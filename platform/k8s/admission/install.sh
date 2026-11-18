#!/usr/bin/env bash
# Installs the admission controllers and their policies. Idempotent.
# Requires the cluster from platform/kind/up.sh.
set -euo pipefail
cd "$(dirname "$0")"

GATEKEEPER_CHART=3.23.1
KYVERNO_CHART=3.10.0

helm upgrade --install gatekeeper gatekeeper \
  --repo https://open-policy-agent.github.io/gatekeeper/charts --version "$GATEKEEPER_CHART" \
  --namespace gatekeeper-system --create-namespace \
  --values gatekeeper-values.yaml --wait --timeout 10m

helm upgrade --install kyverno kyverno \
  --repo https://kyverno.github.io/kyverno/ --version "$KYVERNO_CHART" \
  --namespace kyverno --create-namespace \
  --values kyverno-values.yaml --wait --timeout 10m

# Kyverno reads signatures through Artifactory with the SAME read-only
# identity as the nodes (its secrets must live in its own namespace).
kubectl -n llm-gateway get secret artifactory-pull -o json | python3 -c '
import json, sys
s = json.load(sys.stdin)
s["metadata"] = {"name": s["metadata"]["name"], "namespace": "kyverno"}
print(json.dumps(s))' | kubectl apply -f -

kubectl apply -f gatekeeper/config.yaml
kubectl apply -f gatekeeper/templates/
# Each template creates a constraint CRD asynchronously: wait for them.
for crd in k8sallowedregistries k8simagedigest k8srequiredlimits k8snamespacepsarestricted; do
  # No CRD after 60 s = the template's Rego did not compile: show why.
  for _ in $(seq 30); do kubectl get crd "${crd}.constraints.gatekeeper.sh" >/dev/null 2>&1 && break; sleep 2; done
  kubectl get crd "${crd}.constraints.gatekeeper.sh" >/dev/null 2>&1 || {
    kubectl get constrainttemplate "$crd" -o jsonpath='{.status.byPod[*].errors}' >&2; echo >&2; exit 1; }
  kubectl wait --for condition=established --timeout=60s "crd/${crd}.constraints.gatekeeper.sh"
done
kubectl apply -f gatekeeper/constraints.yaml

kubectl apply -f kyverno/verify-signatures.yaml

echo "Admission control installed. Prove it: python3 ../tests/admission_test.py"
