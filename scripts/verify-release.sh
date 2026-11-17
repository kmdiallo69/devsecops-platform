#!/usr/bin/env bash
# Verifies a released image BY DIGEST: signature, SBOM attestation and SLSA
# build provenance — each must have been produced by this repository's
# release workflow, on main, through GitHub's OIDC issuer. Anything else
# (another repo, a fork, a branch, a tag instead of a digest) fails.
#
#   scripts/verify-release.sh ghcr.io/<owner>/llm-gateway@sha256:...
set -euo pipefail

REF="${1:?usage: $0 <image>@sha256:<digest>}"
[[ "$REF" == *@sha256:* ]] || { echo "Refusing a tag: pass <image>@sha256:<digest>" >&2; exit 1; }

REPO="${REPO:-kmdiallo69/devsecops-platform}"
IDENTITY="https://github.com/${REPO}/.github/workflows/release.yml@refs/heads/main"
ISSUER="https://token.actions.githubusercontent.com"

echo "== Signature"
cosign verify "$REF" \
  --certificate-identity "$IDENTITY" \
  --certificate-oidc-issuer "$ISSUER" >/dev/null
echo "OK — signed by ${IDENTITY}"

echo "== SBOM attestation (SPDX)"
cosign verify-attestation "$REF" --type spdxjson \
  --certificate-identity "$IDENTITY" \
  --certificate-oidc-issuer "$ISSUER" >/dev/null
echo "OK"

echo "== SLSA build provenance"
gh attestation verify "oci://${REF}" \
  --repo "$REPO" \
  --signer-workflow "${REPO}/.github/workflows/release.yml" \
  --source-ref refs/heads/main >/dev/null
echo "OK"
