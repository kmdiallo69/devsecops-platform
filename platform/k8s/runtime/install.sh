#!/usr/bin/env bash
# Installs Falco (runtime detection) + Falcosidekick (alert routing, web UI).
# Requires platform/k8s/admission/install.sh to have run (falco namespace
# exemption). Idempotent.
set -euo pipefail
cd "$(dirname "$0")"

FALCO_CHART=9.2.2

# Namespace first, with its labels: `helm --create-namespace` would create
# it unlabelled.
kubectl apply -f namespace.yaml

# UI password: generated once into the keychain, piped to the API server.
security find-generic-password -s falco-ui -w >/dev/null 2>&1 \
  || security add-generic-password -a "$USER" -s falco-ui -w "$(openssl rand -base64 24)"
security find-generic-password -s falco-ui -w | sed 's/^/FALCOSIDEKICK_UI_USER=admin:/' |
  kubectl -n falco create secret generic falco-ui-credentials --from-env-file=/dev/stdin \
    --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install falco falco \
  --repo https://falcosecurity.github.io/charts --version "$FALCO_CHART" \
  --namespace falco \
  --values falco-values.yaml --wait --timeout 10m

echo "Falco installed. Alerts UI: kubectl -n falco port-forward svc/falco-falcosidekick-ui 2802:2802"
