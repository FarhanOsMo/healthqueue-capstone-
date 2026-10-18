# Validation report

* Run on: 2026-10-17 (UTC), Windows 11 + Git Bash, Docker Desktop 29.8.0, kind v0.33.0, OpenTofu 1.12.6, Python 3.13.1.
* Status meanings: **PASSED** = executed here and succeeded; **FAILED** = executed and failed; **SKIPPED** = not
  executed; **BLOCKED** = cannot run without approval, credentials or paid resources.
* Every PASSED row links to the raw output saved by the run. Re-run the static set with
  `bash scripts/validate_all.sh` (writes `reports/validation/`).

## 1. Application

| Test | Status | Evidence |
|---|---|---|
| Unit + API + validation + observability + storage + report tests | **PASSED** - 53 passed, coverage 95.73% (gate 85%) | `validation/pytest.txt` |
| PostgreSQL integration test (real postgres:17 container) | **PASSED** (part of the 53, `TEST_POSTGRES_URL` set) | `validation/pytest.txt` |
| Concurrency: 10 parallel bookings, same slot -> exactly 1 succeeds | **PASSED** | `tests/test_storage.py` |
| Flaky-test check: PostgreSQL test run 40x against a reused database | **PASSED** 40/40 after fix (before: **FAILED 2/40** - test reused leftover rows and a 3-digit pseudo-unique provider ID, causing false 409s; now each run uses its own throwaway schema) | `tests/test_storage.py::pg_store` |
| Input validation (10 invalid-field cases, extra field, past/far time, non-JSON, timezone) | **PASSED** | `tests/test_validation.py` |
| Failure handling: 500 hides internals; 503 readiness; 404/409/422 | **PASSED** | `tests/test_api.py` |
| Lint / format (ruff) | **PASSED** | `validation/ruff-*.txt` |
| SAST (bandit) | **PASSED** - 0 issues (5 SQL-string warnings fixed by using literal SQL, not suppressed) | `validation/bandit.txt` |
| Dependency audit (pip-audit) | **PASSED** - no known vulnerabilities | `validation/pip-audit.txt` |
| Container smoke test (healthz, readyz, POST 201, non-root uid 10001, HEALTHCHECK healthy) | **PASSED** | build log (BUILD_STATUS) |
| Docker Compose: API + Postgres + Prometheus; read-only FS, cap_drop ALL | **PASSED** | `observability/compose-prometheus-check.txt` |

Warnings seen (not failures): Starlette deprecation notice inside FastAPI's TestClient; openpyxl note that it cannot
read an Excel-only conditional-formatting extension.

## 2. CI/CD and supply chain

| Test | Status | Evidence |
|---|---|---|
| Workflow syntax + expressions (actionlint) | **PASSED** | `validation/actionlint.txt` |
| YAML lint (all YAML) | **PASSED** | `validation/yamllint.txt` |
| Dockerfile lint (hadolint) | **PASSED** | `validation/hadolint.txt` |
| Shell scripts (shellcheck, warning level) | **PASSED** | `validation/shellcheck.txt` |
| Image build (v0.1.1, 249 MB) | **PASSED** | `supply-chain/run-log.txt` |
| Trivy vulnerability gate (fixable HIGH/CRITICAL = 0) | **PASSED** (initial run **FAILED** on pip-vendored urllib3/msgpack -> fixed in Dockerfile) | `supply-chain/trivy-image-report.txt` |
| Trivy totals (informational): 166 OS findings, HIGH 44 / CRITICAL 0, **all HIGH unfixed upstream (Debian)** | reported | same |
| Syft SBOM, SPDX JSON (2,969 elements) + CycloneDX JSON | **PASSED** | `supply-chain/sbom.*.json` |
| Cosign sign by digest (local test key, tlog off) | **PASSED** - *not a trusted release signature* | `supply-chain/cosign-verify.json` |
| Cosign SBOM attestation + verify | **PASSED** | `supply-chain/cosign-verify-sbom-attestation.json` |
| Local provenance attestation + verify (builder marked UNTRUSTED) | **PASSED** - demo of the mechanism only | `supply-chain/cosign-verify-provenance-attestation.json` |
| Negative test: tampered image (new digest) fails verification | **PASSED** ("no signatures found") | `supply-chain/cosign-verify-tampered.txt` |
| Secret scan of all committable files (gitleaks 8.30.1) | **PASSED** - no leaks (1 public GPG fingerprint allow-listed with reason) | `validation/secret-scan.txt` |
| GitHub Actions `ci.yml` run on GitHub (4 jobs: tests + Postgres + coverage gate, config validation, OpenTofu + LocalStack plan, image + Trivy gate + SBOM) | **PASSED** on commit 33e4a39 (first run on 7334333 **FAILED**: one ruff E501 in a late-added script - fixed) | [https://github.com/FarhanOsMo/healthqueue-capstone-/actions/runs/39079615363](https://github.com/FarhanOsMo/healthqueue-capstone-/actions/runs/39079615363) |
| `release.yml`: GHCR push, keyless signing, GitHub SLSA provenance, `gh attestation verify`, GitOps PR | **BLOCKED** - needs push + tag | - |

## 3. Infrastructure as Code

| Test | Status | Evidence |
|---|---|---|
| `tofu fmt -check` (recursive) | **PASSED** | `validation/tofu-fmt.txt` |
| `tofu validate` - module, aws-production, localstack, bootstrap | **PASSED** (4/4) | `validation/tofu-validate.txt` |
| Trivy IaC + Dockerfile + K8s misconfiguration scan (HIGH/CRITICAL) | **PASSED** (2 HIGH found during build -> fixed: CMK for state bucket, read-only FS for Gitea) | `validation/trivy-config.txt` |
| LocalStack 3.8 community started, S3/STS/IAM/KMS/Logs healthy | **PASSED** | `opentofu/localstack-health.json` |
| S3 remote backend init (LocalStack) | **PASSED** | `opentofu/init.txt` |
| Lock enforcement: plan blocked while another lock exists (HTTP 412) | **PASSED** | `opentofu/plan-while-locked.txt` |
| Lock recovery: `tofu force-unlock` | **PASSED** | `opentofu/force-unlock.txt` |
| `tofu plan` (LocalStack): 13 to add, 0 change, 0 destroy; no lock left | **PASSED** | `opentofu/plan.txt`, `opentofu/run-log.txt` |
| `tofu apply` (LocalStack or AWS) | **SKIPPED** by rule - never run | - |
| `tofu plan` against real AWS | **BLOCKED** - needs AWS credentials | - |

## 4. Kubernetes and GitOps

| Test | Status | Evidence |
|---|---|---|
| Kustomize render (local 12 objects, production 11) | **PASSED** | `validation/kustomize-build.txt`, `k8s/rendered-*.yaml` |
| kubeconform strict (K8s 1.33 schemas) | **PASSED** - 23/23 valid | `validation/kubeconform.txt` |
| Dedicated kind cluster + local registry + Argo CD v3.5.5 + Gitea | **PASSED** | `k8s/kind-up-log.txt` |
| Argo CD reconciliation from Git -> Synced / Healthy | **PASSED** | `k8s/gitops-image-update.txt` |
| API via NodePort: healthz, readyz, 201, 200 x4 across replicas, 409, 422 | **PASSED** | `k8s/gitops-verification.txt` |
| Running pods use the exact signed digest | **PASSED** | same |
| Self-heal reverts manual `kubectl scale` | **PASSED** | same |
| Commit-driven change (2 -> 3 replicas) synced | **PASSED** | same |
| Rollback by `git revert` synced | **PASSED** | same |
| Image update via Git (v0.1.0 -> v0.1.1 -> final rebuild) | **PASSED** | `k8s/gitops-image-update.txt` |
| NetworkPolicy: API->DB allowed; other namespace->DB blocked (with positive control) | **PASSED** | `k8s/gitops-verification.txt` |
| Pod Security Admission `restricted` rejects a privileged pod | **PASSED** | same |
| Argo CD reconciling from **GitHub** | **BLOCKED** - repo not pushed (`application-github.yaml` ready) | - |
| Production overlay deployed | **SKIPPED** - no paid cluster; render + schema validation only | - |

## 5. Observability and SRE

| Test | Status | Evidence |
|---|---|---|
| `promtool check rules` (18 rules) | **PASSED** | `observability/promtool-check.txt` |
| `promtool test rules` - 5 scenarios (healthy, 5% errors, blip, target down, booking failures) | **PASSED** | `observability/promtool-test.txt`, `validation/promtool.txt` |
| Prometheus scrapes API, rules loaded (Compose) | **PASSED** | `observability/compose-prometheus-check.txt` |
| JSON logs carry request_id + trace_id; IDs not in metrics; bodies not logged | **PASSED** (tests) | `tests/test_observability.py` |
| Local load test v0.1.0: latency SLI 85.4% (SLO breach found) | **PASSED as a measurement** | `slo/local-load-test-v0.1.0-no-pool.json` |
| Local load test v0.1.1 (pool): latency SLI 100%, p99 157 ms | **PASSED** | `slo/local-load-test-v0.1.1-pool.json` |
| Alertmanager/Grafana deployed | **SKIPPED** - documented design only | - |

## 6. Reports and data

| Test | Status | Evidence |
|---|---|---|
| DORA CSV reproducible byte-for-byte from seed | **PASSED** | `validation/dora-data-repro.txt`, `tests/test_reports.py` |
| DORA rows internally consistent (lead time, recovery) | **PASSED** | tests + Checks sheet |
| SLO arithmetic: 43,200 min x 0.001 = 43.2 min; request budget separate | **PASSED** | tests + Checks sheet |
| `slo-error-budget.xlsx` recalculated in **Excel 16**: 330 formulas, 0 errors, 14/14 checks PASS | **PASSED** | `scripts/verify_workbooks.ps1` output below |
| `dora-analysis.xlsx` recalculated in **Excel 16**: 384 formulas, 0 errors, 41/41 checks PASS | **PASSED** | same |
| Cross-platform workbook verifier | **PASSED** | `validation/workbooks.txt` |
| Charts render (exported and inspected) | **PASSED** (axis/label issues found and fixed) | - |
| LibreOffice Calc compatibility | **SKIPPED** - LibreOffice not installed; only Excel-2010-era functions used | - |

```
PASS  reports/slo-error-budget.xlsx  formulas=330  formula_errors=0  checks='ALL CHECKS PASS'  excel=16.0
PASS  reports/dora-analysis.xlsx  formulas=384  formula_errors=0  checks='ALL CHECKS PASS'  excel=16.0
```

## 7. Documentation

| Test | Status | Evidence |
|---|---|---|
| Relative links in all 25 Markdown files resolve | **PASSED** | `python scripts/check_links.py` |
| Mermaid diagrams render (README 1 + architecture 4) | **PASSED** - all 5 rendered to SVG by `minlag/mermaid-cli` | final audit |
| Setup instructions match scripts (fresh-clone order fixed: `kind_up.sh` before `local_supply_chain.sh`) | **PASSED** (reviewed) | README |

## Summary

| Category | Passed | Failed | Skipped | Blocked |
|---|---|---|---|---|
| Static checks (`validate_all.sh`) | 18 | 0 | 0 | 0 |
| Dynamic local checks (supply chain, OpenTofu, GitOps, load test, Compose) | all listed | 0 | 2 (apply - by rule; Alertmanager) | 0 |
| GitHub CI | 4 jobs | 0 (after fix) | 0 | 0 |
| Needs tag / AWS | - | - | - | 3 (release run, Argo from GitHub, AWS plan) |
