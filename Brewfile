# Toolchain for the whole project — `brew bundle` installs what is missing.
tap "hashicorp/tap"

# IaC (Homebrew core is stuck at Terraform 1.5.7 since the BSL license change)
brew "hashicorp/tap/terraform"
brew "checkov"           # IaC scanning (Terraform, Kubernetes, Dockerfile)

# Containers & Kubernetes (kubectl, helm, kind, docker already installed)
brew "hadolint"          # Dockerfile linter

# Supply chain
brew "trivy"             # SCA + image + misconfig scanning
brew "syft"              # SBOM generation
brew "cosign"            # image signing / verification
brew "jfrog-cli"         # `jf` — Artifactory

# Shift-left
brew "gitleaks"          # secret detection
brew "semgrep"           # SAST
brew "pre-commit"
