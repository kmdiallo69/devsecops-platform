#!/usr/bin/env bash
# Verifies a released image BY DIGEST: signature, SBOM attestations and SLSA
# build provenance — each must have been produced by this repository's
# release workflow, on main, through GitHub's OIDC issuer. Anything else
# (another repo, a fork, a branch, a tag instead of a digest) fails.
#
#   scripts/verify-release.sh ghcr.io/<owner>/llm-gateway@sha256:...
#   scripts/verify-release.sh 127.0.0.1:8085/docker/<owner>/llm-gateway@sha256:...
#
# The second form verifies the copy served by Artifactory (docker login to
# it first): the signatures travel with the image through the proxy.
set -euo pipefail

REF="${1:?usage: $0 <image>@sha256:<digest>}"
[[ "$REF" == *@sha256:* ]] || { echo "Refusing a tag: pass <image>@sha256:<digest>" >&2; exit 1; }
IMAGE="${REF%@*}"
DIGEST="${REF#*@}"

REPO="${REPO:-kmdiallo69/devsecops-platform}"
IDENTITY="https://github.com/${REPO}/.github/workflows/release.yml@refs/heads/main"
ISSUER="https://token.actions.githubusercontent.com"

# Classic signature format (tags), as produced by release.yml.
COSIGN=(--new-bundle-format=false
        --certificate-identity "$IDENTITY"
        --certificate-oidc-issuer "$ISSUER")
case "$IMAGE" in 127.0.0.1*|localhost*) COSIGN+=(--allow-http-registry) ;; esac

echo "== Signature (index)"
cosign verify "${COSIGN[@]}" "$REF" >/dev/null
echo "OK — signed by ${IDENTITY}"

# Platform digests read from GHCR: a digest is the same in every registry,
# and GHCR is plain HTTPS (no insecure-registry setup for the local proxy).
GHCR_REF="ghcr.io/${REPO%%/*}/llm-gateway@${DIGEST}"

echo "== SBOM attestation (SPDX), per platform"
manifests="$(docker buildx imagetools inspect --raw "$GHCR_REF")"
for arch in amd64 arm64; do
  pdigest="$(python3 -c 'import json,sys; print(next(m["digest"] for m in json.load(sys.stdin)["manifests"] if m["platform"]["architecture"] == sys.argv[1]))' "$arch" <<<"$manifests")"
  cosign verify-attestation "${COSIGN[@]}" --type spdxjson "${IMAGE}@${pdigest}" >/dev/null
  echo "OK — linux/${arch}"
done

# Provenance is looked up on GitHub by digest — the same digest, whichever
# registry served the image.
echo "== SLSA build provenance"
gh attestation verify "oci://${GHCR_REF}" \
  --repo "$REPO" \
  --signer-workflow "${REPO}/.github/workflows/release.yml" \
  --source-ref refs/heads/main >/dev/null
echo "OK"
