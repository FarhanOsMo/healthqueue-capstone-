"""Input validation: every bad input must be rejected with 422 and no data echo."""

from __future__ import annotations

from datetime import UTC, datetime, timedelta

import pytest

from tests.conftest import future


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("patient_ref", "John Smith"),  # real names are never accepted
        ("patient_ref", "PT-12"),
        ("clinic_id", "clinic-1"),
        ("provider_id", "PRV-42"),
        ("appointment_type", "surgery"),
        ("duration_minutes", 10),
        ("duration_minutes", 20),  # not a multiple of 15
        ("duration_minutes", 135),
        ("start_time", "next tuesday"),
        ("start_time", "2026-12-01T09:00:00"),  # no timezone
    ],
)
def test_invalid_field_rejected(client, valid_payload, field, value):
    r = client.post("/v1/appointments", json={**valid_payload, field: value})
    assert r.status_code == 422
    body = r.json()
    assert body["error"] == "validation_error"
    assert any(field in d["field"] for d in body["details"])
    # The submitted value must not be reflected back (short numbers could
    # collide with the random request ID, so only check string inputs).
    if isinstance(value, str):
        assert value not in r.text


def test_missing_field_rejected(client, valid_payload):
    payload = dict(valid_payload)
    del payload["provider_id"]
    r = client.post("/v1/appointments", json=payload)
    assert r.status_code == 422


def test_unknown_field_rejected_to_prevent_phi(client, valid_payload):
    r = client.post("/v1/appointments", json={**valid_payload, "notes": "patient has diabetes"})
    assert r.status_code == 422
    assert "diabetes" not in r.text


def test_past_start_time_rejected(client, valid_payload):
    past = (datetime.now(UTC) - timedelta(hours=1)).isoformat()
    r = client.post("/v1/appointments", json={**valid_payload, "start_time": past})
    assert r.status_code == 422
    assert "future" in r.json()["message"]


def test_too_far_ahead_rejected(client, valid_payload):
    r = client.post("/v1/appointments", json={**valid_payload, "start_time": future(days=400)})
    assert r.status_code == 422
    assert "180 days" in r.json()["message"]


def test_non_json_body_rejected(client):
    r = client.post(
        "/v1/appointments", content="not json", headers={"Content-Type": "application/json"}
    )
    assert r.status_code == 422


def test_timezone_offset_normalised_to_utc(client, valid_payload):
    when = (datetime.now(UTC) + timedelta(days=3)).replace(
        hour=10, minute=0, second=0, microsecond=0
    )
    offset_form = when.replace(tzinfo=None).isoformat() + "-05:00"  # 10:00 at UTC-5 == 15:00Z
    r = client.post("/v1/appointments", json={**valid_payload, "start_time": offset_form})
    assert r.status_code == 201
    stored = datetime.fromisoformat(r.json()["start_time"].replace("Z", "+00:00"))
    assert stored.utcoffset() == timedelta(0)
    assert stored.hour == 15
