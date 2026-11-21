# Artifactory setup

Run from `platform/local/artifactory/`. Every secret goes to the OS keychain
(`security` on macOS) — never to a file in the repo or the shell history.

## 1. Start the stack

```bash
echo "POSTGRES_PASSWORD=$(openssl rand -base64 24)" > .env
docker compose up -d
until curl -sf 127.0.0.1:8082/artifactory/api/system/ping; do sleep 5; done; echo
```

First start takes ~2 minutes.

## 2. First login (UI)

Open http://127.0.0.1:8082 (not `localhost`: the port is bound to IPv4
only, and browsers trying `::1` first make the UI very slow), log in as
`admin` / `password`.

- Change the admin password when prompted (store it in your password manager).
- Accept the EULA.
- Skip the onboarding wizard — **do not** let it create default
  repositories; they are defined in `config/repositories.yml`.

## 3. Admin token for configuration as code

Requested from the API and piped straight into the keychain: the token is
never displayed, copied to the clipboard or written to the shell history.
`curl -u admin` prompts for the admin password interactively. Valid 30 days.

```bash
TOKEN=$(curl -sS --fail-with-body -u admin -X POST http://127.0.0.1:8082/artifactory/api/security/token -d username=admin --data-urlencode 'scope=member-of-groups:*' -d expires_in=2592000 | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')
security add-generic-password -U -a "$USER" -s jfrog-admin -w "$TOKEN"
unset TOKEN
```

Why not copy a token from the UI: the interactive `-w` prompt of `security`
silently truncates input at 128 characters, and copying from the token
dialog by hand easily grabs a partial value — both end in
`401 Props Authentication Token not found`.

## 4. Apply the repositories

```bash
./apply-config.sh
```

Expected: `docker`, `dockerhub-remote`, `ghcr-remote`, `images-local`.

## 5. Machine identities (UI — user/permission APIs are Pro only)

Generate each password into the keychain:

```bash
security add-generic-password -a "$USER" -s jfrog-publisher -w "$(openssl rand -base64 24)"
security add-generic-password -a "$USER" -s jfrog-cluster-reader -w "$(openssl rand -base64 24)"
```

To set it in the UI, copy it straight to the clipboard, paste, then clear
the clipboard. Two traps both end in `Bad Credentials` at `docker login`:

- never select the password on screen: base64 contains `/` and `+`, where
  a double-click selection stops, giving a partial password;
- use a **private window** and press **⌘A before ⌘V** in each password
  field: the browser autofills the saved admin password there, and a plain
  paste is appended to it instead of replacing it.

```bash
security find-generic-password -s jfrog-publisher -w | tr -d '\n' | pbcopy
pbcopy < /dev/null
```

Check that both identities authenticate (prints only the HTTP code; 200 = OK):

```bash
for u in cluster-reader publisher; do printf '%s: ' $u; curl -s -o /dev/null -w '%{http_code}\n' -u "$u:$(security find-generic-password -s jfrog-$u -w)" http://127.0.0.1:8082/artifactory/api/security/encryptedPassword; done
```

**Administration → User Management → Users → New User**, twice:

| Username | Password | Settings |
|---|---|---|
| `publisher` | keychain `jfrog-publisher` | *Disable UI access* ✔, *Can update profile* ✘ |
| `cluster-reader` | keychain `jfrog-cluster-reader` | *Disable UI access* ✔, *Can update profile* ✘ |

**Administration → User Management → Permissions → New Permission**:

| Permission | Repositories | User | Actions |
|---|---|---|---|
| `publisher-images-local` | `images-local` | `publisher` | Read, Annotate, Deploy/Cache — **not** Delete/Overwrite |
| `cluster-reader-local` | `images-local` | `cluster-reader` | Read |
| `cluster-reader-remotes` | `ghcr-remote`, `dockerhub-remote` | `cluster-reader` | Read, Deploy/Cache |

Why *Deploy/Cache* on the remotes for a read-only consumer: pulling an image
that is not cached yet makes Artifactory **cache** it, and caching needs that
action. On remote repositories it cannot be used to upload anything.

**Remove the installer defaults** — otherwise least privilege is silently
broken:

- **Permissions**: delete `Anything` (Read on every repository, granted to
  the `readers` group) and `Any Remote`.
- **Groups → `readers`**: untick *Automatically Join New Users*, remove
  `publisher` and `cluster-reader` from it.

## 6. Prove the controls

Docker clients use the proxy on `127.0.0.1:8085` (see `nginx.conf`).

```bash
REG=127.0.0.1:8085/docker

# Anonymous access is refused (a curl on /v2/ is not proof: the registry
# token flow always answers 401 first, even with anonymous access on)
docker logout 127.0.0.1:8085
docker pull -q $REG/library/python:3.12-slim

# Allowlist: python allowed, everything else refused
security find-generic-password -s jfrog-cluster-reader -w | docker login 127.0.0.1:8085 -u cluster-reader --password-stdin
docker pull -q $REG/library/python:3.12-slim
docker pull -q $REG/library/nginx:latest
docker pull -q $REG/someuser/python:latest

# Read-only identity cannot push
docker tag llm-gateway:dev $REG/llm-gateway:0.1.0
docker push -q $REG/llm-gateway:0.1.0

# Publisher can push a new tag...
security find-generic-password -s jfrog-publisher -w | docker login 127.0.0.1:8085 -u publisher --password-stdin
docker push -q $REG/llm-gateway:0.1.0

docker push -q $REG/llm-gateway:0.1.0 --platform linux/$(docker version -f '{{.Server.Arch}}')

# ...but cannot overwrite it with a different image (immutability)
docker tag $REG/library/python:3.12-slim $REG/llm-gateway:0.1.0
docker push -q $REG/llm-gateway:0.1.0 --platform linux/$(docker version -f '{{.Server.Arch}}')

docker logout 127.0.0.1:8085
```

Expected, in order: anonymous pull *unauthorized* · python pulled · nginx *not found* ·
someuser/python *not found* · cluster-reader push *denied* · publisher push
OK · overwrite *denied* (`needs DELETE permission`).

**Known limit — found by this test.** Artifactory enforces "no
Delete/Overwrite" on **files**, not on Docker tags. A multi-platform index
is stored as `list.manifest.json`, a single-platform image as
`manifest.json`: pushing the *other* format to an existing tag creates a new
file next to the old one and is accepted. Hence the `--platform` flag above
(one format, always), and why tag immutability is not the last line of
defense: workloads are deployed **by digest** and their **Cosign signature
is verified at admission** (roadmap steps 4–5).

Cleanup (admin only — `publisher` cannot delete):

```bash
curl -sS -o /dev/null -w '%{http_code}\n' -X DELETE -H "Authorization: Bearer $(security find-generic-password -s jfrog-admin -w)" http://127.0.0.1:8082/artifactory/images-local/llm-gateway/0.1.0
```
