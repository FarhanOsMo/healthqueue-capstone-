# Rubric mapping and self-audit (150 points)

Status key: ✅ done + evidence · 🟡 done but not executed in its real environment · ⏳ needs the student · ❌ not done.
Evidence paths are relative to the repository root. Scores are **provisional self-assessments**, not a guarantee.

## Assignment requirements -> implementation -> evidence

| # | Requirement | Implementation | Evidence | Status | Limitation / to reach Exemplary |
|---|---|---|---|---|---|
| R1 | CI/CD with automated build + test | `.github/workflows/ci.yml` (lint, SAST, pip-audit, pytest + Postgres, image build) | `reports/validation/*.txt` (local equivalents), actionlint pass | 🟡 | Push the repo so the workflow runs; screenshot the green run |
| R2 | Vulnerability scanning | Trivy image gate (fixable HIGH/CRITICAL) + Trivy IaC scan, digest-pinned post-incident Trivy | `reports/supply-chain/trivy-image-report.txt`, `reports/validation/trivy-config.txt` | ✅ | - |
| R3 | SBOM generation | Syft SPDX + CycloneDX; SBOM signed attestation | `reports/supply-chain/sbom.*.json` | ✅ | - |
| R4 | Artifact signing | Cosign keyless in `release.yml`; local key-based demo + verify + tamper test | `reports/supply-chain/cosign-*.json/txt` | ✅ local / 🟡 keyless | Run `release.yml` once (tag `v0.1.1`) |
| R5 | OpenTofu provisioning ≥ 2 cloud resources with state management | Module: KMS key+alias, S3 bucket (+6 config resources), CloudWatch log group, OIDC provider, IAM role+policy (13 resources); S3 backend + `use_lockfile`; bootstrap state bucket | `infra/`, `reports/opentofu/` (validate, plan 13 to add, lock blocked, force-unlock) | ✅ validated + planned / ❌ never applied (by $0 rule) | Real AWS apply intentionally not done; LocalStack ≠ AWS |
| R6 | Containerized appointment API deployed to K8s via Argo CD/Flux reconciliation | FastAPI app, Dockerfile, Kustomize, Argo CD Application with prune + self-heal | `reports/k8s/gitops-verification.txt` (14/14 PASS) | ✅ (source = in-cluster Gitea) | Switch to `application-github.yaml` after pushing and show it syncing from GitHub |
| R7 | Observability plan: SLIs, SLOs, error budget calculation | `docs/observability-plan.md`, `reports/slo-error-budget.xlsx`, Prometheus rules + promtool tests | Excel verify (14/14 checks), promtool 5/5 | ✅ | Monitoring stack not deployed in-cluster |
| R8 | Synthetic 90-day DORA data + analysis vs elite/high/medium/low | `scripts/generate_dora_data.py`, `data/dora_deployments.csv`, `reports/dora-analysis.xlsx`, `docs/dora-analysis.md` | Excel verify (41/41 checks), reproducibility test | ✅ | Benchmarks from DORA 2024 (2025 removed tiers) - stated |
| R9 | Supply chain summary with SLSA alignment | `docs/supply-chain-security.md` | SLSA v1.2 references + GitHub docs; status per control | ✅ | No level claimed until release run |
| R10 | Docs: architecture diagrams, runbooks, ADRs, README | `README.md`, `docs/architecture.md` (4 Mermaid diagrams + 1 in README), 6 ADRs, 5 runbooks, postmortem | link check | ✅ | - |
| R11 | 8-10 min camera-on video | `docs/video-walkthrough-outline.md` (timestamps + checklist) | - | ⏳ | **You must record it** (face visible throughout) |
| R12 | GitHub repository with artifacts | All files ready locally; remote is empty | `git status` | ⏳ | Commit + push (commands in the final summary) |

## Category 1 - CI/CD Pipeline with Supply Chain Security (provisional 26/30)

**Supports the score:** separate untrusted-PR and trusted-release workflows; least-privilege permissions per job;
actions pinned to full SHAs; Trivy gate that actually failed and was fixed at the root; SBOM in two formats; keyless
signing + SBOM attestation + GitHub SLSA provenance + three verifications in CI; GitOps PR pinning the verified digest;
local pipeline proves sign/attest/verify and tamper rejection; Dependabot; secret scan clean.

**Prevents full marks:** the GitHub workflows have **not run yet** (repo not pushed) - CI pass, keyless signature
and provenance are unproven in their real environment. No admission control in the cluster. SLSA L3 not reached.

**To reach Exemplary:** push, let `ci.yml` run green, tag `v0.1.1` so `release.yml` publishes/signs/attests/verifies;
save the run URL + `gh attestation verify` output into `reports/`.

## Category 2 - Infrastructure as Code and GitOps Deployment (provisional 27/30)

**Supports:** reusable module with secure defaults (KMS rotation, versioning, SSE-KMS, public access block, TLS-only,
lifecycle, `prevent_destroy`, `allowed_account_ids`, default tags), separate LocalStack and production roots, remote
S3 state with native locking **tested** (lock contention + force-unlock), recovery procedures; Argo CD reconciliation
genuinely tested end-to-end (sync, self-heal, change, rollback, image update) with AppProject guard rails,
digest-pinned images, probes, limits, PSA, NetworkPolicies, PDB, non-root read-only containers.

**Prevents full marks:** nothing applied to real AWS (by design) and no real-account plan; Argo CD sources from a local
Gitea copy rather than GitHub; single-node kind.

**To reach Exemplary:** after pushing, apply `deploy/argocd/application-github.yaml` and show Argo CD syncing from
GitHub; optionally a PR in GitHub changing replicas, merged and synced, on video.

## Category 3 - DORA Metrics Analysis and Toil Reduction (provisional 28/30)

**Supports:** reproducible 90-day dataset (fixed seed, byte-identical test), clear window and units, all four metrics
with medians and tails, per-phase trend + weekly charts, cited 2024 benchmarks incl. the non-monotonic CFR caveat and
the 2025 change, formula-driven classification, failure/remediation analysis, toil inventory with quantified savings,
recommendations tied to specific metrics, honest small-sample and survey-vs-records limitations, 41 independent checks.

**Prevents full marks:** data is synthetic (required by the assignment, but limits insight); benchmark values come
from the report's cluster table via secondary confirmation (Octopus Deploy summary) - verify against the PDF.

**To reach Exemplary:** open the 2024 DORA report PDF and add the page number of the cluster table to `Benchmarks`.

## Category 4 - Observability and SRE Reliability Evaluation (provisional 28/30)

**Supports:** three SLIs with numerators/denominators/exclusions/windows; SLO rationale; time-based (43.2 min) and
request-based budgets kept separate; workbook with consumed/remaining, conditional formatting, charts, policy,
explanation and checks; multi-window burn-rate alerts unit-tested; metrics/logs/traces with privacy controls; runbook;
blameless postmortem; **real local measurement found and fixed a latency SLO breach**.

**Prevents full marks:** Prometheus/Alertmanager/Grafana not running inside the cluster; no Grafana dashboard JSON;
time-based probe data is synthetic.

**To reach Exemplary:** optional - deploy kube-prometheus-stack in kind (heavier) or show the Compose Prometheus
UI with the alert rules on video.

## Category 5 - Production-Grade Design and Technical Documentation (provisional 25/30 now, ~28 after the video)

**Supports:** README a newcomer can follow on Windows/macOS/Linux with three paths and a prerequisite checker;
architecture with diagrams matching the implementation and a "tested vs designed" table; 6 ADRs; runbooks for
incident, OpenTofu, GitOps, local dev, reports; PHI readiness checklist; cost safeguards; cleanup that only touches
project resources; validation report with honest PASSED/SKIPPED/BLOCKED.

**Prevents full marks right now:** the **video is not recorded** and the repository is not pushed.

**To reach Exemplary:** record the 8-10 minute video using the outline (face visible throughout), push the repo.

## Provisional total

| Category | Score now | Likely after push + release run + video |
|---|---|---|
| 1 CI/CD + supply chain | 26 | 28-29 |
| 2 IaC + GitOps | 27 | 28 |
| 3 DORA + toil | 28 | 28-29 |
| 4 Observability + SRE | 28 | 28-29 |
| 5 Design + documentation | 25 | 28 |
| **Total** | **134 / 150** | **~140-143 / 150** |

## Second, independent audit (re-inspected files, not earlier claims)

Performed after the build by re-reading files and re-running checks:

| Check | Result |
|---|---|
| Every required file exists (README, 9 docs, 2 workbooks, validation report, BUILD_STATUS) | ✅ verified with `ls` |
| `validate_all.sh` re-run from scratch | ✅ 18/18 PASS |
| Pods run the digest recorded in `reports/supply-chain/image-ref.txt` | ✅ re-verified after the final rebuild |
| Numbers in docs match workbook values (43.2 min; 91.9%/71.8%/49.0%/60.8%; DORA 2.03/7.5/8.2%/36) | ✅ cross-checked |
| Claims that overstated evidence | fixed: tied failure categories; "7x" recovery ratio corrected to 6x/7x; unsupported "review wait" claim removed; SLSA level not claimed |
| Secrets/state files in committable set | ✅ none (gitleaks; `.tfstate`, `.env`, `.local`, `.kube` ignored) |
| Unrelated changes | ✅ none - `kind-shipfast` cluster and old `localstack` container untouched; default kube context unchanged |
