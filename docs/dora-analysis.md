# DORA metrics analysis and toil reduction (summary)

Full workbook: [`reports/dora-analysis.xlsx`](../reports/dora-analysis.xlsx) · data:
[`data/dora_deployments.csv`](../data/dora_deployments.csv) · generator: `scripts/generate_dora_data.py`
(seed 20261025).

> **SYNTHETIC DATA.** 124 simulated production deployments of `healthqueue-api` between **2026-07-01 and
> 2026-09-28 (90 days)**, in three 30-day phases: *Manual* (hand-run deploy script), *CI* (automated tests and image
> pipeline, manual deploy), *GitOps* (Argo CD, `git revert` rollback). It is not real HealthQueue performance.

## Benchmark source

DORA (Google Cloud), *Accelerate State of DevOps Report* **2024**, software delivery performance clusters
(<https://dora.dev/research/2024/dora-report/>). The **2025** DORA report replaced the four tiers with seven team
archetypes, so 2024 is the latest edition with elite/high/medium/low benchmarks.

| Cluster (2024) | Deployment frequency | Change lead time | Change failure rate | Failed deployment recovery time |
|---|---|---|---|---|
| Elite | On demand (multiple per day) | < 1 day | 5% | < 1 hour |
| High | Daily to weekly | 1 day - 1 week | 20% | < 1 day |
| Medium | Weekly to monthly | 1 week - 1 month | 10% | < 1 day |
| Low | Monthly to every 6 months | 1 - 6 months | 40% | 1 week - 1 month |

Note: the 2024 Medium cluster had a lower change failure rate than High; DORA explained that throughput weighed
more in clustering. We therefore compare CFR value-by-value instead of as a strict ranking.

## Results (all computed by workbook formulas, checked independently)

| Metric | Unit | Overall (90 d) | 1-Manual | 2-CI | 3-GitOps | Cluster (overall -> last 30 d) |
|---|---|---|---|---|---|---|
| Deployment frequency | deploys/day | 1.38 | 0.97 | 1.13 | 2.03 | Elite -> Elite |
| Change lead time (median) | hours | 12.9 | 43.8 | 22.2 | 7.5 | Elite -> Elite |
| Change lead time (p90) | hours | 59.0 | 98.0 | 53.2 | 13.3 | - |
| Change failure rate | % | 11.3% | 24.1% | 5.9% | 8.2% | High value (≤ 20%) -> Medium value (≤ 10%) |
| Recovery time (median) | minutes | 79 | 224 | 56.5 | 36 | High/Medium (< 1 day) -> Elite |
| Manual toil per deployment | minutes | 19.7 | 49.9 | 22.0 | 4.1 | - |

Definitions and units: frequency = deployments ÷ days; lead time = `deployed_at − first_commit_at`; CFR = failed
deployments ÷ deployments; recovery = `restored_at − deployed_at` for failed deployments. Medians are used because
the distributions are skewed; p90/mean show the tails.

## Findings

1. **Throughput doubled while lead time fell ~6x** (0.97 -> 2.03 deploys/day; 43.8 h -> 7.5 h median).
2. **Stability improved with speed** - CFR 24% -> 8%, median recovery 224 -> 36 min. Speed did not cost stability.
3. **Recovery depends on the remediation method:** `git revert` via Argo CD median **31 min** vs. hotfix **181 min** vs.
   manual rollback **224 min** (Failure_Analysis sheet).
4. **Top failure causes are tied:** configuration errors and dependency/migration problems - 5 of 14 failures each.
5. **Caveat:** phase 2's CFR (5.9%) is lower than phase 3's (8.2%) - with 34 and 61 deployments this is within random
   noise. Weekly CFR swings between 0% and 33%. Do not over-read single-phase changes.

## Toil reduction, tied to the results

| Toil (manual, repetitive, automatable) | Automation | DORA metric moved |
|---|---|---|
| Building/pushing images by hand | CI image pipeline | lead time |
| Manual vulnerability checks | Trivy gate + Dependabot | change failure rate |
| Hand-run deploy script | Argo CD sync from Git | deployment frequency |
| Manual rollback | `git revert` -> Argo CD (tested) | recovery time |

Hands-on minutes per deployment fell **92%** (49.9 -> 4.1); at the phase-3 volume this saves about **46 engineer-hours
per month** compared with the manual process.

**Next toil targets (recommendations):**
1. *Frequency/lead time:* auto-merge digest PRs when signature + provenance verify; review SLA for the p90 tail.
2. *Change failure rate:* policy-as-code checks on manifests/config and automated migration tests (the two top failure
   categories); canary releases (Argo Rollouts) gated on the SLO metrics.
3. *Recovery time:* make `git revert` the default remediation and link it from the fast-burn alert runbook.

## Limitations

Synthetic data; DORA benchmarks come from **survey** answers across thousands of organisations, ours from
deployment records of one service - methods differ; ~30-60 deployments per phase is a small sample; teams should
compare mainly against their own trend rather than chase a label.
