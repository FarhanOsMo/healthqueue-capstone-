"""Generate a reproducible SYNTHETIC 90-day DORA deployment dataset for HealthQueue.

Nothing in this file is real production data. The numbers are simulated to
tell a plausible improvement story so the analysis workbook has something
meaningful to analyse:

  Phase 1 (days 1-30)   "Manual"     - deploys by hand-run script, manual smoke tests
  Phase 2 (days 31-60)  "CI"         - automated tests + image pipeline, manual deploy step
  Phase 3 (days 61-90)  "GitOps"     - Argo CD sync, automated rollback by git revert

Reproducible: a fixed random seed means every run produces byte-identical CSV.

Usage:
  python scripts/generate_dora_data.py                # writes data/dora_deployments.csv
  python scripts/generate_dora_data.py --out other.csv --seed 7
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import random
from dataclasses import dataclass
from datetime import UTC, date, datetime, time, timedelta
from pathlib import Path

SEED = 20261025
PERIOD_START = date(2026, 7, 1)  # inclusive
PERIOD_DAYS = 90  # 2026-07-01 .. 2026-09-28 inclusive
SERVICE = "healthqueue-api"

FIELDS = [
    "deployment_id",
    "deployed_at_utc",
    "deploy_date",
    "phase",
    "deploy_method",
    "service",
    "environment",
    "commit_sha",
    "pr_number",
    "first_commit_at_utc",
    "lead_time_hours",
    "change_failed",
    "failure_category",
    "incident_id",
    "restored_at_utc",
    "recovery_minutes",
    "remediation",
    "manual_toil_minutes",
]


@dataclass(frozen=True)
class Phase:
    name: str
    method: str
    weekday_rate: float  # mean deployments per weekday (Poisson)
    weekend_rate: float
    lead_time_median_h: float  # log-normal median
    lead_time_sigma: float
    failure_prob: float
    recovery_median_min: float
    recovery_sigma: float
    toil_min: tuple[int, int]  # manual minutes per deployment (uniform range)
    remediations: tuple[tuple[str, float], ...]


PHASES = (
    Phase(
        "1-Manual",
        "manual_script",
        1.2,
        0.1,
        52.0,
        0.75,
        0.20,
        190.0,
        0.8,
        (35, 60),
        (("manual rollback", 0.6), ("hotfix", 0.4)),
    ),
    Phase(
        "2-CI",
        "ci_pipeline_manual_deploy",
        1.6,
        0.2,
        26.0,
        0.65,
        0.13,
        95.0,
        0.7,
        (15, 30),
        (("manual rollback", 0.5), ("hotfix", 0.3), ("roll forward", 0.2)),
    ),
    Phase(
        "3-GitOps",
        "gitops_argocd",
        2.6,
        0.3,
        9.0,
        0.6,
        0.07,
        32.0,
        0.6,
        (2, 6),
        (("git revert (Argo CD sync)", 0.75), ("roll forward", 0.25)),
    ),
)

FAILURE_CATEGORIES = (
    ("configuration error", 0.35),
    ("dependency / migration", 0.20),
    ("latency regression", 0.20),
    ("application bug (5xx)", 0.25),
)


def _poisson(rng: random.Random, lam: float) -> int:
    # Knuth's algorithm - fine for the small rates used here.
    limit, k, p = pow(2.718281828459045, -lam), 0, 1.0
    while True:
        p *= rng.random()
        if p <= limit:
            return k
        k += 1


def _weighted(rng: random.Random, options: tuple[tuple[str, float], ...]) -> str:
    r, acc = rng.random(), 0.0
    for value, weight in options:
        acc += weight
        if r <= acc:
            return value
    return options[-1][0]


def _iso(ts: datetime) -> str:
    return ts.strftime("%Y-%m-%dT%H:%M:%SZ")


def generate(seed: int = SEED) -> list[dict[str, object]]:
    rng = random.Random(seed)
    rows: list[dict[str, object]] = []
    pr_number = 412
    incident_number = 1
    for day_index in range(PERIOD_DAYS):
        day = PERIOD_START + timedelta(days=day_index)
        phase = PHASES[min(day_index // 30, 2)]
        weekend = day.weekday() >= 5
        count = _poisson(rng, phase.weekend_rate if weekend else phase.weekday_rate)
        # Deploy times during working hours (13:00-23:00 UTC ~ 9am-7pm US Eastern), sorted.
        minutes = sorted(rng.randint(13 * 60, 23 * 60 - 1) for _ in range(count))
        for m in minutes:
            deployed = datetime.combine(day, time(m // 60, m % 60), tzinfo=UTC)
            lead_h = round(
                min(
                    rng.lognormvariate(0, phase.lead_time_sigma) * phase.lead_time_median_h, 24 * 21
                ),
                2,
            )
            first_commit = deployed - timedelta(hours=lead_h)
            failed = rng.random() < phase.failure_prob
            pr_number += rng.randint(1, 3)
            row: dict[str, object] = {
                "deployment_id": f"DEP-{len(rows) + 1:04d}",
                "deployed_at_utc": _iso(deployed),
                "deploy_date": day.isoformat(),
                "phase": phase.name,
                "deploy_method": phase.method,
                "service": SERVICE,
                "environment": "production (synthetic)",
                "commit_sha": hashlib.sha1(
                    f"{seed}-{len(rows)}".encode(), usedforsecurity=False
                ).hexdigest()[:12],
                "pr_number": pr_number,
                "first_commit_at_utc": _iso(first_commit),
                "lead_time_hours": lead_h,
                "change_failed": "TRUE" if failed else "FALSE",
                "failure_category": "",
                "incident_id": "",
                "restored_at_utc": "",
                "recovery_minutes": "",
                "remediation": "",
                "manual_toil_minutes": rng.randint(*phase.toil_min),
            }
            if failed:
                rec = max(
                    5,
                    round(rng.lognormvariate(0, phase.recovery_sigma) * phase.recovery_median_min),
                )
                row.update(
                    failure_category=_weighted(rng, FAILURE_CATEGORIES),
                    incident_id=f"INC-{incident_number:03d}",
                    restored_at_utc=_iso(deployed + timedelta(minutes=rec)),
                    recovery_minutes=rec,
                    remediation=_weighted(rng, phase.remediations),
                )
                incident_number += 1
            rows.append(row)
    return rows


def write_csv(rows: list[dict[str, object]], out: Path) -> None:
    out.parent.mkdir(parents=True, exist_ok=True)
    with out.open("w", newline="", encoding="utf-8") as fh:
        writer = csv.DictWriter(fh, fieldnames=FIELDS, lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)


def main() -> None:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--out", type=Path, default=Path("data/dora_deployments.csv"))
    parser.add_argument("--seed", type=int, default=SEED)
    args = parser.parse_args()
    rows = generate(args.seed)
    write_csv(rows, args.out)
    failed = sum(r["change_failed"] == "TRUE" for r in rows)
    print(
        f"Wrote {len(rows)} synthetic deployments ({failed} failed) to {args.out} "
        f"covering {PERIOD_START} .. {PERIOD_START + timedelta(days=PERIOD_DAYS - 1)} "
        f"(seed {args.seed})."
    )


if __name__ == "__main__":
    main()
