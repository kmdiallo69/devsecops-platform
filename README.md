# DevSecOps Platform — Azure / AKS

A secure software supply chain and hardened Kubernetes platform, built step
by step: every commit is gated by automated security controls, every image
is scanned, signed and stored in a governed artifact repository (JFrog
Artifactory), and the cluster only admits workloads that meet policy.

Built **local-first** (kind cluster, zero cloud cost), then deployed to
**Azure** (AKS, Key Vault, Azure Policy, Defender for Cloud) with Terraform.

## Roadmap

Each step is one commit (or a small series), tested for real before moving on.

| # | Step | What it proves | Status |
|---|------|----------------|--------|
| 0 | Bootstrap: toolchain, repo hygiene, pre-commit secret scanning | Shift-left: secrets never reach Git | ✅ |
| 1 | Demo app + LLM gateway (FastAPI), hardened Dockerfile | Secure-by-default containers | ✅ |
| 2 | CI security gates (GitHub Actions): Gitleaks, Semgrep/Bandit (SAST), pip-audit + Trivy (SCA), Checkov (IaC), Hadolint | SAST / SCA / IaC / secret detection as merge gates | ⏳ |
| 3 | JFrog Artifactory: push via OIDC, immutable tags, remote-repo allow/deny, Xray | Artifact governance | ⏳ |
| 4 | Supply chain: SBOM (Syft), Cosign keyless signing, SLSA provenance | Signed images + provenance | ⏳ |
| 5 | Local cluster (kind): Pod Security Admission, NetworkPolicies, OPA Gatekeeper (allowed registries, no privileged, required limits), signature verification at admission | Policy enforcement | ⏳ |
| 6 | Runtime protection: Falco rules + alert | Runtime threat detection | ⏳ |
| 7 | Azure with Terraform: AKS (private, Workload Identity, Azure Policy add-on), Key Vault (CMK, rotation), Log Analytics — scanned by Checkov | Governed cloud foundation, key management | ⏳ |
| 8 | Secrets: Key Vault → Secrets Store CSI driver via Workload Identity | No secret in Git or in images | ⏳ |
| 9 | Defender for Cloud: CSPM, Defender for Containers, DevOps security (GitHub connector) | CSPM/CWPP + pipeline telemetry | ⏳ |
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

## Quick start

```bash
brew bundle            # install the toolchain (see Brewfile)
pre-commit install     # enable local secret scanning before every commit
```
