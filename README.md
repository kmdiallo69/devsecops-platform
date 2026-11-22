# DevSecOps Platform — Azure / AKS

A secure software supply chain and hardened Kubernetes platform, built step
by step: every commit is gated by automated security controls, every image
is scanned, signed and stored in a governed artifact repository (JFrog
Artifactory), and the cluster only admits workloads that meet policy.

Built **local-first** (kind cluster, zero cloud cost), then deployed to
**Azure** (AKS, Key Vault, Azure Policy, Defender for Cloud) with Terraform.

## Repository layout

```
apps/llm-gateway/          the application (FastAPI) + hardened Dockerfile
.github/workflows/         security-ci (PR gates), release (sign, SBOM, provenance)
infra/terraform/           Azure: bootstrap (state), modules, environments/{dev,staging,prod}
deploy/k8s/                Kustomize: base + components + overlays/{local,dev,staging,prod}
platform/local/            local lab: Artifactory, kind, Gatekeeper/Kyverno, Falco, tests
scripts/                   verify-release.sh (signature, SBOM, provenance by digest)
```

One workload contract (`deploy/k8s/base`), one infrastructure composition
(`infra/terraform/modules/platform`): environments differ by parameters,
never by code. Promoting a release = a PR changing one digest in an overlay.

## Roadmap

Each step is one commit (or a small series), tested for real before moving on.

| # | Step | What it proves | Status |
|---|------|----------------|--------|
| 0 | Bootstrap: toolchain, repo hygiene, pre-commit secret scanning | Shift-left: secrets never reach Git | ✅ |
| 1 | Demo app + LLM gateway (FastAPI), hardened Dockerfile | Secure-by-default containers | ✅ |
| 2 | CI security gates (GitHub Actions): Gitleaks, Semgrep (SAST), pip-audit (SCA), Checkov + Hadolint (IaC), Trivy (image) — required to merge | SAST / SCA / IaC / secret detection as merge gates | ✅ |
| 3 | JFrog Artifactory (self-hosted JCR): single entry point, remote-repo allowlists, immutable tags, least-privilege identities | Artifact governance | ✅ |
| 4 | Supply chain: SBOM (Syft), Cosign keyless signing, SLSA provenance | Signed images + provenance | ✅ |
| 5 | Local cluster (kind): Pod Security Admission, NetworkPolicies, OPA Gatekeeper (allowed registries, no privileged, required limits), signature verification at admission | Policy enforcement | ✅ |
| 6 | Runtime protection: Falco rules + alert | Runtime threat detection | ✅ |
| 7 | Azure with Terraform (modules + dev/staging/prod): private AKS, WAF_v2, NAT Gateway, NSGs, Key Vault CMK + private endpoint, Azure Policy, remote state | Governed cloud foundation, key management | ✅ |
| 8 | Secrets: Key Vault → Secrets Store CSI driver via Workload Identity, write-only Terraform secret, rotation without restart | No secret in Git, images, state, env vars or Kubernetes Secrets | ✅ |
| 9 | Defender for Cloud: CSPM, Defender for Containers (AKS sensor), Key Vault threat protection, security contact — subscription root of its own | CSPM/CWPP, defense in depth (admission + runtime) | ✅ |
| 10 | AI/LLM security: guardrails mapped to the OWASP LLM Top 10 (prompt injection, output handling, PII, rate limits) + tests | Securing AI/LLM platforms | ⏳ |
| 11 | Threat model (STRIDE) + architecture docs | Secure design | ⏳ |

## LLM gateway (`apps/llm-gateway`)

The single, controlled path between users and a model. Talks to any
OpenAI-compatible inference endpoint (vLLM, Ollama, Azure AI Foundry);
defaults to an offline mock so tests and CI need no model and no key.

| Control (Step 1) | Why |
|---|---|
| Clients cannot send `role: system` | Prompt injection via instruction override (OWASP LLM01) |
| Bounded message size, count and `max_tokens` | Cost / resource exhaustion (OWASP LLM10) |
| Generic 502 on upstream errors, details only in logs | No leakage of internal URLs, model names or keys |
| API docs off by default | No free map of the attack surface |
| Every dependency pinned **and hashed**, locked for Linux/py3.12 | A substituted package fails the build |
| Multi-stage image, numeric non-root UID, pip removed | Smaller attack surface; works with `runAsNonRoot` |

```bash
cd apps/llm-gateway
uv venv --python 3.12 --managed-python && source .venv/bin/activate
uv pip install --require-hashes -r requirements-dev.txt
python -m pytest -q
```

## Security CI (`.github/workflows/security-ci.yml`)

Six gates run in parallel on every PR; `main` is branch-protected, so a PR
cannot merge unless all six pass. Findings from Semgrep and Checkov are
uploaded as SARIF to the repository's Security tab.

The pipeline itself is hardened: actions pinned to full commit SHAs
(kept current by Dependabot), `permissions: {}` by default with per-job
grants, `persist-credentials: false` on every checkout.

**What the first CI run actually caught** (PR #1):

| Finding | Gate | Fix |
|---|---|---|
| zlib1g heap overflow (CVE-2026-85091, HIGH) in `python:3.12-slim` — fixed in Debian, not yet in the official image | Trivy | `apt-get upgrade` at build time |
| `COPY` without `WORKDIR` in the builder stage (DL3045) | Hadolint | explicit `WORKDIR /build` |
| `checkov-action` pinned from its "latest release" — published in 2022, ran Checkov 2.0.930 | the pipeline itself | pin resolved from the newest **tag** |
| Hadolint skipped because the Checkov step failed before it | the pipeline itself | `if: !cancelled()` — one gate never hides another |

## Artifact governance — JFrog Artifactory (`platform/local/artifactory`)

Self-hosted JFrog Container Registry (JCR) + PostgreSQL, behind an nginx
proxy. Artifactory is the **single trusted entry point** for images:
nothing is pulled from Docker Hub or GHCR directly.

```
CI ──build, scan, sign──▶ GHCR                Docker Hub
                           │                      │
                     ghcr-remote            dockerhub-remote
                  (only kmdiallo69/**)   (only library/python/**)
                           └──────┬───────────────┘
                     docker (virtual) ◀── images-local (immutable tags)
                                  │
                       developers · CI · Kubernetes
```

| Control | How |
|---|---|
| Allowlisted upstreams | `includesPattern` on remote repos — `nginx`, `someuser/python` are refused |
| Immutable tags | publisher has *Deploy/Cache* but not *Delete/Overwrite* on `images-local` — see the limit below |
| Least privilege | `publisher` (push to `images-local` only), `cluster-reader` (read only); no UI access for either; anonymous access disabled; installer default "Read on everything" permission removed |
| Config as code | repositories in `config/repositories.yml`, applied with `apply-config.sh` (idempotent merge) |
| No secrets in Git | admin token and passwords read from the OS keychain; DB password in a git-ignored `.env` |
| Network exposure | every port bound to `127.0.0.1`; PostgreSQL not published at all |

**What testing the controls actually found** (every control is proven with
real `docker` commands, [`SETUP.md` §6](platform/local/artifactory/SETUP.md)):

| Finding | Impact | Fix |
|---|---|---|
| Installer default permission `Anything` grants **Read on every repository** to the `readers` group, which every new user joins automatically | least privilege silently broken | permission deleted, auto-join disabled |
| "No Delete/Overwrite" is enforced per **file**: an index is stored as `list.manifest.json`, a single image as `manifest.json` — pushing the other format to an existing tag was **accepted** | tag immutability bypassable by the publisher | one manifest format, always; same-format overwrite proven refused (`needs DELETE permission`); real guarantee moved to **deploy by digest + signature verification at admission** (steps 4–5) |
| Passwords pasted into the UI were silently altered (partial selection of base64, browser autofill) | `Bad Credentials` for machine identities | passwords generated into the keychain, copied with `pbcopy`, verified by an API check before use |

**Edition limit, stated plainly:** JCR (the free edition) exposes the
repository configuration API but not the user/permission APIs (Pro only), so
the two identities and their permissions are created in the UI, following
the exact steps in [`platform/local/artifactory/SETUP.md`](platform/local/artifactory/SETUP.md).
With Artifactory Pro, those would be Terraform (`jfrog/platform` provider).

## Software supply chain — sign, SBOM, provenance (`.github/workflows/release.yml`)

Every merge to `main` that changes the app produces **one immutable
reference** — `ghcr.io/kmdiallo69/llm-gateway@sha256:…`, an index of
`linux/amd64` + `linux/arm64` — and three verifiable claims about it:

| Claim | Tool | Answers |
|---|---|---|
| Signature (index + each platform) | Cosign, keyless | did **our** pipeline produce it? |
| SBOM, one per platform (SPDX) | Syft + `cosign attest` | what exactly is inside it? |
| SLSA build provenance | `actions/attest-build-provenance` | which commit, workflow and runner built it? |

```
build (amd64+arm64) ─▶ push ─▶ Trivy (both platforms) ─▶ sign ─▶ SBOM attest ─▶ provenance
                         │            │ fails?
                         │            └──▶ stops here: image stays UNSIGNED = undeployable
                         └── everything after this targets the digest, never the tag
```

| Control | Why |
|---|---|
| **Keyless** signing (GitHub OIDC → Sigstore Fulcio, logged in Rekor) | no private key exists to steal, leak or rotate |
| Verification pins the **signer identity**: this repo's `release.yml` on `refs/heads/main` | a valid signature is not enough — anyone can sign keylessly; a fork or another branch fails |
| Digest only — [`scripts/verify-release.sh`](scripts/verify-release.sh) refuses a tag | a tag is a mutable pointer (proven in Step 3) |
| Scanned again at release time, signed only if clean | a CVE published between PR and merge never gets signed |
| BuildKit attestation manifests off; one index format on every release | keeps the registry's no-overwrite rule effective (Step 3 finding) |

```bash
scripts/verify-release.sh ghcr.io/kmdiallo69/llm-gateway@sha256:<digest>
scripts/verify-release.sh 127.0.0.1:8085/docker/kmdiallo69/llm-gateway@sha256:<digest>   # through Artifactory
```

**What testing it actually found:**

| Finding | Impact | Fix |
|---|---|---|
| `docker build` on the CI runner pushed an **index** (amd64 + an `unknown/unknown` BuildKit attestation), not a single image — and amd64 only | broke the "one format" rule; image unusable on ARM nodes | explicit multi-arch buildx build, `--provenance=false --sbom=false` |
| Consumers pulling **through Artifactory** got `no signatures found`, while GHCR verified fine | signed images look unsigned behind the proxy — admission would reject every release | Artifactory answers the OCI referrers API with an **empty list**, so Cosign v3 never falls back to the referrers tag. Signing switched to the classic tag format (`sha256-….sig` / `.att`), served like any tag |

**Trade-off, stated plainly:** Cosign marks the classic format as
deprecated. It is kept deliberately because it is what works through the
registry proxy today; the switch back to OCI referrers is a one-line change
(`COSIGN_FORMAT` in the workflow) once the proxy serves them.

## Policy enforcement — kind cluster (`platform/local/kind`, `deploy/k8s`, `platform/local`)

A local cluster that **only runs what the pipeline signed**. Nodes pull
exclusively through Artifactory (`registry.local:8085`, read-only
`cluster-reader` identity); three admission layers decide what may run:

| Layer | Rules | Why this tool |
|---|---|---|
| **Pod Security Admission** (`restricted`, enforced) | no privileged, no root, no capabilities, no privilege escalation, seccomp required | built into the API server — nothing to install, bypass or crash |
| **OPA Gatekeeper** (Rego, [`templates/`](platform/local/admission/gatekeeper/templates/)) | registry = Artifactory only (init and ephemeral containers included: `kubectl debug` is no way around it) · digest required · CPU/memory limits · **every namespace must enforce PSA `restricted`** | general-purpose policy; the last rule closes PSA's gap — it only protects namespaces that carry its label |
| **Kyverno** `ImageValidatingPolicy` ([`verify-signatures.yaml`](platform/local/admission/kyverno/verify-signatures.yaml)) | **every** image signed by `release.yml@refs/heads/main` (keyless), signatures fetched through Artifactory | native Cosign keyless verification (Gatekeeper would need an external-data provider for it) |

Workload hardening ([`deployment.yaml`](deploy/k8s/base/deployment.yaml)):
image by signed digest, UID 10001, read-only root filesystem, all
capabilities dropped, no service-account token, CPU/memory limits.
[`networkpolicy.yaml`](deploy/k8s/base/networkpolicy.yaml): default
deny; only DNS and labelled clients → gateway:8000; **no internet egress for
the gateway** (an LLM gateway that can reach anywhere is an exfiltration /
SSRF channel).

**Proven, not assumed** — [`admission_test.py`](platform/local/tests/admission_test.py)
sends a compliant pod with exactly one thing broken, through the real
admission chain (`--dry-run=server`):

| Case | Result | Refused by |
|---|---|---|
| signed release, by digest | admitted | — |
| same signed image, by **tag** | refused | Gatekeeper / Kyverno (both enforce digests) |
| Docker Hub directly | refused | Gatekeeper / Kyverno |
| allowlisted in Artifactory but **unsigned** (python base image) | refused | Kyverno |
| no CPU/memory limits | refused | Gatekeeper |
| privileged container | refused | Pod Security |
| namespace without the PSA label | refused | Gatekeeper |

**What testing it actually found:**

| Finding | Impact | Fix |
|---|---|---|
| Gatekeeper's chart default is `failurePolicy: Ignore` | Gatekeeper down = every pod admitted unchecked | fail closed (`Fail`), Kyverno too |
| …and fail-closed with the default webhook scope **deadlocked the cluster**: while Gatekeeper started, kube-controller-manager could not renew its Lease (kube-system) → lost leadership → never marked the webhook's own endpoint ready | every write refused, including Helm | webhook never called for system namespaces, and only for pods/namespaces; break-glass procedure in [`SETUP.md`](platform/local/kind/SETUP.md) |
| Registry config bind-mounted from the repo went stale after a `git switch` (mount keeps the deleted directory) | nodes fell back to HTTPS → `ImagePullBackOff` | config copied into the nodes by `up.sh` |
| The first test runner counted "webhook unreachable" as a successful denial | 5 false passes | a refusal counts only if the expected control made it |

**Known limit, stated plainly:** system namespaces (control plane,
Gatekeeper, Kyverno) are exempt from admission, so those add-ons pull from
their upstream registries. In production they would be mirrored through
Artifactory and pinned by digest too.

## Runtime detection — Falco (`platform/local/runtime`)

Admission control decides what may **start**; Falco watches what a running
container actually **does** — the only layer that sees an attacker who got
in through the application itself (RCE, SSRF, a malicious dependency).
Kernel events via the modern eBPF probe (no kernel module), routed by
Falcosidekick to a web UI (in production: Slack, PagerDuty or a SIEM).

Rules written for **this** workload ([`falco-values.yaml`](platform/local/runtime/falco-values.yaml)),
on top of Falco's default ruleset:

| Rule | Priority | Logic |
|---|---|---|
| Unexpected process in LLM gateway | CRITICAL | the image runs one program (uvicorn/python): **any** other process — shell, `curl`, package manager — is an intrusion or an unannounced debug session (MITRE T1059) |
| LLM gateway outbound connection attempt | WARNING | NetworkPolicy **blocks** internet egress; this **detects the attempt** — an SSRF or a prompt-injected tool call trying to exfiltrate (T1041) |

Proven with real commands ([`SETUP.md` §7](platform/local/kind/SETUP.md)):
`kubectl exec … sh -c id` → two CRITICAL alerts (`sh`, `id`) with pod,
namespace, image and command line; a connection to `1.1.1.1:443` →
refused by the NetworkPolicy **and** reported by Falco.

| Finding | Impact | Fix |
|---|---|---|
| The process rule also fired on runc's own bootstrap process (`6 init`, parent `runc`, uid 0) — twice per `kubectl exec` | alert noise: 4 alerts where 2 mattered | narrow exclusion (`parent = runc and args = init`); the exec'd process is still alerted |
| Falcosidekick UI ships with `admin:admin` | anyone reaching the UI reads every security event | password generated into the keychain, injected as a secret; `admin:admin` → 401 verified |

**Trade-off, stated plainly:** a kernel sensor needs privileges our own
policies forbid. `falco` is therefore the single namespace allowed to run
privileged pods — labelled `enforce: privileged` on purpose, exempt from
Gatekeeper and Kyverno, with PSA `warn`/`audit` kept at `restricted` so its
privileged pods stay visible.

## Azure — production-grade landing zone (`infra/terraform`)

```
Internet ─443─▶ App Gateway WAF_v2 ─80─▶ internal LB ─▶ pods (private AKS, user pool)
                (OWASP, bots, rate        (node subnet)     │
                 limit, TLS from KV)                        ├─▶ Key Vault (private endpoint)
                                                            └─▶ NAT Gateway ─▶ Internet (one fixed IP)
```

| Layer | Control |
|---|---|
| Edge | WAF_v2 in Prevention mode, Microsoft DRS 2.1 + bot rules, 60 req/min per client IP, TLS 1.2+, `Authorization` scrubbed from logs |
| Network | one subnet per trust zone, NSG with explicit deny-all on each; the only path into the nodes is WAF → ILB:80 |
| Egress | NAT Gateway: one known IP, no public IP on any node, no default outbound access |
| Cluster | private API server, no local accounts (Entra ID + Azure RBAC only), etcd encrypted with a rotating CMK, system/user pools, ephemeral OS disks + host encryption, Cilium NetworkPolicies |
| Governance | Azure Policy (pod security restricted + allowed images regex) in deny mode; audit logs of AKS, Key Vault and WAF to Log Analytics |
| Terraform | modules + thin environments, remote state per environment (no access keys, versioned, locked), provider checksums locked, fmt/validate/Checkov in CI |

**Proven on Azure** (dev): app reachable only through the WAF (`200`),
SQL injection and XSS refused (`403`), rate limit enforced, port 80 closed,
API server with no public FQDN, admin kubeconfig refused, pod egress seen
from the outside as the NAT IP. Six issues found by deploying for real are
listed in [`infra/terraform/README.md`](infra/terraform/README.md).

## Secrets without secrets (`infra/terraform/modules/app-identity`, `deploy/k8s/components/aks-workload-identity`)

The LLM provider API key reaches the app as a **read-only file** — and
exists nowhere else:

```
Key Vault secret ──private endpoint──▶ Secrets Store CSI driver ──▶ /mnt/secrets/llm-api-key (tmpfs, read-only)
       ▲                                     │
       │ Key Vault Secrets User              │ ServiceAccount token, exchanged by OIDC federation
       │ on THIS secret only                 ▼
       └──────────── managed identity ◀── Entra ID (trusts llm-gateway/llm-gateway of this cluster only)
```

| Where the key is NOT | How |
|---|---|
| Git, the image | never committed; supplied as `TF_VAR_llm_api_key` from the OS keychain |
| Terraform plan and **state** | `value_wo` (write-only attribute) + `ephemeral` variable |
| An environment variable | the app reads `LLM_API_KEY_FILE` (env vars leak via `/proc`, child processes, dumps) |
| A Kubernetes `Secret` | the CSI driver mounts the file directly (no `secretObjects` sync) |
| The app container's credentials | the pod is not labelled for Workload Identity: no Azure token, no SA token in the container — only the CSI driver uses one |

**Proven on Azure** (dev), with hashes only — the key is never displayed:

| Test | Result |
|---|---|
| Key searched in the remote state and the saved plan | not found (both) |
| SHA-256 of the mounted file vs the keychain value | identical |
| Inside the app container | key not in env, no `AZURE_*` vars, no federated token, no SA token, mount read-only, 0 Kubernetes Secrets |
| **Rotation**: new value pushed (`llm_api_key_version` 1 → 2, plan = 1 in-place change) | same pod, 0 restarts, new hash read **within 45 s** |

Rotation without restart: the CSI driver replaces the file in place (2-min
sync); the app re-reads it when it changes and sends the key per request
(`apps/llm-gateway/app/secrets.py`, tested in `tests/test_secrets.py`).

## Quick start

```bash
brew bundle            # install the toolchain (see Brewfile)
pre-commit install     # enable local secret scanning before every commit
```
