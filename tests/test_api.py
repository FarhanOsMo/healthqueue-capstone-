"""API-level tests: HTTP status codes, headers and response bodies."""

from __future__ import annotations

import uuid

from tests.conftest import future


def test_healthz(client):
    r = client.get("/healthz")
    assert r.status_code == 200
    assert r.json() == {"status": "ok"}


def test_readyz_when_store_available(client):
    r = client.get("/readyz")
    assert r.status_code == 200
    assert r.json()["status"] == "ready"


def test_readyz_returns_503_when_store_down(client, store, monkeypatch):
    monkeypatch.setattr(store, "ping", lambda: False)
    r = client.get("/readyz")
    assert r.status_code == 503
    assert r.json()["error"] == "not_ready"


def test_create_then_get_appointment(client, valid_payload):
    created = client.post("/v1/appointments", json=valid_payload)
    assert created.status_code == 201
    body = created.json()
    assert body["status"] == "booked"
    assert body["patient_ref"] == "PT-000123"
    assert created.headers["Location"] == f"/v1/appointments/{body['id']}"

    fetched = client.get(f"/v1/appointments/{body['id']}")
    assert fetched.status_code == 200
    assert fetched.json() == body


def test_get_unknown_appointment_returns_404(client):
    r = client.get(f"/v1/appointments/{uuid.uuid4()}")
    assert r.status_code == 404
    assert r.json()["error"] == "http_error"


def test_get_with_malformed_id_returns_422(client):
    r = client.get("/v1/appointments/not-a-uuid")
    assert r.status_code == 422


def test_double_booking_same_provider_returns_409(client, valid_payload):
    assert client.post("/v1/appointments", json=valid_payload).status_code == 201
    overlapping = {**valid_payload, "patient_ref": "PT-000999", "start_time": future(minute=15)}
    r = client.post("/v1/appointments", json=overlapping)
    assert r.status_code == 409
    assert r.json()["error"] == "slot_unavailable"


def test_back_to_back_slots_do_not_conflict(client, valid_payload):
    assert client.post("/v1/appointments", json=valid_payload).status_code == 201
    next_slot = {**valid_payload, "start_time": future(minute=30)}
    assert client.post("/v1/appointments", json=next_slot).status_code == 201


def test_same_time_different_provider_is_allowed(client, valid_payload):
    assert client.post("/v1/appointments", json=valid_payload).status_code == 201
    other = {**valid_payload, "provider_id": "PRV-0043"}
    assert client.post("/v1/appointments", json=other).status_code == 201


def test_list_filters_by_clinic(client, valid_payload):
    client.post("/v1/appointments", json=valid_payload)
    client.post(
        "/v1/appointments",
        json={**valid_payload, "clinic_id": "CLN-002", "provider_id": "PRV-0100"},
    )
    r = client.get("/v1/appointments", params={"clinic_id": "CLN-002"})
    assert r.status_code == 200
    assert r.json()["count"] == 1
    assert r.json()["items"][0]["clinic_id"] == "CLN-002"


def test_list_rejects_bad_limit(client):
    assert client.get("/v1/appointments", params={"limit": 0}).status_code == 422
    assert client.get("/v1/appointments", params={"limit": 101}).status_code == 422


def test_request_id_is_generated_and_echoed(client):
    r = client.get("/healthz")
    assert len(r.headers["X-Request-ID"]) == 32
    r2 = client.get("/healthz", headers={"X-Request-ID": "abc12345-test"})
    assert r2.headers["X-Request-ID"] == "abc12345-test"


def test_unsafe_request_id_is_replaced(client):
    r = client.get("/healthz", headers={"X-Request-ID": "<script>alert(1)</script>"})
    assert r.headers["X-Request-ID"] != "<script>alert(1)</script>"


def test_security_headers_present(client):
    r = client.get("/healthz")
    assert r.headers["X-Content-Type-Options"] == "nosniff"
    assert r.headers["Cache-Control"] == "no-store"


def test_unhandled_error_returns_safe_500(client, store, valid_payload, monkeypatch):
    def boom(_):
        raise RuntimeError("database password is hunter2")

    monkeypatch.setattr(store, "create", boom)
    r = client.post("/v1/appointments", json=valid_payload)
    assert r.status_code == 500
    assert r.json()["error"] == "internal_error"
    assert "hunter2" not in r.text
    assert "request_id" in r.json()
