"""Storage-layer unit tests (no HTTP)."""

from __future__ import annotations

import os
import threading
import uuid
from datetime import UTC, datetime, timedelta

import pytest

from app.models import AppointmentCreate
from app.storage import SlotConflictError, SQLiteStore, build_store


def _req(provider="PRV-0001", start_offset_min=0, duration=30) -> AppointmentCreate:
    start = (datetime.now(UTC) + timedelta(days=2)).replace(
        hour=9, minute=0, second=0, microsecond=0
    ) + timedelta(minutes=start_offset_min)
    return AppointmentCreate(
        patient_ref="PT-000001",
        clinic_id="CLN-001",
        provider_id=provider,
        appointment_type="consultation",
        start_time=start,
        duration_minutes=duration,
    )


def test_roundtrip(store):
    created = store.create(_req())
    assert store.get(created.id) == created


def test_overlap_detection(store):
    store.create(_req(duration=60))
    with pytest.raises(SlotConflictError):
        store.create(_req(start_offset_min=45))


def test_persists_to_file(tmp_path):
    path = str(tmp_path / "db" / "hq.db")
    first = SQLiteStore(path)
    created = first.create(_req())
    first.close()
    second = SQLiteStore(path)
    assert second.get(created.id) is not None
    second.close()


def test_concurrent_bookings_only_one_wins(store):
    results: list[str] = []

    def book():
        try:
            store.create(_req(provider="PRV-0777"))
            results.append("ok")
        except SlotConflictError:
            results.append("conflict")

    threads = [threading.Thread(target=book) for _ in range(10)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert results.count("ok") == 1
    assert results.count("conflict") == 9


def test_build_store_rejects_unknown_scheme():
    with pytest.raises(ValueError):
        build_store("mysql://nope")


@pytest.fixture
def pg_store():
    """A PostgresStore in its own throwaway schema, dropped afterwards.

    Isolation matters: the test database may be reused between runs, and rows
    left by an earlier run must never be able to cause a false 409 conflict.
    """
    url = os.getenv("TEST_POSTGRES_URL")
    if not url:
        pytest.skip("TEST_POSTGRES_URL not set")
    import psycopg
    from psycopg import sql

    schema = f"test_{uuid.uuid4().hex[:12]}"
    with psycopg.connect(url, autocommit=True) as conn:
        conn.execute(sql.SQL("CREATE SCHEMA {}").format(sql.Identifier(schema)))
    sep = "&" if "?" in url else "?"
    store = build_store(f"{url}{sep}options=-c%20search_path%3D{schema}")
    try:
        yield store
    finally:
        store.close()
        with psycopg.connect(url, autocommit=True) as conn:
            conn.execute(sql.SQL("DROP SCHEMA {} CASCADE").format(sql.Identifier(schema)))


def test_postgres_backend_roundtrip_and_conflict(pg_store):
    assert pg_store.ping()
    created = pg_store.create(_req(provider="PRV-9001"))
    assert pg_store.get(created.id) == created
    with pytest.raises(SlotConflictError):
        pg_store.create(_req(provider="PRV-9001", start_offset_min=15))
    # back-to-back slot for the same provider is fine; listing filters by clinic
    pg_store.create(_req(provider="PRV-9001", start_offset_min=30))
    assert len(pg_store.list("CLN-001", 10)) == 2
    assert pg_store.list("CLN-999", 10) == []
