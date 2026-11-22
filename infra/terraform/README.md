# Azure infrastructure (Terraform)

```
infra/terraform/
  bootstrap/            remote state store (run once)
  subscription/         Defender for Cloud plans + security contact (once per subscription)
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
| System node size | D2 (2 vCPU) | D4 (4 vCPU) | D4 (4 vCPU) |
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

## 1b. Subscription security baseline (once per subscription)

```bash
cd infra/terraform/subscription
cp terraform.tfvars.example terraform.tfvars   # subscription_id, security_contact_email
terraform init -backend-config="storage_account_name=$(terraform -chdir=../bootstrap output -raw storage_account_name)"
terraform apply
```

Defender for Cloud plans are **subscription-wide**, so they live in their
own root and state, not in an environment: destroying dev must not switch
off threat protection for staging and prod.

| Plan | What it gives |
|---|---|
| Defender CSPM | posture recommendations, attack paths, agentless scanning |
| Defender for Containers | runtime sensor on AKS nodes, agentless K8s discovery, registry vulnerability assessment |
| Key Vault | anomalous access alerts (unusual IP, volume, enumeration) |

The AKS module declares the sensor (`microsoft_defender` block) explicitly:
with the Containers plan on, Azure would add it by itself and every plan
would show drift. `enable_defender = false` returns all plans to Free.

## 2. Deploy an environment

```bash
cd infra/terraform/environments/dev
cp terraform.tfvars.example terraform.tfvars
terraform init -backend-config="storage_account_name=$(terraform -chdir=../../bootstrap output -raw storage_account_name)"
terraform plan -out=tfplan
terraform apply tfplan
```

About 25 minutes (App Gateway and AKS are the long ones).

The LLM API key is passed from the keychain, never written to a file:

```bash
TF_VAR_llm_api_key="$(security find-generic-password -s llm-api-key-dev -w)" terraform plan -out=tfplan
TF_VAR_llm_api_key="$(security find-generic-password -s llm-api-key-dev -w)" terraform apply tfplan
```

It is a write-only value: it reaches Key Vault, never the plan or the
state. To rotate: new value + `-var llm_api_key_version=<n+1>`.

## 3. Deploy the app

```bash
scripts/deploy-aks.sh dev    # from the repository root
```

Renders `deploy/k8s/overlays/dev`, injects the three non-secret IDs that
change per deployment (Workload Identity client ID, vault name, tenant) and
applies it through `az aks command invoke` — the API server is private.
The overlay's ILB IP and WAF subnet match `ingress_ilb_ip` / `appgw_cidr`
(both derived from the environment's /16).

### Verify runtime detection

Admission control first — a root pod with a non-allowed image is refused
(Azure Policy: image not allowed, no `runAsNonRoot`, no `fsGroup`, no seccomp):

```bash
$KUBECTL "kubectl create ns defender-test; kubectl run t -n defender-test --image=mcr.microsoft.com/aks/fundamental/base-ubuntu:v0.0.11 -- sleep 600; kubectl delete ns defender-test"
```

Then Microsoft's simulated alert, in a namespace **excluded** from the
policies (`aks-command`, not `kube-system`: activity in system namespaces
did not produce the test alert):

```bash
$KUBECTL "kubectl run defender-test -n aks-command --image=mcr.microsoft.com/aks/fundamental/base-ubuntu:v0.0.11 --restart=Never -- sleep 600 && kubectl wait -n aks-command --for=condition=Ready pod/defender-test --timeout=120s && kubectl exec -n aks-command defender-test -- bash -c 'cp /bin/echo ./asc_alerttest_662jfi039n; ./asc_alerttest_662jfi039n testing eicar pipe'; kubectl delete pod -n aks-command defender-test --wait=false"
az security alert list --query "[?contains(alertDisplayName,'test')]" -o table   # 10-30 min later
```

`$KUBECTL` is the environment's `kubectl` output. The point of the pair:
admission control has blind spots (excluded namespaces); runtime detection
sees process behaviour regardless of namespace. Prevention and detection
are layers, not alternatives.

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
| Defender sensor: the collector DaemonSet pod stayed `Pending` on the dev **system node** — AKS add-ons already request 1881m of its 1900m allocatable CPU, so the node ran with **no runtime detection** | dev accepted and documented (4-vCPU trial quota); staging system pool raised to D4 (prod already D4). Check `kubectl get ds -n kube-system` after enabling the sensor: DESIRED must equal READY |
| Simulated Defender alert run in `kube-system`: no alert after 3 h, while the sensor reported healthy (heartbeats, no errors) | runbook uses a non-system namespace (`aks-command`); a quiet sensor is not proof of coverage — test detection end to end, don't trust a green DaemonSet |
| A 40-minute destroy outlived the interactive CLI token (`ExpiredAuthenticationToken`) | re-run (state was consistent, locked meanwhile); CI uses OIDC federation, refreshed by the provider |
