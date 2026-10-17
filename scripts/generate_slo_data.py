"""Generate a reproducible SYNTHETIC 30-day SLI dataset for the SLO workbook.

Not real production data. One row per day for September 2026 with:
  eligible /v1 requests, 5xx errors, slow (>= 300 ms) requests,
  valid booking submissions, failed submissions,
  synthetic-probe minutes and "bad" (down) minutes, and an incident note.

Three injected incidents give the error budgets something to consume:
  Day 12  PostgreSQL failover          -> 5xx burst, failed bookings, 22 bad minutes
  Day 19  Slow query after deployment  -> latency regression (6% slow requests)
  Day 25  Bad config pushed            -> 9 bad minutes, rolled back by git revert

Usage: python scripts/generate_slo_data.py   # writes data/slo_daily_synthetic.csv
"""

from __future__ import annotations

import argparse
import csv
import random
from datetime import date, timedelta
from pathlib import Path

SEED = 20260901
START = date(2026, 9, 1)
DAYS = 30

FIELDS = [
    "date",
    "eligible_requests",
    "errors_5xx",
    "slow_requests_ge_300ms",
    "valid_submissions",
    "failed_submissions",
    "probe_minutes",
    "bad_minutes",
    "incident_note",
]

INCIDENTS = {
    12: {
        "errors": 450,
        "failed_sub": 120,
        "bad_min": 22,
        "slow_extra": 0.0,
        "note": "INC-201 PostgreSQL failover: 5xx burst for ~22 min",
    },
    19: {
        "errors": 0,
        "failed_sub": 0,
        "bad_min": 0,
        "slow_extra": 0.06,
        "note": "INC-202 slow query after deploy: 6% of requests >= 300 ms",
    },
    25: {
        "errors": 200,
        "failed_sub": 40,
        "bad_min": 9,
        "slow_extra": 0.0,
        "note": "INC-203 bad config; rolled back via git revert in 9 min",
    },
}


def generate(seed: int = SEED) -> list[dict[str, object]]:
    rng = random.Random(seed)
    rows = []
    for i in range(DAYS):
        day = START + timedelta(days=i)
        weekend = day.weekday() >= 5
        requests = int(rng.gauss(15_000 if weekend else 42_000, 1_500))
        inc = INCIDENTS.get(i + 1, {})
        errors = round(requests * rng.uniform(0.0002, 0.0004)) + inc.get("errors", 0)
        slow_rate = rng.uniform(0.003, 0.005) + inc.get("slow_extra", 0.0)
        submissions = round(requests * rng.uniform(0.055, 0.065))
        failed_sub = round(submissions * rng.uniform(0.0003, 0.0007)) + inc.get("failed_sub", 0)
        rows.append(
            {
                "date": day.isoformat(),
                "eligible_requests": requests,
                "errors_5xx": errors,
                "slow_requests_ge_300ms": round(requests * slow_rate),
                "valid_submissions": submissions,
                "failed_submissions": failed_sub,
                "probe_minutes": 1440,
                "bad_minutes": inc.get("bad_min", 0),
                "incident_note": inc.get("note", ""),
            }
        )
    return rows


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", type=Path, default=Path("data/slo_daily_synthetic.csv"))
    ap.add_argument("--seed", type=int, default=SEED)
    args = ap.parse_args()
    rows = generate(args.seed)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    with args.out.open("w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=FIELDS, lineterminator="\n")
        w.writeheader()
        w.writerows(rows)
    print(f"Wrote {len(rows)} synthetic days to {args.out} (seed {args.seed}).")


if __name__ == "__main__":
    main()
