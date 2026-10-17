# BUILD_STATUS

Last updated: 2026-10-17 (UTC). Deadline: 2026-10-25 23:59. Maintained during the build; see
[`reports/validation-report.md`](reports/validation-report.md) for test evidence.

## 1. What was inspected (read-only first)

OS/architecture, the repository and its remote, Git, Python/pip, Docker/Compose and engine state, kind, kubectl,
kube contexts and the running cluster, Helm/Argo CD/Flux CLIs, OpenTofu/Terraform, LocalStack, GitHub CLI,
security tools (Trivy, Syft, Cosign, linters), office software, disk/CPU/RAM, and earlier assignment folders.
No secrets, tokens or environment-variable values were printed.

## 2. What is installed on the build machine

| Item | Found |
|---|---|
| OS | Windows 11 Home (10.0.26300), x86_64; Git Bash (MSYS2) + PowerShell 5.1 |
| Repo | `healthqueue-capstone-`, branch `main`, **no commits yet**, remote `origin` = github.com/FarhanOsMo/healthqueue-capstone- (public, empty) |
| Git | 2.47.1 |
| Python / pip | 3.13.1 / 24.3.1 (project venv `.venv` created) |
| Docker | Docker Desktop, client/engine 29.8.0, Compose v5.5.1; engine was **stopped** -> started Docker Desktop; 14 CPUs, ~7.5 GiB for containers |
| kind / kubectl | kind v0.33.0 / kubectl v1.36.1 (bundled with Docker Desktop) |
| Existing cluster | `kind-shipfast` (Assignment 5) with Argo CD v3.5.3 + app `shipfast` - **left untouched**, still the default context |
| OpenTofu | v1.12.6 (Terraform not installed) |
| LocalStack | image `localstack/localstack:3.8` present (old container `localstack` exited - not touched) |
| Not installed | Helm, argocd CLI, flux, gh, trivy, syft, cosign, kubeconform, actionlint, hadolint, shellcheck, LibreOffice -> run as pinned containers instead; `gh` not needed locally |
| Office | Microsoft Excel 16 (used via COM to recalculate/verify the workbooks) |
| Disk | ~240 GB free on C: |
| Hardware | 14 logical CPUs, 15.4 GB RAM |

## 3. What works (verified)

Everything in the table in [`reports/validation-report.md`](reports/validation-report.md): 18/18 static checks,
53 tests (94% coverage), container build, Trivy gate, Syft SBOM, Cosign sign/attest/verify (local key), tamper
rejection, OpenTofu validate + LocalStack plan + lock test, kind + Argo CD reconciliation, self-heal, commit-driven
rollout, `git revert` rollback, NetworkPolicy, Pod Security, Compose + Prometheus, promtool alert tests, both
workbooks recalculated in Excel with all independent checks passing.

## 4. What is missing / not possible for $0

* Real AWS provisioning (forbidden by the $0 rule) - reference config validated and planned against LocalStack only.
* GitHub Actions runs, GHCR publishing, keyless Cosign, GitHub SLSA provenance - need the repository pushed
  (approval required). Workflows are linted with actionlint.
* Argo CD reconciling from GitHub - currently from an in-cluster Gitea copy (same mechanism).

## 5. What was reused from earlier work

| Earlier project | Reused / adapted |
|---|---|
| `Downloads/meridian-pay-pipeline` (CI with Trivy, Syft, Cosign keyless) | Workflow structure and the keyless-signing + identity-pinned verify pattern; **improved**: split PR vs release trust, SHA-pinned actions, post-incident Trivy pinning, SBOM attestation, GitHub provenance, `gh attestation verify`, GitOps PR |
| `Downloads/meridian-infra` (OpenTofu + LocalStack 3.8) | LocalStack 3.8 pin (community, no token) and dummy-credential provider pattern; **improved**: separate local/production roots, S3 remote state with locking (the old project committed `terraform.tfstate`), encryption/KMS/OIDC, no `apply` in CI |
| `Downloads/Assignment 5/shipfast-gitops` (Argo CD app, Deployment) | Argo CD Application layout with automated self-heal; **improved**: AppProject guard rails, Kustomize overlays, digest pinning, probes, security contexts, NetworkPolicies, PSA |
| Assignment 6 runbook (docx) | Runbook/postmortem style adapted to HealthQueue |

Nothing from Meridian Bank was copied as-is; application, metrics, SLOs and documents are HealthQueue-specific.

## 6. What was built

Application, tests, Dockerfile, Compose, two GitHub workflows + Dependabot, OpenTofu module + 3 roots, Kustomize
base/overlays, Argo CD project/apps, kind config + local Gitea, Prometheus SLO rules + tests, 2 data generators,
2 workbook builders + verifiers, bash/PowerShell helper scripts (supply chain, kind, GitOps publish/verify, OpenTofu checks, validation, prerequisites, cleanup), 6 ADRs, 5 runbooks, postmortem, architecture/observability/
supply-chain/DORA/cost/readiness docs, rubric mapping, video outline, validation report.

## 7. Needs your credentials, an external service or your approval

| Action | Why it needs you | Cost |
|---|---|---|
| `git commit` + `git push` to `origin` | publishing is your decision (commands in the final summary) | free |
| Enabling branch protection, `release` environment, "allow Actions to create PRs" | GitHub repository settings | free |
| Pushing a tag `v0.1.1` to run `release.yml` | creates public GHCR package + public Rekor entries | free for public repo |
| Real AWS `plan`/`apply` | needs an AWS account; apply costs money | **not done** |
| Recording the video | must be you, camera on | - |

## 8. Local resources currently running (all free, local)

| Resource | Remove with |
|---|---|
| kind cluster `healthqueue` (Argo CD, Gitea, API, PostgreSQL) | `bash scripts/cleanup.sh` |
| container `kind-registry` (local registry, label project=healthqueue) | same |
| container `hq-localstack` (LocalStack 3.8) | `docker rm -f hq-localstack` or cleanup script |
| Your `kind-shipfast` cluster | untouched |

## Build log (decisions and fixes)

1. Docker engine was stopped -> started Docker Desktop (local, free).
2. Chose a **dedicated** kind cluster with its own kubeconfig instead of modifying `kind-shipfast`.
3. Trivy gate failed on pip's vendored urllib3/msgpack (HIGH) -> removed pip from runtime image (no ignore lists).
4. Trivy IaC flagged the state bucket using an AWS-managed key -> added a customer-managed KMS key.
5. Trivy IaC flagged Gitea without read-only root FS -> fixed and redeployed.
6. Cosign v3 offline signing needed `--use-signing-config=false`; empty-repo `git rev-parse` broke provenance JSON -> fixed.
7. A Git Bash path bug wrote the kubeconfig to `C:\c\...` -> moved it, removed the stray folder, scripts use native paths.
8. GitOps verify script had a stale-value wait loop -> fixed; added a positive-control probe for the NetworkPolicy test.
9. **Local load test found a latency SLO breach (85.4% ≤ 300 ms)** -> connection pool in v0.1.1 -> 100% after a GitOps rollout.
10. DORA finding text claimed a single top failure cause while two were tied -> corrected; removed an unsupported claim.
11. Secret scan initially scanned git-ignored local secrets -> now scans exactly the committable files; one public GPG
    fingerprint allow-listed with justification.
