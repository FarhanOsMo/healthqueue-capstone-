"""Logs, metrics and traces - the three signals the SLOs are built on.

* Logs    : one JSON object per line, always carrying request_id and trace_id so
            a log line can be joined to its trace. Request/response bodies are
            never logged (they could contain patient references).
* Metrics : Prometheus counters/histograms exposed on /metrics. Labels use the
            route *template* (/v1/appointments/{appointment_id}) not the raw path,
            which keeps cardinality bounded and keeps IDs out of metrics.
* Traces  : OpenTelemetry SDK + FastAPI auto-instrumentation. Spans go to an
            OTLP collector only if OTEL_EXPORTER_OTLP_ENDPOINT is set.
"""

from __future__ import annotations

import contextvars
import json
import logging
import sys
from datetime import UTC, datetime

from opentelemetry import trace
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor, ConsoleSpanExporter
from prometheus_client import Counter, Histogram

from app.config import Settings

request_id_var: contextvars.ContextVar[str | None] = contextvars.ContextVar(
    "request_id", default=None
)

# ---------------------------------------------------------------- metrics ---
# Bucket edges include 0.3 s exactly, because the latency SLO threshold is
# 300 ms: the SLI can then be computed exactly from the `le="0.3"` bucket.
LATENCY_BUCKETS = (0.005, 0.01, 0.025, 0.05, 0.1, 0.2, 0.3, 0.5, 1.0, 2.5, 5.0)

HTTP_REQUESTS = Counter(
    "healthqueue_http_requests_total",
    "HTTP requests handled, by route template and status code.",
    ["method", "route", "status"],
)
HTTP_LATENCY = Histogram(
    "healthqueue_http_request_duration_seconds",
    "HTTP request latency in seconds, by route template.",
    ["method", "route"],
    buckets=LATENCY_BUCKETS,
)
APPOINTMENT_SUBMISSIONS = Counter(
    "healthqueue_appointment_submissions_total",
    "Appointment create attempts by outcome (created | rejected_validation | conflict | error).",
    ["outcome"],
)


# ---------------------------------------------------------------- logging ---
class JsonFormatter(logging.Formatter):
    _RESERVED = set(vars(logging.makeLogRecord({})).keys()) | {"message", "asctime"}

    def format(self, record: logging.LogRecord) -> str:
        payload: dict[str, object] = {
            "ts": datetime.fromtimestamp(record.created, UTC).isoformat(timespec="milliseconds"),
            "level": record.levelname,
            "logger": record.name,
            "msg": record.getMessage(),
            "request_id": request_id_var.get(),
        }
        span_ctx = trace.get_current_span().get_span_context()
        if span_ctx.is_valid:
            payload["trace_id"] = format(span_ctx.trace_id, "032x")
            payload["span_id"] = format(span_ctx.span_id, "016x")
        # Structured extras passed via logger.info("...", extra={...})
        for key, value in record.__dict__.items():
            if key not in self._RESERVED and not key.startswith("_"):
                payload[key] = value
        if record.exc_info:
            # Exception *type* only; tracebacks can leak data and go to traces instead.
            payload["exc_type"] = record.exc_info[0].__name__ if record.exc_info[0] else None
        return json.dumps(payload, default=str)


def configure_logging(level: str) -> None:
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonFormatter())
    root = logging.getLogger()
    root.handlers[:] = [handler]
    root.setLevel(level)
    # Uvicorn's own access log would duplicate ours (and log raw paths).
    logging.getLogger("uvicorn.access").disabled = True


# ---------------------------------------------------------------- tracing ---
_tracing_configured = False


def configure_tracing(settings: Settings) -> None:
    """Install the global tracer provider once per process."""
    global _tracing_configured
    if _tracing_configured:
        return
    resource = Resource.create(
        {
            "service.name": settings.service_name,
            "service.version": settings.version,
            "deployment.environment": settings.environment,
        }
    )
    provider = TracerProvider(resource=resource)
    if settings.otlp_endpoint:
        from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter

        provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter()))
    if settings.trace_console:
        provider.add_span_processor(BatchSpanProcessor(ConsoleSpanExporter()))
    trace.set_tracer_provider(provider)
    _tracing_configured = True
