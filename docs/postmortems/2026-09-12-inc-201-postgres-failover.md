# Postmortem INC-201: bookings failed during PostgreSQL failover (SYNTHETIC)

> **This incident is synthetic.** It is the injected 12 September event in `data/slo_daily_synthetic.csv`, written up
> as an example of HealthQueue's blameless postmortem format.

* **Date:** 2026-09-12 · **Duration:** 22 minutes of user impact · **Severity:** SEV1
* **Error budget impact:** 450 extra failed requests (~43% of the monthly request budget), 22 of 43.2 allowed bad
  minutes (51% of the time budget), 120 failed valid bookings.
* **Authors:** on-call engineer + platform lead · **Status:** actions in progress

## Summary

A scheduled maintenance on the database triggered a failover. For 22 minutes the API kept trying to use broken
connections; requests failed with 5xx and patients could not book. Service recovered when the pods were restarted.

## Timeline (UTC)

| Time | Event |
|---|---|
| 14:02 | Database failover starts (provider maintenance) |
| 14:03 | 5xx ratio jumps to ~6%; `HealthQueueAvailabilityFastBurn` pending |
| 14:05 | Alert fires and pages on-call (2-minute `for`) |
| 14:09 | On-call sees no recent deploy; readiness still green because `/readyz` only pinged once per new connection |
| 14:18 | Pods restarted manually; errors drop |
| 14:24 | Error ratio back to baseline; incident resolved |

## Contributing factors (no blame - systems, not people)

1. The API opened a new database connection per request and had no retry for a failed first attempt after a failover.
2. Readiness did not reflect the broken state quickly enough, so traffic kept going to pods that were failing.
3. No runbook step for "database failover" existed; the restart was found by trial.

## What went well

* The burn-rate alert paged within 3 minutes of impact - before any clinic called.
* `request_id`/`trace_id` in logs let the team confirm all errors came from the insert path.

## Action items

| Action | Owner | Status |
|---|---|---|
| Use a connection pool that detects and replaces broken connections | Backend | **Done in v0.1.1** (psycopg_pool) |
| Readiness checks borrow a pooled connection (same path as requests) | Backend | Done in v0.1.1 |
| Add "database failover" section to the runbook | On-call | Done (section C) |
| Quarterly failover game-day in staging | Platform | Planned |
| Error budget: request budget now in FREEZE -> only reliability work until it recovers | Eng manager | Applied |
