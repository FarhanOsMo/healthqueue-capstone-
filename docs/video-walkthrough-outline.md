# Video walkthrough outline (8-10 minutes, camera on the whole time)

Audience: **Maya Chen, CTO**. Tone: a lead engineer briefing their CTO - decisions, evidence, trade-offs.
These are talking points, not a script; say them in your own words.

**Recording setup:** webcam overlay in a corner of a screen recording (OBS Studio is free: add a *Video Capture
Device* source on top of *Display Capture*). Keep your face visible for the entire video - do not hide the overlay
when you switch windows. Rehearse once; aim for 9 minutes.

## Before you hit record (prepare these windows/tabs)

1. VS Code (or Explorer) with the repo open, `README.md` preview.
2. A terminal in the repo (Git Bash on Windows) - run `bash scripts/kind_up.sh` beforehand if the cluster is down.
3. GitHub repo page -> *Actions* tab (only if you pushed and the workflows ran).
4. Argo CD UI: `kubectl -n argocd port-forward svc/argocd-server 8443:443` -> https://localhost:8443.
5. Both workbooks open in Excel: `reports/slo-error-budget.xlsx` (Dashboard) and `reports/dora-analysis.xlsx` (Summary).
6. `docs/architecture.md` rendered (GitHub or VS Code Markdown preview shows the Mermaid diagram).

## Timeline

| Time | Section | Say (key points) | Show on screen |
|---|---|---|---|
| 0:00-0:40 | **Problem + overview** | "Maya, we're launching a patient-facing booking API. Before launch we need to ship fast *and* prove what we run. I built a reference pipeline: code to production with security gates, GitOps deploys, and SLOs - all for $0 on a laptop." | README top table |
| 0:40-1:40 | **Architecture** | Walk the diagram left to right: PR -> CI (read-only) -> tag -> release (scan, SBOM, sign, provenance, verify) -> GitOps PR -> Argo CD -> Kubernetes -> Prometheus. "Untrusted code can never publish." | `docs/architecture.md` diagram + "tested vs designed" table |
| 1:40-2:50 | **CI/CD pipeline** | Two workflows, two trust levels. Least-privilege permissions; actions pinned to commit SHAs (mention the March 2026 Trivy-action compromise as *why*). Tests: 53 incl. Postgres integration, 94% coverage. | `.github/workflows/ci.yml` (permissions block), terminal: `python -m pytest --cov` (or the saved output), GitHub Actions run if available |
| 2:50-4:00 | **Scanning, SBOM, signing, SLSA** | Trivy gate fails on fixable HIGH/CRITICAL - "it caught pip's vendored urllib3; I removed pip from the image instead of ignoring it." Syft SBOM. Cosign keyless in CI; locally a test key. Tampered image rejected. "We're *designed* for SLSA Build L2; I don't claim it until the first tagged release verifies. L3 needs a reusable workflow." | `reports/supply-chain/run-log.txt` (Trivy gate passed, verified, tampered rejected), `docs/supply-chain-security.md` SLSA table |
| 4:00-4:50 | **OpenTofu + state** | KMS, encrypted versioned S3 evidence bucket, CloudWatch logs, GitHub OIDC role (no AWS keys). S3 remote state with native locking. "I never ran apply - $0 rule. I proved validate, a plan, and that locking really blocks a second writer." | `infra/modules/.../main.tf` briefly; `reports/opentofu/plan-while-locked.txt` (Error acquiring the state lock) |
| 4:50-6:10 | **Kubernetes + GitOps (live)** | Argo CD Synced/Healthy. Show self-heal: scale by hand, Argo puts it back. Rollback = `git revert`. Security: non-root, read-only FS, NetworkPolicy, Pod Security restricted - all verified. | Argo CD UI app tree; terminal: `kubectl -n healthqueue scale deploy healthqueue-api --replicas=5` then watch it return to 2; `reports/k8s/gitops-verification.txt` PASS list |
| 6:10-7:30 | **Observability + SLO/error budget** | Three SLIs; 99.9% is a design choice = **43.2 min per 30 days**. Requests vs minutes are different budgets. Synthetic month: availability budget 92% used -> policy says FREEZE risky releases. Burn-rate alerts are unit-tested. **Story:** the load test showed latency SLI 85% -> found connection-per-request -> pooled -> shipped via GitOps -> 100%. | Excel SLO Dashboard (colours + charts), Observed_Local sheet, `observability/prometheus/slo-rules.yaml` |
| 7:30-8:40 | **DORA + toil** | 90 days synthetic, compared to DORA **2024** clusters (2025 dropped tiers). GitOps phase: 2 deploys/day, 7.5 h lead time, 8% CFR, 36 min recovery. `git revert` recovered ~6x faster than hotfixes and ~7x faster than manual rollbacks (31 vs 181 vs 224 min median). Toil per deploy -92% (~46 h/month). Next: auto-merge verified digest PRs, policy-as-code for config errors, canaries. | Excel DORA Summary + Weekly_Trend charts + Failure_Analysis |
| 8:40-9:30 | **Trade-offs + limitations** | No real cloud ($0). Synthetic data clearly labelled. Local signing ≠ keyless. Gitea stands in for GitHub locally. Demo Postgres has no backups. Before real PHI: auth, BAAs, managed encrypted DB, audit logs. | `docs/production-readiness.md`, `docs/rubric-mapping.md` gaps |
| 9:30-10:00 | **Summary + ask** | "Fast and safe: signed, verifiable images; Git is the only way to change production; SLOs tell us when to slow down. Ask: approve pushing the repo and cutting v0.1.1 so the keyless signature and provenance become real." | README "Results at a glance" |

## On-screen checklist (tick while recording)

- [ ] Face visible the whole time (webcam overlay never covered)
- [ ] README + architecture diagram
- [ ] Workflow permissions block (`ci.yml` read-only vs `release.yml` job permissions)
- [ ] Passing tests output (53 passed, coverage ≥ 85%)
- [ ] GitHub Actions run (only if pushed - otherwise say it has not run yet)
- [ ] Trivy gate passed + SBOM file + Cosign verified + tampered image rejected
- [ ] OpenTofu plan + lock-blocked output
- [ ] Argo CD Synced/Healthy + self-heal demo
- [ ] `kubectl get pods` showing the digest-pinned image
- [ ] SLO workbook Dashboard and Observed_Local sheet (43.2 min visible)
- [ ] DORA workbook Summary + benchmark sheet with the 2024 source
- [ ] One limitation said out loud (synthetic data / no real cloud)

## Questions Maya might ask (be ready)

* *"Why 99.9 and not 99.99?"* - 4.3 min/month is not credible for one region and one on-call person; revisit with data.
* *"Is this SLSA compliant?"* - Designed for Build L2; verified after the first GitHub release. Not L3 yet.
* *"What stops someone deploying an unsigned image?"* - Today: only CI can publish and Git pins verified digests.
  Next: an admission controller that rejects unsigned images.
* *"What would it cost in AWS?"* - Not measured; the module itself is cheap (KMS key ~ $1/month + usage), the cluster
  and database are the real costs and are not in this phase.
