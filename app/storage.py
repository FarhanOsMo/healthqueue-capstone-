"""Appointment storage.

Two interchangeable backends behind one small interface:

* SQLiteStore   - zero-setup file database for the quick start and the tests.
* PostgresStore - used in Docker Compose and Kubernetes so several API replicas
                  share one database (SQLite cannot be shared between pods).

Double-booking protection: a provider cannot have two overlapping
appointments. The overlap check and the insert run inside one transaction that
holds a lock, so two simultaneous requests cannot both win.
"""

from __future__ import annotations

import contextlib
import sqlite3
import threading
import uuid
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Protocol

from app.models import Appointment, AppointmentCreate, AppointmentStatus

_TS_FORMAT = "%Y-%m-%dT%H:%M:%S.%fZ"  # fixed width so text comparison == time comparison


class SlotConflictError(Exception):
    """The provider already has an overlapping appointment."""


class AppointmentStore(Protocol):
    def create(self, data: AppointmentCreate) -> Appointment: ...
    def get(self, appointment_id: uuid.UUID) -> Appointment | None: ...
    def list(self, clinic_id: str | None, limit: int) -> list[Appointment]: ...
    def ping(self) -> bool: ...
    def close(self) -> None: ...


def _to_text(ts: datetime) -> str:
    return ts.astimezone(UTC).strftime(_TS_FORMAT)


def _from_text(raw: str) -> datetime:
    return datetime.strptime(raw, _TS_FORMAT).replace(tzinfo=UTC)


class SQLiteStore:
    # Literal SQL only (no string building) - every value is a bound parameter.
    _INSERT = (
        "INSERT INTO appointments (id, patient_ref, clinic_id, provider_id, appointment_type, "
        "start_time, end_time, duration_minutes, status, created_at) "
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
    )
    _SELECT_ONE = (
        "SELECT id, patient_ref, clinic_id, provider_id, appointment_type, start_time, "
        "end_time, duration_minutes, status, created_at FROM appointments WHERE id = ?"
    )
    _SELECT_ALL = (
        "SELECT id, patient_ref, clinic_id, provider_id, appointment_type, start_time, "
        "end_time, duration_minutes, status, created_at FROM appointments "
        "ORDER BY start_time LIMIT ?"
    )
    _SELECT_BY_CLINIC = (
        "SELECT id, patient_ref, clinic_id, provider_id, appointment_type, start_time, "
        "end_time, duration_minutes, status, created_at FROM appointments "
        "WHERE clinic_id = ? ORDER BY start_time LIMIT ?"
    )

    def __init__(self, path: str) -> None:
        if path != ":memory:":
            Path(path).parent.mkdir(parents=True, exist_ok=True)
        # One shared connection guarded by a lock keeps this simple and safe for
        # the demo's concurrency level. check_same_thread=False because FastAPI
        # runs sync endpoints in a thread pool.
        self._conn = sqlite3.connect(path, check_same_thread=False, isolation_level=None)
        self._lock = threading.Lock()
        with self._lock:
            self._conn.execute("PRAGMA journal_mode=WAL")
            self._conn.execute(
                """
                CREATE TABLE IF NOT EXISTS appointments (
                    id TEXT PRIMARY KEY,
                    patient_ref TEXT NOT NULL,
                    clinic_id TEXT NOT NULL,
                    provider_id TEXT NOT NULL,
                    appointment_type TEXT NOT NULL,
                    start_time TEXT NOT NULL,
                    end_time TEXT NOT NULL,
                    duration_minutes INTEGER NOT NULL,
                    status TEXT NOT NULL,
                    created_at TEXT NOT NULL
                )
                """
            )
            self._conn.execute(
                "CREATE INDEX IF NOT EXISTS ix_provider_time "
                "ON appointments (provider_id, start_time)"
            )

    def _row_to_model(self, row: tuple) -> Appointment:
        return Appointment(
            id=uuid.UUID(row[0]),
            patient_ref=row[1],
            clinic_id=row[2],
            provider_id=row[3],
            appointment_type=row[4],
            start_time=_from_text(row[5]),
            duration_minutes=row[7],
            status=row[8],
            created_at=_from_text(row[9]),
        )

    def create(self, data: AppointmentCreate) -> Appointment:
        start = data.start_time
        end = start + timedelta(minutes=data.duration_minutes)
        appt = Appointment(
            id=uuid.uuid4(),
            status=AppointmentStatus.booked,
            created_at=datetime.now(UTC),
            **data.model_dump(),
        )
        with self._lock:
            self._conn.execute("BEGIN IMMEDIATE")
            try:
                clash = self._conn.execute(
                    "SELECT 1 FROM appointments WHERE provider_id = ? "
                    "AND start_time < ? AND end_time > ? LIMIT 1",
                    (data.provider_id, _to_text(end), _to_text(start)),
                ).fetchone()
                if clash:
                    raise SlotConflictError(data.provider_id)
                self._conn.execute(
                    self._INSERT,
                    (
                        str(appt.id),
                        appt.patient_ref,
                        appt.clinic_id,
                        appt.provider_id,
                        appt.appointment_type.value,
                        _to_text(start),
                        _to_text(end),
                        appt.duration_minutes,
                        appt.status.value,
                        _to_text(appt.created_at),
                    ),
                )
                self._conn.execute("COMMIT")
            except BaseException:
                self._conn.execute("ROLLBACK")
                raise
        return appt

    def get(self, appointment_id: uuid.UUID) -> Appointment | None:
        with self._lock:
            row = self._conn.execute(self._SELECT_ONE, (str(appointment_id),)).fetchone()
        return self._row_to_model(row) if row else None

    def list(self, clinic_id: str | None, limit: int) -> list[Appointment]:
        with self._lock:
            if clinic_id:
                rows = self._conn.execute(self._SELECT_BY_CLINIC, (clinic_id, limit)).fetchall()
            else:
                rows = self._conn.execute(self._SELECT_ALL, (limit,)).fetchall()
        return [self._row_to_model(r) for r in rows]

    def ping(self) -> bool:
        try:
            with self._lock:
                self._conn.execute("SELECT 1").fetchone()
            return True
        except sqlite3.Error:
            return False

    def close(self) -> None:
        self._conn.close()


class PostgresStore:
    _SELECT_ONE = (
        "SELECT id, patient_ref, clinic_id, provider_id, appointment_type, start_time, "
        "duration_minutes, status, created_at FROM appointments WHERE id = %s"
    )
    _SELECT_ALL = (
        "SELECT id, patient_ref, clinic_id, provider_id, appointment_type, start_time, "
        "duration_minutes, status, created_at FROM appointments ORDER BY start_time LIMIT %s"
    )
    _SELECT_BY_CLINIC = (
        "SELECT id, patient_ref, clinic_id, provider_id, appointment_type, start_time, "
        "duration_minutes, status, created_at FROM appointments "
        "WHERE clinic_id = %s ORDER BY start_time LIMIT %s"
    )

    def __init__(self, url: str, min_size: int = 2, max_size: int = 10) -> None:
        # Imported lazily so SQLite-only setups don't need libpq.
        import psycopg
        from psycopg_pool import ConnectionPool

        # A connection pool: opening a new PostgreSQL connection per request
        # (TCP + auth handshake) made ~15% of requests miss the 300 ms latency
        # SLO in the local load test (reports/slo/local-load-test-v0.1.0-no-pool.json).
        # open() does not wait, so the API still starts while the DB is down.
        self._pool = ConnectionPool(
            url,
            min_size=min_size,
            max_size=max_size,
            timeout=5,
            kwargs={"connect_timeout": 3, "autocommit": False},
            open=False,
        )
        self._pool.open(wait=False)
        self._schema_ready = False
        # If the database is not up yet the API still starts; /readyz reports
        # "not ready" (so Kubernetes sends it no traffic) until this succeeds.
        with contextlib.suppress(psycopg.OperationalError):
            self._ensure_schema()

    def _ensure_schema(self) -> None:
        if self._schema_ready:
            return
        with self._connect() as conn:
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS appointments (
                    id UUID PRIMARY KEY,
                    patient_ref TEXT NOT NULL,
                    clinic_id TEXT NOT NULL,
                    provider_id TEXT NOT NULL,
                    appointment_type TEXT NOT NULL,
                    start_time TIMESTAMPTZ NOT NULL,
                    end_time TIMESTAMPTZ NOT NULL,
                    duration_minutes INTEGER NOT NULL,
                    status TEXT NOT NULL,
                    created_at TIMESTAMPTZ NOT NULL
                )
                """
            )
            conn.execute(
                "CREATE INDEX IF NOT EXISTS ix_provider_time "
                "ON appointments (provider_id, start_time)"
            )
        self._schema_ready = True

    def _connect(self):
        # Borrow a pooled connection; it commits on success, rolls back on error
        # and returns to the pool when the `with` block ends.
        return self._pool.connection()

    @staticmethod
    def _row_to_model(row: tuple) -> Appointment:
        return Appointment(
            id=row[0],
            patient_ref=row[1],
            clinic_id=row[2],
            provider_id=row[3],
            appointment_type=row[4],
            start_time=row[5],
            duration_minutes=row[6],
            status=row[7],
            created_at=row[8],
        )

    def create(self, data: AppointmentCreate) -> Appointment:
        start = data.start_time
        end = start + timedelta(minutes=data.duration_minutes)
        appt = Appointment(
            id=uuid.uuid4(),
            status=AppointmentStatus.booked,
            created_at=datetime.now(UTC),
            **data.model_dump(),
        )
        self._ensure_schema()
        with self._connect() as conn, conn.transaction():
            # Serialise bookings per provider for the length of this transaction.
            conn.execute("SELECT pg_advisory_xact_lock(hashtext(%s))", (data.provider_id,))
            clash = conn.execute(
                "SELECT 1 FROM appointments WHERE provider_id = %s "
                "AND start_time < %s AND end_time > %s LIMIT 1",
                (data.provider_id, end, start),
            ).fetchone()
            if clash:
                raise SlotConflictError(data.provider_id)
            conn.execute(
                "INSERT INTO appointments (id, patient_ref, clinic_id, provider_id, "
                "appointment_type, start_time, end_time, duration_minutes, status, created_at) "
                "VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s)",
                (
                    appt.id,
                    appt.patient_ref,
                    appt.clinic_id,
                    appt.provider_id,
                    appt.appointment_type.value,
                    start,
                    end,
                    appt.duration_minutes,
                    appt.status.value,
                    appt.created_at,
                ),
            )
        return appt

    def get(self, appointment_id: uuid.UUID) -> Appointment | None:
        self._ensure_schema()
        with self._connect() as conn:
            row = conn.execute(self._SELECT_ONE, (appointment_id,)).fetchone()
        return self._row_to_model(row) if row else None

    def list(self, clinic_id: str | None, limit: int) -> list[Appointment]:
        self._ensure_schema()
        with self._connect() as conn:
            if clinic_id:
                rows = conn.execute(self._SELECT_BY_CLINIC, (clinic_id, limit)).fetchall()
            else:
                rows = conn.execute(self._SELECT_ALL, (limit,)).fetchall()
        return [self._row_to_model(r) for r in rows]

    def ping(self) -> bool:
        try:
            self._ensure_schema()
            with self._connect() as conn:
                conn.execute("SELECT 1").fetchone()
            return True
        except Exception:  # noqa: BLE001 - any DB failure means "not ready"
            return False

    def close(self) -> None:
        self._pool.close()


def build_store(database_url: str) -> AppointmentStore:
    if database_url.startswith("sqlite:///"):
        return SQLiteStore(database_url.removeprefix("sqlite:///"))
    if database_url.startswith(("postgresql://", "postgres://")):
        return PostgresStore(database_url)
    raise ValueError("DATABASE_URL must start with sqlite:/// or postgresql://")
