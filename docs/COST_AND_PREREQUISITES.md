# Cost safeguards and prerequisites

**Rule: the default workflow costs $0 and needs no cloud account, no credentials and no payment details.**
Everything runs on your own computer with free, open-source tools. Paid or account-bound features exist only as
clearly disabled, documented options.

## 1. Cost safeguards built into the project

| Risk | Safeguard |
|---|---|
| Accidentally creating AWS resources | No script runs `tofu apply`. The LocalStack provider forces every endpoint to `localhost` (validated variable) with dummy `test` keys that do not work on AWS. The production root has `allowed_account_ids`, and its plan needs real credentials you would have to supply deliberately. |
| Paid managed Kubernetes / databases | None are created. Kubernetes = local kind; PostgreSQL = a container. Production equivalents are documented only. |
| GitHub Actions minutes | Public repository + GitHub-hosted standard runners = free minutes. `concurrency` cancels superseded CI runs; the release workflow runs only on version tags; timeouts on every job. |
| Registry storage | GHCR is free for public packages. Locally a `registry:3` container is used. |
| Paid monitoring/logging/security SaaS | None. Prometheus, OpenTelemetry SDK, Trivy, Syft, Cosign are open source; tracing export is off by default. |
| LocalStack licence | Pinned to the **community** image `localstack/localstack:3.8`, which starts without an auth token (newer `latest` images ask for one). Only services in the free tier are used (S3, STS, IAM, KMS, CloudWatch Logs). |
| Optional AWS evidence archive | The `archive-evidence` job in `release.yml` is skipped unless you set the repository variable `AWS_EVIDENCE_ROLE_ARN`. Default: off. |
| Sigstore | Public-good Fulcio/Rekor are free. Local signing disables the transparency log entirely (`--tlog-upload=false`). |
| Surprise downloads | Total image downloads for the full path are about 5-6 GB (kind node, Argo CD, LocalStack 2 GB, tools). |

**Things that are free but have limits:**

* **GitHub Actions** - free for public repos on standard runners; a *private* repo gets a monthly minute quota and
  then needs billing. Keep the repo public for the capstone or watch *Settings -> Billing -> Usage*.
* **Artifact attestations** (`actions/attest-build-provenance`) - available for public repos; private repos need
  GitHub Enterprise Cloud.
* **Docker Hub** - anonymous pulls are rate-limited per IP. If you hit the limit, wait or `docker login` with a free
  account.
* **Docker Desktop** - free for personal use, education and small businesses; larger companies need a paid
  subscription. On Linux, Docker Engine is always free.
* **Public transparency log** - keyless signatures are written to the public Rekor log (permanent, public). Fine for
  this open-source project.
* **Never assume a free tier is unlimited.** Nothing in the default path relies on a cloud free tier.

## 2. Prerequisites

Run the read-only checker first - it tells you which paths your machine supports:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\check_prereqs.ps1     # Windows
```
```bash
bash scripts/check_prereqs.sh                                          # macOS / Linux / Git Bash
```

| Path | What you get | Needs | Hardware |
|---|---|---|---|
| **A - Quick start** | API, 53 tests, lint, DORA/SLO data + workbooks | Python 3.12+ (3.13 recommended), Git | any laptop, ~500 MB |
| **B - Containers** | Docker image, Compose (API + Postgres + Prometheus), Trivy/Syft/Cosign pipeline, OpenTofu + LocalStack | + Docker (running), OpenTofu 1.10+ | 2 CPU, 4 GB RAM for Docker, ~4 GB disk |
| **C - Full GitOps** | kind cluster, Argo CD, Gitea, NetworkPolicy/PSA tests, load test | + kind, kubectl, Git Bash on Windows | 4 CPU, **≥ 6 GB RAM for Docker**, ~6 GB disk; first run 10-15 min |

Windows note: the `.sh` scripts run in **Git Bash** (installed with Git for Windows). PowerShell equivalents are
given for the quick-start commands.

### Installing (official, free sources only)

| Tool | Windows | macOS | Linux |
|---|---|---|---|
| Python 3.13 | `winget install Python.Python.3.13` or python.org | `brew install python@3.13` | distro package / python.org |
| Git (+ Git Bash) | `winget install Git.Git` | `brew install git` | distro package |
| Docker | Docker Desktop (`winget install Docker.DockerDesktop`) | Docker Desktop or Colima (`brew install colima docker`) | Docker Engine (docs.docker.com/engine/install) |
| kind | `winget install Kubernetes.kind` | `brew install kind` | release binary from kind.sigs.k8s.io |
| kubectl | included with Docker Desktop, or `winget install Kubernetes.kubectl` | `brew install kubectl` | kubernetes.io/docs/tasks/tools |
| OpenTofu | `winget install OpenTofu.Tofu` | `brew install opentofu` | opentofu.org/docs/intro/install |

**Not required to install:** Trivy, Syft, Cosign, kubeconform, actionlint, hadolint, promtool, LocalStack - the
scripts run their official container images (pinned by version/digest).

**Optional:** Microsoft Excel (to run `scripts/verify_workbooks.ps1`) or LibreOffice Calc (free) to open the
workbooks. Claude Code is **not** needed to run anything in this repository.

## 3. External dependencies

| Dependency | Used for | Account needed? | Cost |
|---|---|---|---|
| PyPI | Python packages | no | free |
| Docker Hub, ghcr.io, quay.io | base and tool images, Argo CD images | no (rate-limited anonymous pulls) | free |
| raw.githubusercontent.com | Argo CD install manifest (pinned v3.5.5) | no | free |
| registry.opentofu.org | AWS provider download | no | free |
| GitHub + GitHub Actions + GHCR | CI/CD, publishing (only after you push) | GitHub account | free for public repo |
| Sigstore public good | keyless signing in CI | no (uses GitHub OIDC) | free |
| AWS | **not used** by default; reference design only | yes, only if you choose to | would cost money - not part of this project |

## 4. Remaining limitations

* No real cloud deployment, by design. AWS resources are validated and planned (against LocalStack), never applied.
* `plan` for `environments/aws-production` needs real (read-only is enough) AWS credentials and the state bucket -
  not run here.
* Keyless signing, GHCR push, GitHub provenance and the GitOps PR run only when the release workflow runs on GitHub.
* Argo CD reconciles from an in-cluster Gitea copy of the repo locally; switching to GitHub needs the repo pushed
  (`deploy/argocd/application-github.yaml`).
* The local kind cluster is single-node: topology spread and PodDisruptionBudgets are configured but cannot show
  multi-node behaviour.
