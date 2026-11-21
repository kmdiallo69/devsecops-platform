#!/usr/bin/env bash
# Creates the kind cluster, wires it to the Artifactory proxy and creates
# the image pull secret for the cluster-reader identity. Idempotent.
set -euo pipefail
cd "$(dirname "$0")"

CLUSTER=devsecops
PROXY=artifactory-proxy-1
NAMESPACE=llm-gateway

docker inspect "$PROXY" >/dev/null 2>&1 || {
  echo "Artifactory proxy not running — start platform/local/artifactory first." >&2; exit 1; }

kind get clusters 2>/dev/null | grep -qx "$CLUSTER" || kind create cluster --config cluster.yaml
kubectl config use-context "kind-${CLUSTER}" >/dev/null

# Registry settings into every node (re-run safe; containerd reads
# certs.d on each pull, no restart needed).
for node in $(kind get nodes --name "$CLUSTER"); do
  for dir in containerd/certs.d/*/; do
    host="$(basename "$dir")"
    docker exec "$node" mkdir -p "/etc/containerd/certs.d/${host}"
    docker exec -i "$node" sh -c "cat > '/etc/containerd/certs.d/${host}/hosts.toml'" < "${dir}hosts.toml"
  done
done

# The nodes resolve `registry.local` to the proxy through Docker's DNS.
docker network inspect kind --format '{{range .Containers}}{{.Name}} {{end}}' | grep -qw "$PROXY" \
  || docker network connect --alias registry.local kind "$PROXY"

kubectl apply -f ../../../deploy/k8s/base/namespace.yaml

# Pull secret for the READ-ONLY identity, built from the keychain and piped
# straight to the API server: the password never touches disk, argv or the
# shell history.
security find-generic-password -s jfrog-cluster-reader -w | python3 -c '
import base64, json, sys
auth = base64.b64encode(b"cluster-reader:" + sys.stdin.read().strip().encode()).decode()
print(json.dumps({"auths": {"registry.local:8085": {"auth": auth}}}))' |
  kubectl -n "$NAMESPACE" create secret generic artifactory-pull \
    --type=kubernetes.io/dockerconfigjson --from-file=.dockerconfigjson=/dev/stdin \
    --dry-run=client -o yaml | kubectl apply -f -

echo "Cluster ready. From the repo root: kubectl apply -k deploy/k8s/overlays/local"
