"""Runtime configuration, read once from environment variables.

Every setting has a safe default so the API starts with zero configuration
(SQLite file storage, JSON logs, tracing to nowhere). Secrets such as the
database password are only ever read from the environment - never hard-coded.
"""

from __future__ import annotations

import os
from dataclasses import dataclass


def _bool(name: str, default: bool) -> bool:
    raw = os.getenv(name)
    if raw is None:
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


@dataclass(frozen=True)
class Settings:
    service_name: str
    environment: str
    version: str
    log_level: str
    # "sqlite:///path/to/file.db" or "postgresql://user:pass@host:5432/db"
    database_url: str
    # Booking rules
    max_days_ahead: int
    # Tracing: if an OTLP endpoint is configured spans are exported there,
    # otherwise tracing still runs (so trace IDs appear in logs) but spans are dropped.
    otlp_endpoint: str | None
    trace_console: bool

    @classmethod
    def from_env(cls) -> Settings:
        return cls(
            service_name=os.getenv("SERVICE_NAME", "healthqueue-api"),
            environment=os.getenv("APP_ENV", "local"),
            version=os.getenv("APP_VERSION", "0.1.1"),
            log_level=os.getenv("LOG_LEVEL", "INFO").upper(),
            database_url=os.getenv("DATABASE_URL", "sqlite:///./data/healthqueue.db"),
            max_days_ahead=int(os.getenv("MAX_DAYS_AHEAD", "180")),
            otlp_endpoint=os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT") or None,
            trace_console=_bool("OTEL_TRACE_CONSOLE", False),
        )
