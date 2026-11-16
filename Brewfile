# Toolchain for the whole project — `brew bundle` installs what is missing.
tap "hashicorp/tap"

# IaC (Homebrew core is stuck at Terraform 1.5.7 since the BSL license change)
brew "hashicorp/tap/terraform"
brew "checkov"           # IaC scanning (Terraform, Kubernetes, Dockerfile)

# Cloud, Git & Kubernetes — native arm64 builds (Intel builds under Rosetta
# fail as soon as they call git/xcrun on Apple Silicon)
brew "gh"
cask "azure-cli"         # moved from homebrew/core to a cask
brew "kubernetes-cli"    # kubectl
brew "helm"
brew "kind"
brew "hadolint"          # Dockerfile linter

# Python — uv locks dependencies for the container's platform (Linux,
# Python 3.12) from a Mac, with hashes
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
