from __future__ import annotations

from datetime import UTC, datetime, timedelta

import pytest
from fastapi.testclient import TestClient

from app.config import Settings
from app.main import create_app
from app.storage import SQLiteStore


@pytest.fixture
def settings() -> Settings:
    return Settings(
        service_name="healthqueue-api",
        environment="test",
        version="test",
        log_level="INFO",
        database_url="sqlite:///:memory:",
        max_days_ahead=180,
        otlp_endpoint=None,
        trace_console=False,
    )


@pytest.fixture
def store() -> SQLiteStore:
    s = SQLiteStore(":memory:")
    yield s
    s.close()


@pytest.fixture
def client(settings, store):
    app = create_app(settings=settings, store=store)
    with TestClient(app) as c:
        yield c


def future(days: int = 7, hour: int = 14, minute: int = 0) -> str:
    when = (datetime.now(UTC) + timedelta(days=days)).replace(
        hour=hour, minute=minute, second=0, microsecond=0
    )
    return when.isoformat().replace("+00:00", "Z")


@pytest.fixture
def valid_payload() -> dict:
    return {
        "patient_ref": "PT-000123",
        "clinic_id": "CLN-001",
        "provider_id": "PRV-0042",
        "appointment_type": "checkup",
        "start_time": future(),
        "duration_minutes": 30,
    }
