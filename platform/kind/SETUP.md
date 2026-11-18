# Local cluster (kind) setup

Requires the Artifactory stack from `platform/artifactory` running, with the
`cluster-reader` identity (its SETUP.md §5).

## 1. Create the cluster

```bash
platform/kind/up.sh
```

Creates the `devsecops` cluster, attaches the Artifactory proxy to the kind
network as `registry.local`, creates the `llm-gateway` namespace (Pod
Security `restricted`, enforced) and the read-only pull secret.

## 2. Deploy

```bash
kubectl apply -k platform/k8s/llm-gateway
kubectl -n llm-gateway rollout status deploy/llm-gateway
```

## 3. Prove: images come through Artifactory, by digest

```bash
kubectl -n llm-gateway get pods -o jsonpath='{range .items[*]}{.status.containerStatuses[0].imageID}{"\n"}{end}'
```

Expected: `registry.local:8085/docker/kmdiallo69/llm-gateway@sha256:…`.

## 4. Prove: Pod Security Admission

```bash
kubectl -n llm-gateway run priv --image=registry.local:8085/docker/library/python:3.12-slim --privileged
```

Expected: `forbidden: violates PodSecurity "restricted:latest"`.

## 5. Prove: NetworkPolicies are enforced

```bash
kubectl apply -f platform/k8s/tests/netpol-clients.yaml
kubectl -n llm-gateway wait --for=jsonpath='{.status.phase}'=Succeeded pod/client-allowed pod/client-denied --timeout=90s
kubectl -n llm-gateway logs client-allowed
kubectl -n llm-gateway logs client-denied
kubectl -n llm-gateway exec deploy/llm-gateway -- python -c "import urllib.request; urllib.request.urlopen('https://example.com', timeout=5)"
kubectl delete -f platform/k8s/tests/netpol-clients.yaml
```

Expected: `200` · `TimeoutError` (or `URLError … timed out`) · the gateway
itself cannot reach the internet (`timed out`).

## Tear down

```bash
kind delete cluster --name devsecops
docker network disconnect kind artifactory-proxy-1
```
