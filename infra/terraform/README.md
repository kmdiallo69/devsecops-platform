# Azure infrastructure (Terraform)

```
infra/terraform/
  bootstrap/            remote state store (run once)
  modules/
    platform/           composition: wires the modules below into one environment
    network/            VNet, 3 subnets, NSG per subnet, NAT Gateway, private DNS
    monitoring/         Log Analytics
    key-vault/          vault (RBAC, purge protection), CMK with rotation, private endpoint
    aks/                private cluster, system + user pools, identity, RBAC
    app-gateway/        WAF_v2 (OWASP, bots, rate limit), TLS from Key Vault
    policy/             Azure Policy: pod security restricted + allowed images
  environments/
    dev/  staging/  prod/   one call to modules/platform, one state file each
```

**Same code, different parameters.** Every environment calls the same
composition module; only sizing and exposure differ:

| | dev | staging | prod |
|---|---|---|---|
| VNet | 10.10.0.0/16 | 10.20.0.0/16 | 10.30.0.0/16 |
| AKS tier | Free | Standard (SLA) | Standard (SLA) |
| System / user nodes | 1 / 1, no zones | 2 / 2, zones 1-3 | 3 / 3, zones 1-3 |
| WAF exposure | operator IP | operator / corporate IPs | Internet |
| Key Vault | standard, 7-day soft delete | standard, 30 days | **premium (HSM keys)**, 90 days |
| Logs | 30 days, 0.5 GB/day cap | 30 days, 5 GB/day | 90 days, no cap |
| App Gateway autoscale | 0-2 | 1-3 | 2-10 |

On a free-trial subscription (4 vCPU), only **dev** can be applied;
staging and prod are validated in CI (`fmt`, `validate`, Checkov).

## 1. Bootstrap the state store (once)

```bash
cd infra/terraform/bootstrap
cp terraform.tfvars.example terraform.tfvars   # subscription_id, admin_ip
terraform init
terraform apply
```

Storage account with **no access keys** (Entra ID only), reachable from
the operator IP only, GZRS, blob versioning, 30-day soft delete, and a
`CanNotDelete` lock. Its own state is local (git-ignored).

## 2. Deploy an environment

```bash
cd infra/terraform/environments/dev
cp terraform.tfvars.example terraform.tfvars
terraform init -backend-config="storage_account_name=$(terraform -chdir=../../bootstrap output -raw storage_account_name)"
terraform plan -out=tfplan
terraform apply tfplan
```

About 25 minutes (App Gateway and AKS are the long ones).

## 3. Deploy the app

The cluster is private: kubectl runs through Azure Resource Manager.

```bash
RG=$(terraform output -raw resource_group); AKS=$(terraform output -raw aks_name)
kubectl kustomize ../../../../deploy/k8s/overlays/dev > /tmp/dev.yaml
az aks command invoke -g $RG -n $AKS --file /tmp/dev.yaml \
  --command "kubectl apply -f dev.yaml && kubectl -n llm-gateway rollout status deploy/llm-gateway"
```

The overlay's ILB IP and WAF subnet must match `terraform output
ingress_ilb_ip` / `appgw_cidr` (both derived from the environment's /16).

## 4. Destroy

Remove the workloads FIRST, then the infrastructure:

```bash
az aks command invoke -g $RG -n $AKS --command "kubectl delete namespace llm-gateway --wait=true"
terraform destroy
```

Why: draining the user pool moves the app pods — and in dev there is
nowhere to move them (one user node; the system pool is tainted
`CriticalAddonsOnly`). The PodDisruptionBudget (`minAvailable: 1`) then
correctly refuses the second eviction and the pool deletion blocks for 30
minutes. Same root cause as an upgrade without surge capacity: a PDB needs
somewhere to reschedule to. If it happens anyway:
`az aks nodepool delete --ignore-pdb` (Azure API, not Kubernetes RBAC).

The vault stays soft-deleted for its retention period (purge protection);
the next deployment gets a new name from the random suffix.

## What deploying it for real found

| Finding | Fix |
|---|---|
| The App Gateway, inside the VNet, resolved Key Vault to its **private endpoint** — which the PE NSG did not allow — and failed after 20 min with a bare `InternalServerError` | PE NSG allows the WAF subnet |
| AKS KMS needs **two** permission planes: `Key Vault Crypto User` (data) **and** `vaults/read` (control) | `Reader` on the vault only |
| Azure Policy blocked `az aks command invoke` — its pod runs a Microsoft image without our securityContext | `aks-command` added to the excluded namespaces (access stays gated by Azure RBAC) |
| Azure CNI **overlay** keeps pod IPs between nodes: the nodes NSG's deny-all dropped cross-node DNS | pod CIDR allowed in the nodes NSG |
| The Azure *restricted* initiative is stricter than Kubernetes PSA *restricted*: requires `fsGroup` and `supplementalGroups` | added to the base Deployment |
| Default ephemeral OS disk (128 GB) larger than the VM's local NVMe (110 GiB) | `os_disk_size_gb = 64` |
| **Teardown**: the PDB blocked the user-pool drain (one user node, nowhere to reschedule) — and the admin role assignment was destroyed in parallel, so `kubectl` was refused while the pool hung | runbook: delete workloads first; node pool now `depends_on` the admin role (access kept until the pool is gone); `--ignore-pdb` via the Azure API as last resort |
| A 40-minute destroy outlived the interactive CLI token (`ExpiredAuthenticationToken`) | re-run (state was consistent, locked meanwhile); CI uses OIDC federation, refreshed by the provider |
