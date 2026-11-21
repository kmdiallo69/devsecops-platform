#!/usr/bin/env bash
# Applies config/repositories.yml to Artifactory (YAML configuration PATCH).
#
# Auth: an admin access token read from the OS keychain — never from a file,
# an argument or the shell history. Store it once with:
#   security add-generic-password -a "$USER" -s jfrog-admin -w
# Or export JFROG_ACCESS_TOKEN yourself (e.g. on Linux, from a secret store).
set -euo pipefail

# 127.0.0.1, not localhost: the ports are bound to IPv4 only, and clients
# that try ::1 first for "localhost" wait for that attempt to fail.
JFROG_URL="${JFROG_URL:-http://127.0.0.1:8082}"
CONFIG="$(dirname "$0")/config/repositories.yml"

if ! curl -sf -m 5 "${JFROG_URL}/artifactory/api/system/ping" >/dev/null; then
  echo "Artifactory is not reachable at ${JFROG_URL} — start it first (SETUP.md §1)." >&2
  exit 1
fi

if [[ -z "${JFROG_ACCESS_TOKEN:-}" ]]; then
  if ! JFROG_ACCESS_TOKEN="$(security find-generic-password -s jfrog-admin -w 2>/dev/null)"; then
    echo "No admin token: set JFROG_ACCESS_TOKEN or store one in the keychain" >&2
    echo "as service 'jfrog-admin' (SETUP.md §3)." >&2
    exit 1
  fi
fi

curl --fail-with-body -sS -X PATCH \
  -H "Authorization: Bearer ${JFROG_ACCESS_TOKEN}" \
  -H "Content-Type: application/yaml" \
  --data-binary "@${CONFIG}" \
  "${JFROG_URL}/artifactory/api/system/configuration"
echo

echo "Repositories now configured:"
curl --fail-with-body -sS \
  -H "Authorization: Bearer ${JFROG_ACCESS_TOKEN}" \
  "${JFROG_URL}/artifactory/api/repositories" |
  python3 -c "import json,sys; [print(f\"  {r['key']:<18} {r['type']:<8} {r['packageType']}\") for r in json.load(sys.stdin)]"
