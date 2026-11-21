# Local cluster (kind) setup

Requires the Artifactory stack from `platform/local/artifactory` running, with the
`cluster-reader` identity (its SETUP.md §5).

## 1. Create the cluster

```bash
platform/local/kind/up.sh
```

Creates the `devsecops` cluster, attaches the Artifactory proxy to the kind
network as `registry.local`, creates the `llm-gateway` namespace (Pod
Security `restricted`, enforced) and the read-only pull secret.

## 2. Deploy

```bash
kubectl apply -k deploy/k8s/overlays/local
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
kubectl apply -f platform/local/tests/netpol-clients.yaml
kubectl -n llm-gateway wait --for=jsonpath='{.status.phase}'=Succeeded pod/client-allowed pod/client-denied --timeout=90s
kubectl -n llm-gateway logs client-allowed
kubectl -n llm-gateway logs client-denied
kubectl -n llm-gateway exec deploy/llm-gateway -- python -c "import urllib.request; urllib.request.urlopen('https://example.com', timeout=5)"
kubectl delete -f platform/local/tests/netpol-clients.yaml
```

Expected: `200` · `TimeoutError` (or `URLError … timed out`) · the gateway
itself cannot reach the internet (`timed out`).

## 6. Admission control (Gatekeeper + Kyverno)

```bash
platform/local/admission/install.sh
python3 platform/local/tests/admission_test.py
kubectl -n llm-gateway rollout restart deploy/llm-gateway
kubectl -n llm-gateway rollout status deploy/llm-gateway
```

Expected: `7/7 controls behaved as expected`, then a successful rollout
(the signed release passes all three layers). Each test case is a compliant
pod with exactly one thing broken, sent with `--dry-run=server`: the real
admission chain runs, nothing is created. A refusal only counts if the
expected control made it — "failed calling webhook" (controller down) is a
failure, not a pass.

## 7. Runtime detection (Falco)

```bash
platform/local/runtime/install.sh
kubectl -n llm-gateway exec deploy/llm-gateway -- sh -c id
kubectl -n llm-gateway exec deploy/llm-gateway -- python -c "import socket; s=socket.socket(); s.settimeout(3); print(s.connect_ex(('1.1.1.1', 443)))"
sleep 5
kubectl -n falco logs ds/falco -c falco --since=2m | grep -E "Unexpected process|tried to reach"
```

Expected: `Unexpected process in LLM gateway` for `sh` and for `id` (CRITICAL),
`LLM gateway tried to reach the outside (dest=1.1.1.1:443 …)` (WARNING) — and
the connection itself fails (non-zero code): blocked by NetworkPolicy AND
detected by Falco.

Alerts UI (password generated into the keychain by `install.sh`):

```bash
security find-generic-password -s falco-ui -w | tr -d '\n' | pbcopy
kubectl -n falco port-forward svc/falco-falcosidekick-ui 2802:2802
```

Open http://127.0.0.1:2802 in a private window, user `admin`, paste with
⌘A then ⌘V, then `pbcopy < /dev/null`. The chart default `admin:admin` is
refused (401).

## Break-glass: the admission webhook blocks the cluster

Both webhooks fail closed. If Gatekeeper is down and system components
cannot write (symptom: every `kubectl apply` fails with
`failed calling webhook "validation.gatekeeper.sh"`), remove the webhook
registration — no policy is deleted — then re-run `install.sh`:

```bash
kubectl delete validatingwebhookconfiguration gatekeeper-validating-webhook-configuration
platform/local/admission/install.sh
```

The webhook scope (`gatekeeper-values.yaml`) is what keeps this from
happening in normal operation: system namespaces are never sent to the
webhook, and only pods and namespaces are.

## Tear down

```bash
kind delete cluster --name devsecops
docker network disconnect kind artifactory-proxy-1
```
