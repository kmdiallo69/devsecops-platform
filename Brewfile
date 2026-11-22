# Toolchain for the whole project — `brew bundle` installs what is missing.
tap "hashicorp/tap"
tap "azure/kubelogin"

# IaC
brew "hashicorp/tap/terraform"
brew "checkov"           # IaC scanning (Terraform, Kubernetes, Dockerfile)

# Cloud, Git & Kubernetes
brew "gh"
cask "azure-cli"
brew "azure/kubelogin/kubelogin" # kubectl sign-in through Entra ID (AKS without local accounts)
brew "kubernetes-cli"    # kubectl
brew "helm"
brew "kind"
brew "hadolint"          # Dockerfile linter

# Python — uv locks dependencies for the container's platform (Linux,
# Python 3.12) regardless of the developer's OS, with hashes
brew "uv"

# Supply chain
brew "trivy"             # SCA + image + misconfig scanning
brew "syft"              # SBOM generation
brew "cosign"            # image signing / verification
brew "jfrog-cli"         # `jf` — Artifactory

# Shift-left
brew "gitleaks"          # secret detection
brew "semgrep"           # SAST
brew "pre-commit"
brew "graphviz"          # renders docs/architecture (diagrams as code)
