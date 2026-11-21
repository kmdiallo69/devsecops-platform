#!/usr/bin/env bash
# Deploys deploy/k8s/overlays/<env> to that environment's PRIVATE AKS cluster.
#
#   scripts/deploy-aks.sh dev
#
# The overlay in Git is complete except for three non-secret IDs that change
# on every deployment (random name suffix): the app's Workload Identity
# client ID, the vault name and the tenant. They are read from the
# environment's Terraform outputs and injected into a temporary overlay —
# nothing in the repository is modified.
#
# The cluster API is private: kubectl runs through Azure Resource Manager
# (`az aks command invoke`), authorized by Entra ID + Azure RBAC.
set -euo pipefail

ENV="${1:?usage: $0 <dev|staging|prod>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF="${ROOT}/infra/terraform/environments/${ENV}"
OVERLAY="${ROOT}/deploy/k8s/overlays/${ENV}"
[[ -d "$TF" && -d "$OVERLAY" ]] || { echo "unknown environment: ${ENV}" >&2; exit 1; }

out() { terraform -chdir="$TF" output -raw "$1"; }
RG="$(out resource_group)"
AKS="$(out aks_name)"
KV="$(out key_vault_name)"
TENANT="$(out tenant_id)"
CLIENT_ID="$(out app_identity_client_id)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "${WORK}/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ${OVERLAY}
patches:
  - target:
      kind: SecretProviderClass
      name: llm-gateway-secrets
    patch: |-
      - op: replace
        path: /spec/parameters/clientID
        value: ${CLIENT_ID}
      - op: replace
        path: /spec/parameters/keyvaultName
        value: ${KV}
      - op: replace
        path: /spec/parameters/tenantId
        value: ${TENANT}
EOF

kubectl kustomize "$WORK" > "${WORK}/manifests.yaml"
grep -q "SET-AT-DEPLOY" "${WORK}/manifests.yaml" && { echo "unresolved placeholder in manifests" >&2; exit 1; }

echo "Deploying ${ENV} to ${AKS} (${RG})"
az aks command invoke -g "$RG" -n "$AKS" --file "${WORK}/manifests.yaml" \
  --command "kubectl apply -f manifests.yaml && kubectl -n llm-gateway rollout status deploy/llm-gateway --timeout=240s && kubectl -n llm-gateway get pods,svc -o wide"
