"""Architecture diagram as code — regenerate after any change to the platform.

    pip install diagrams          # needs Graphviz (`brew install graphviz`)
    cd docs/architecture && python architecture.py

Writes architecture.png next to this file, then quantizes it to 128
colours (Pillow) to stay under the repository's large-file hook. Project logos that the
`diagrams` library does not ship are in icons/ (each from the project's own
repository or the CNCF artwork repository).
"""

from pathlib import Path

from diagrams import Cluster, Diagram, Edge
from diagrams.azure.aimachinelearning import AzureOpenai
from diagrams.azure.containers import KubernetesServices
from diagrams.azure.identity import ManagedIdentities
from diagrams.azure.managementgovernance import Policy
from diagrams.azure.monitor import LogAnalyticsWorkspaces
from diagrams.azure.network import ApplicationGateway, PrivateEndpoint
from diagrams.azure.networking import Nat, NetworkSecurityGroups
from diagrams.azure.security import KeyVaults, MicrosoftDefenderForCloud
from diagrams.azure.storage import StorageAccounts
from diagrams.custom import Custom
from diagrams.k8s.compute import Pod
from diagrams.k8s.network import NetworkPolicy, Service
from diagrams.k8s.podconfig import Secret
from diagrams.onprem.ci import GithubActions
from diagrams.onprem.client import Users
from diagrams.onprem.container import Docker
from diagrams.onprem.iac import Terraform
from diagrams.onprem.registry import Jfrog
from diagrams.onprem.security import Trivy
from diagrams.generic.storage import Storage
from diagrams.onprem.vcs import Git, Github
from diagrams.programming.framework import Fastapi
from diagrams.programming.language import Python

ICONS = Path(__file__).parent / "icons"


def icon(label: str, name: str):
    return Custom(label, str(ICONS / f"{name}.png"))


graph = {"fontsize": "22", "splines": "spline", "pad": "0.4", "nodesep": "0.45", "ranksep": "0.9", "labelloc": "t"}
node = {"fontsize": "12"}

with Diagram(
    "DevSecOps platform — from commit to runtime",
    filename=str(Path(__file__).parent / "architecture"),
    outformat="png",
    show=False,
    direction="LR",
    graph_attr=graph,
    node_attr=node,
):
    users = Users("Clients")

    with Cluster("Developer workstation"):
        dev_hooks = Git("pre-commit\nGitleaks")
        tf = Terraform("Terraform\n(operator)")

    with Cluster("GitHub — protected main, 9 required checks"):
        repo = Github("Repository")
        with Cluster("Security CI  (permissions: {}, actions pinned by SHA)"):
            ci = GithubActions("security-ci")
            ci_tools = [
                icon("Semgrep\nSAST", "semgrep"),
                Python("pip-audit\nSCA"),
                icon("Checkov\nIaC", "checkov"),
                Docker("Hadolint\nDockerfile"),
                Trivy("Trivy\nimage scan"),
            ]
        with Cluster("Release  (OIDC, no stored keys)"):
            release = GithubActions("release")
            syft = Storage("Syft\nSBOM per platform")
            cosign = icon("Cosign keyless\n+ SLSA provenance", "cosign")

    with Cluster("Registries & transparency"):
        ghcr = Github("GHCR\nsigned image")
        rekor = icon("Sigstore\nFulcio · Rekor", "rekor")
        jfrog = Jfrog("Artifactory\nsingle entry point")

    with Cluster("Local lab (kind)"):
        kind = icon("kind cluster", "kind")
        gatekeeper = icon("Gatekeeper\nregistries · digest · limits", "opa")
        kyverno = icon("Kyverno\nsignature check", "kyverno")
        falco = icon("Falco\nruntime rules", "falco")

    with Cluster("Azure subscription"):
        defender = MicrosoftDefenderForCloud("Defender for Cloud\nCSPM · Containers · KV")
        policy = Policy("Azure Policy\nrestricted · allowed images")
        logs = LogAnalyticsWorkspaces("Log Analytics")
        state = StorageAccounts("Terraform state\nEntra-only · locked")

        with Cluster("VNet  (NSG per subnet, deny by default)"):
            waf = ApplicationGateway("App Gateway WAF_v2\nOWASP CRS · bots · rate limit")
            nsg = NetworkSecurityGroups("NSGs")
            nat = Nat("NAT Gateway\nfixed egress IP")
            pe = PrivateEndpoint("Private endpoint")
            kv = KeyVaults("Key Vault\nCMK · purge protection")

            with Cluster("Private AKS  (no public API, Entra ID + Azure RBAC, KMS etcd)"):
                aks = KubernetesServices("AKS")
                ilb = Service("Internal LB")
                netpol = NetworkPolicy("NetworkPolicies\ndefault deny")
                with Cluster("llm-gateway  (restricted, non-root, read-only FS)"):
                    gw = [Pod("pod"), Pod("pod")]
                    app = Fastapi("Guardrails\nOWASP LLM Top 10")
                csi = Secret("Secrets Store CSI\nkey as a file")
                wi = ManagedIdentities("Workload Identity")
                sensor = MicrosoftDefenderForCloud("Defender sensor")

    llm = AzureOpenai("Model provider\nOpenAI-compatible")

    # Code to image
    dev_hooks >> repo >> ci
    for t in ci_tools:
        ci - Edge(style="dotted") - t
    repo >> Edge(label="merge to main") >> release
    release >> syft
    release >> cosign >> rekor
    release >> Edge(label="signed image, SBOM, provenance") >> ghcr >> jfrog

    # Image to clusters
    jfrog >> Edge(label="digest-pinned pull") >> kind
    kind - gatekeeper
    kind - kyverno
    kind - falco
    jfrog >> Edge(label="digest-pinned pull") >> aks

    # Infrastructure
    tf >> Edge(style="dashed", label="plan / apply") >> state
    tf >> Edge(style="dashed") >> aks

    # Request path
    users >> Edge(label="HTTPS", color="darkgreen", penwidth="2") >> waf
    waf >> Edge(color="darkgreen", penwidth="2") >> ilb >> Edge(color="darkgreen", penwidth="2") >> gw[0]
    gw[0] - app
    gw >> Edge(color="darkgreen") >> nat >> Edge(label="HTTPS", color="darkgreen") >> llm
    aks - netpol
    nsg - Edge(style="dotted") - waf

    # Secrets
    csi >> Edge(label="federated token", color="firebrick") >> wi
    wi >> Edge(color="firebrick") >> pe >> Edge(color="firebrick") >> kv
    csi >> Edge(color="firebrick") >> gw[1]

    # Governance and detection
    policy >> Edge(style="dashed", label="admission") >> aks
    sensor >> Edge(style="dashed") >> defender
    aks - sensor
    waf >> Edge(style="dotted") >> logs
    aks >> Edge(style="dotted") >> logs

# Same picture, a third of the bytes: a flat diagram needs no 24-bit colour.
from PIL import Image  # noqa: E402

png = Path(__file__).parent / "architecture.png"
Image.open(png).convert("RGB").quantize(colors=128, dither=Image.Dither.NONE).save(png, optimize=True)
