# Local development: run, test, troubleshoot the API

## Run without Docker (SQLite)

```powershell
# Windows PowerShell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements-dev.txt
uvicorn app.main:app --reload --port 8080
```
```bash
# macOS / Linux
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements-dev.txt
uvicorn app.main:app --reload --port 8080
```

Open http://127.0.0.1:8080/docs for interactive API docs (disabled when `APP_ENV=production`).

## Try it

```bash
curl -s localhost:8080/healthz
curl -s -X POST localhost:8080/v1/appointments -H "Content-Type: application/json" -d '{
  "patient_ref": "PT-000123", "clinic_id": "CLN-001", "provider_id": "PRV-0042",
  "appointment_type": "checkup", "start_time": "2026-12-01T14:30:00Z", "duration_minutes": 30}'
curl -s localhost:8080/v1/appointments/<id-from-above>
curl -s localhost:8080/metrics | grep healthqueue_
```

PowerShell: `Invoke-RestMethod -Method Post -Uri http://127.0.0.1:8080/v1/appointments -ContentType 'application/json' -Body '{...}'`

| Request | Expected |
|---|---|
| valid booking | `201` + `Location` header |
| same provider, overlapping time | `409 slot_unavailable` |
| past time, >180 days ahead, bad IDs, extra fields, no timezone | `422 validation_error` (field names only) |
| unknown id | `404` |
| DB down | `/readyz` -> `503`; `/healthz` stays `200` |

## Configuration (environment variables)

| Variable | Default | Meaning |
|---|---|---|
| `DATABASE_URL` | `sqlite:///./data/healthqueue.db` | or `postgresql://user:pass@host:5432/db` |
| `APP_ENV` | `local` | `production` hides `/docs` |
| `LOG_LEVEL` | `INFO` | |
| `MAX_DAYS_AHEAD` | `180` | booking window |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | unset | send traces to an OTel collector |
| `OTEL_TRACE_CONSOLE` | `false` | print spans to stdout (debugging) |

## Tests and checks

```bash
python -m pytest --cov                      # 53 tests; Postgres test skipped unless TEST_POSTGRES_URL is set
ruff check . && ruff format --check .
bandit -r app -c pyproject.toml
pip-audit -r requirements.txt
yamllint -s .
```

Postgres integration test:

```bash
docker run -d --name hq-test-postgres -e POSTGRES_USER=hq -e POSTGRES_PASSWORD=localtest \
  -e POSTGRES_DB=healthqueue -p 127.0.0.1:55432:5432 postgres:17-alpine
TEST_POSTGRES_URL=postgresql://hq:localtest@127.0.0.1:55432/healthqueue python -m pytest tests/test_storage.py
docker rm -f hq-test-postgres
```

## Docker Compose (API + PostgreSQL, optional Prometheus)

```bash
cp .env.example .env            # set POSTGRES_PASSWORD
docker compose up --build -d
docker compose --profile observability up -d   # Prometheus at http://127.0.0.1:9090 (rules loaded)
docker compose down -v
```

## Troubleshooting

| Problem | Fix |
|---|---|
| `uvicorn: command not found` | activate the venv first |
| `Activate.ps1 cannot be loaded` | `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` (or use `.venv\Scripts\python -m uvicorn ...`) |
| `ModuleNotFoundError: app` | run commands from the repository root |
| Port 8080 in use | `--port 8081` (or `API_PORT=8081` for Compose) |
| `POSTGRES_PASSWORD` error from Compose | create `.env` from `.env.example` |
| Docker "cannot connect to the Docker daemon" | start Docker Desktop |
| Windows: Git Bash rewrites `/paths` in docker commands | `export MSYS_NO_PATHCONV=1` (the scripts already do this) |
