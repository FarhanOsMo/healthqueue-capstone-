"""Metrics, structured logs and trace correlation."""

from __future__ import annotations

import json
import logging

from prometheus_client import REGISTRY

from app.observability import JsonFormatter, request_id_var


def _sample(name: str, labels: dict) -> float:
    return REGISTRY.get_sample_value(name, labels) or 0.0


def test_metrics_endpoint_exposes_slo_metrics(client):
    client.get("/healthz")
    r = client.get("/metrics")
    assert r.status_code == 200
    text = r.text
    assert "healthqueue_http_requests_total" in text
    assert "healthqueue_http_request_duration_seconds_bucket" in text
    assert 'le="0.3"' in text  # exact SLO threshold bucket


def test_request_counter_uses_route_template_not_raw_id(client, valid_payload):
    created = client.post("/v1/appointments", json=valid_payload).json()
    labels = {"method": "GET", "route": "/v1/appointments/{appointment_id}", "status": "200"}
    before = _sample("healthqueue_http_requests_total", labels)
    client.get(f"/v1/appointments/{created['id']}")
    assert _sample("healthqueue_http_requests_total", labels) == before + 1
    assert created["id"] not in client.get("/metrics").text


def test_submission_outcomes_counted(client, valid_payload):
    def outcome(name):
        return _sample("healthqueue_appointment_submissions_total", {"outcome": name})

    created, rejected, conflict = (
        outcome("created"),
        outcome("rejected_validation"),
        outcome("conflict"),
    )
    client.post("/v1/appointments", json=valid_payload)
    client.post("/v1/appointments", json=valid_payload)  # same slot -> conflict
    client.post("/v1/appointments", json={**valid_payload, "clinic_id": "bad"})
    assert outcome("created") == created + 1
    assert outcome("conflict") == conflict + 1
    assert outcome("rejected_validation") == rejected + 1


def test_server_errors_counted_as_5xx(client, store, valid_payload, monkeypatch):
    labels = {"method": "POST", "route": "/v1/appointments", "status": "500"}
    before = _sample("healthqueue_http_requests_total", labels)
    monkeypatch.setattr(store, "create", lambda _: (_ for _ in ()).throw(RuntimeError("x")))
    client.post("/v1/appointments", json=valid_payload)
    assert _sample("healthqueue_http_requests_total", labels) == before + 1


class _ListHandler(logging.Handler):
    """Formats each record at emit time (while the trace context is active)."""

    def __init__(self):
        super().__init__()
        self.setFormatter(JsonFormatter())
        self.lines: list[str] = []

    def emit(self, record):
        self.lines.append(self.format(record))


def test_json_log_line_has_request_and_trace_ids(client):
    handler = _ListHandler()
    logging.getLogger().addHandler(handler)
    try:
        client.post(
            "/v1/appointments",
            json={"bad": "payload"},
            headers={"X-Request-ID": "req-test-0001"},
        )
    finally:
        logging.getLogger().removeHandler(handler)
    lines = [json.loads(line) for line in handler.lines]
    completed = [entry for entry in lines if entry.get("msg") == "request completed"]
    assert completed, "expected a 'request completed' log line"
    entry = completed[-1]
    assert entry["request_id"] == "req-test-0001"
    assert entry["route"] == "/v1/appointments"
    assert entry["status"] == 422
    assert len(entry["trace_id"]) == 32  # OpenTelemetry trace id correlation
    assert "bad" not in json.dumps(entry)  # request body never logged


def test_formatter_without_request_context():
    record = logging.makeLogRecord({"msg": "hello", "levelname": "INFO", "name": "t"})
    token = request_id_var.set(None)
    out = json.loads(JsonFormatter().format(record))
    request_id_var.reset(token)
    assert out["msg"] == "hello"
    assert out["request_id"] is None
