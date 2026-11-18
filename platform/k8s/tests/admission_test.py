#!/usr/bin/env python3
"""Proves the admission controls against the live cluster.

Each case is the same compliant pod with exactly ONE thing broken, sent
with `kubectl apply --dry-run=server`: the request goes through the real
admission chain (Pod Security Admission, Gatekeeper, Kyverno) but nothing
is ever created. Exit code 1 if any control does not behave as expected.

    python3 platform/k8s/tests/admission_test.py
"""

import copy
import json
import subprocess
import sys

NAMESPACE = "llm-gateway"
REGISTRY = "registry.local:8085/docker"
SIGNED = f"{REGISTRY}/kmdiallo69/llm-gateway@sha256:2d03281013ea2d98f3cec22c2fc5940b42863fd98ef83e9bd0f451b28898976e"
SIGNED_TAG = f"{REGISTRY}/kmdiallo69/llm-gateway:sha-ea618c57981e666aa53b6eaf3ae1b0f3fd19718a"
PYTHON_DIGEST = "sha256:5e2bdb1b0d542d5039cffb8181c65930093949194a65c365dfb1b0fe13a4fa5b"

BASE_POD = {
    "apiVersion": "v1",
    "kind": "Pod",
    "metadata": {"name": "admission-test", "namespace": NAMESPACE},
    "spec": {
        "automountServiceAccountToken": False,
        "imagePullSecrets": [{"name": "artifactory-pull"}],
        "securityContext": {
            "runAsNonRoot": True,
            "runAsUser": 10001,
            "seccompProfile": {"type": "RuntimeDefault"},
        },
        "containers": [
            {
                "name": "app",
                "image": SIGNED,
                "securityContext": {
                    "allowPrivilegeEscalation": False,
                    "readOnlyRootFilesystem": True,
                    "capabilities": {"drop": ["ALL"]},
                },
                "resources": {"limits": {"cpu": "100m", "memory": "64Mi"}},
            }
        ],
    },
}


def pod(**container_changes):
    p = copy.deepcopy(BASE_POD)
    c = p["spec"]["containers"][0]
    for key, value in container_changes.items():
        if value is None:
            c.pop(key, None)
        else:
            c[key] = value
    return p


def privileged_pod():
    p = pod()
    p["spec"]["containers"][0]["securityContext"] = {"privileged": True}
    return p


def namespace_without_psa():
    return {"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": "no-psa-label"}}


# (description, manifest, expected to be admitted, control(s) expected to act)
# Where two controls overlap on purpose (defense in depth), either may answer:
# the API server calls the webhooks in parallel and returns the first denial.
CASES = [
    ("signed release, by digest, compliant", pod(), True, "-"),
    ("same signed image, by TAG", pod(image=SIGNED_TAG), False, "Gatekeeper|Kyverno"),
    ("Docker Hub directly (bypasses Artifactory)", pod(image=f"docker.io/library/python@{PYTHON_DIGEST}"), False, "Gatekeeper|Kyverno"),
    ("allowlisted in Artifactory but UNSIGNED", pod(image=f"{REGISTRY}/library/python@{PYTHON_DIGEST}"), False, "Kyverno"),
    ("no CPU/memory limits", pod(resources=None), False, "Gatekeeper"),
    ("privileged container", privileged_pod(), False, "Pod Security"),
    ("namespace without the PSA label", namespace_without_psa(), False, "Gatekeeper"),
]


def admit(manifest):
    r = subprocess.run(
        ["kubectl", "apply", "--dry-run=server", "-f", "-"],
        input=json.dumps(manifest), capture_output=True, text=True,
    )
    return r.returncode == 0, (r.stdout + r.stderr).strip()


def reason(output):
    for marker in ("denied the request:", "is forbidden:"):
        if marker in output:
            return output.split(marker, 1)[1].strip().splitlines()[0][:150]
    return output.splitlines()[0][:150] if output else ""


# How each control identifies itself in a denial. A refusal that matches
# none of them (e.g. "failed calling webhook": the controller is down) is
# NOT a policy decision, and must not count as a pass.
SIGNATURES = {
    "Gatekeeper": 'validation.gatekeeper.sh" denied the request',
    "Kyverno": "kyverno",
    "Pod Security": "violates PodSecurity",
}


def main():
    failures = 0
    for description, manifest, expected, control in CASES:
        admitted, output = admit(manifest)
        if expected:
            ok = admitted
        else:
            ok = (not admitted and "failed calling webhook" not in output
                  and any(SIGNATURES[c] in output for c in control.split("|")))
        failures += not ok
        verdict = "admitted" if admitted else "REFUSED"
        print(f"[{'PASS' if ok else 'FAIL'}] {description:<45} {verdict:<9} (expected: {control})")
        if not admitted or not ok:
            print(f"         {reason(output)}")
    print(f"\n{len(CASES) - failures}/{len(CASES)} controls behaved as expected")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
