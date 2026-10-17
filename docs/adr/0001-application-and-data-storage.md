# ADR-0001: Python/FastAPI API with pluggable SQLite / PostgreSQL storage

* Status: Accepted (2026-10-17)
* Deciders: HealthQueue platform team

## Context

We need a small, explainable appointment API that a new engineer can run in minutes, that several Kubernetes
replicas can serve at once, and that never stores more patient data than necessary.

## Decision

* **FastAPI + Pydantic v2** - typed request models give input validation, correct 422 responses and OpenAPI docs
  for free; the team already uses Python.
* **Storage behind a 5-method interface** (`create`, `get`, `list`, `ping`, `close`):
  * **SQLite** for the quick start and unit tests (zero setup).
  * **PostgreSQL** whenever more than one replica runs (Compose, Kubernetes), because each pod would otherwise have
    its own private SQLite file and a booking made on pod A would be "missing" on pod B.
* **Double-booking prevention in the database transaction** (SQLite `BEGIN IMMEDIATE`; PostgreSQL
  `pg_advisory_xact_lock` per provider) instead of in application memory, so it holds across replicas.
* **Connection pool** (`psycopg_pool`) - added in v0.1.1 after the local load test showed a new connection per request
  pushed ~15% of requests over the 300 ms latency SLO.
* **Data minimisation:** only opaque references (`PT-######`, `CLN-###`, `PRV-####`), an appointment type enum and a
  time. No names, DOB or free text; unknown fields rejected.

## Alternatives considered

* *In-memory dict* - simplest, but data disappears on restart and cannot be shared by replicas.
* *SQLite on a shared volume* - SQLite file locking over network volumes is unreliable; forces one replica.
* *ORM (SQLAlchemy)* - more abstraction than a 3-table-operation demo needs; plain SQL is easier to explain.
* *DynamoDB* - good fit at scale, but ties local development to AWS/LocalStack and costs money in production tests.

## Consequences

* + Runs anywhere with `pip install` + `uvicorn`; the same code runs on PostgreSQL in Kubernetes.
* + Correctness under concurrency is tested (10 parallel bookings -> exactly 1 succeeds).
* − Two storage implementations to keep in sync (mitigated: shared tests + a Postgres integration test in CI).
* − The in-cluster PostgreSQL StatefulSet is a **demo**: no backups, no HA. Production uses a managed, encrypted,
  backed-up PostgreSQL (see [production-readiness.md](../production-readiness.md)).
