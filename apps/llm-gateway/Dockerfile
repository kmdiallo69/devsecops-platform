# =============================================================================
# LLM gateway — multi-stage, non-root, hash-verified dependencies, no pip
# =============================================================================
# Base image pinned by DIGEST: a tag like 3.12-slim is re-pointed upstream
# at any time. The tag stays for humans (and for Dependabot, which bumps
# the digest weekly through a normal, gated PR).

# --- Stage 1: builder ---------------------------------------------------------
FROM python:3.12-slim@sha256:5e2bdb1b0d542d5039cffb8181c65930093949194a65c365dfb1b0fe13a4fa5b AS builder

ENV PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

RUN python -m venv /opt/venv
WORKDIR /build
COPY requirements.txt .
# --require-hashes: every package (including transitive ones) must match the
# sha256 recorded in requirements.txt — a tampered or substituted package on
# the index fails the build instead of shipping.
# Then remove pip from the venv: `python -m venv` seeds it with its OWN pip,
# so removing pip from the base image alone is not enough (found by testing:
# `python -m pip` still worked in the running container, from /opt/venv).
RUN /opt/venv/bin/pip install --require-hashes -r requirements.txt \
 && /opt/venv/bin/python -m pip uninstall -y pip

# --- Stage 2: runtime ---------------------------------------------------------
FROM python:3.12-slim@sha256:5e2bdb1b0d542d5039cffb8181c65930093949194a65c365dfb1b0fe13a4fa5b AS runtime

# apt-get upgrade: official base images lag behind distro security fixes
# (found by CI: zlib1g CVE-2026-85091 was fixed in Debian, but not yet in
# python:3.12-slim). Patching at build time closes that gap; the apt lists
# are deleted so they do not bloat the image.
# pip is not needed at runtime: removing it means an attacker with code
# execution cannot simply `pip install` their tooling, and it is one less
# package for scanners to flag.
RUN apt-get update \
 && apt-get upgrade -y --no-install-recommends \
 && rm -rf /var/lib/apt/lists/* \
 && python -m pip uninstall -y pip \
 && groupadd --gid 10001 app \
 && useradd --uid 10001 --gid 10001 --no-create-home --shell /usr/sbin/nologin app

COPY --from=builder /opt/venv /opt/venv
WORKDIR /srv
COPY app/ ./app/

ENV PATH="/opt/venv/bin:$PATH" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# Numeric UID, not a name: Kubernetes `runAsNonRoot: true` can only verify a
# numeric user — with `USER app` the kubelet refuses to start the pod.
USER 10001:10001

EXPOSE 8000

HEALTHCHECK --interval=15s --timeout=3s --start-period=5s --retries=3 \
  CMD ["python", "-c", "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/healthz', timeout=2).status == 200 else 1)"]

# --no-server-header: do not advertise the server software/version.
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--no-server-header"]
