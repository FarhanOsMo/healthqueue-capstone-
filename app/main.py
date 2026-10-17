"""HealthQueue appointment scheduling API.

Endpoints
  GET  /healthz                       liveness  - is the process alive?
  GET  /readyz                        readiness - can it serve traffic (DB reachable)?
  POST /v1/appointments               book an appointment        -> 201 / 409 / 422
  GET  /v1/appointments/{id}          fetch one appointment      -> 200 / 404 / 422
  GET  /v1/appointments?clinic_id=    list appointments (paged)  -> 200
  GET  /metrics                       Prometheus metrics

Run locally:  uvicorn app.main:app --reload
"""

from __future__ import annotations

import logging
import re
import time
import uuid
from contextlib import asynccontextmanager
from datetime import UTC, datetime
from typing import Annotated

from fastapi import FastAPI, HTTPException, Query, Request, Response, status
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from prometheus_client import CONTENT_TYPE_LATEST, generate_latest

from app.config import Settings
from app.models import (
    CLINIC_ID_PATTERN,
    Appointment,
    AppointmentCreate,
    AppointmentList,
    ErrorResponse,
)
from app.observability import (
    APPOINTMENT_SUBMISSIONS,
    HTTP_LATENCY,
    HTTP_REQUESTS,
    configure_logging,
    configure_tracing,
    request_id_var,
)
from app.storage import AppointmentStore, SlotConflictError, build_store

logger = logging.getLogger("healthqueue")

# Accept a caller-supplied request ID only if it is short and harmless.
_SAFE_REQUEST_ID = re.compile(r"^[A-Za-z0-9._-]{8,64}$")
_UNTRACKED_ROUTES = {"/metrics"}


def _error(
    status_code: int, error: str, message: str, details: list[dict] | None = None
) -> JSONResponse:
    body = ErrorResponse(
        error=error, message=message, request_id=request_id_var.get(), details=details
    )
    return JSONResponse(status_code=status_code, content=body.model_dump(exclude_none=True))


def create_app(settings: Settings | None = None, store: AppointmentStore | None = None) -> FastAPI:
    settings = settings or Settings.from_env()
    configure_logging(settings.log_level)
    configure_tracing(settings)

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        app.state.store = store or build_store(settings.database_url)
        logger.info(
            "service started",
            extra={"environment": settings.environment, "version": settings.version},
        )
        yield
        app.state.store.close()

    app = FastAPI(
        title="HealthQueue Appointment API",
        version=settings.version,
        lifespan=lifespan,
        # Interactive docs are handy locally but are attack surface in production.
        docs_url="/docs" if settings.environment != "production" else None,
        redoc_url=None,
    )
    app.state.settings = settings

    # ------------------------------------------------------------ middleware ---
    @app.middleware("http")
    async def observe_request(request: Request, call_next):
        incoming = request.headers.get("x-request-id", "")
        request_id = incoming if _SAFE_REQUEST_ID.match(incoming) else uuid.uuid4().hex
        token = request_id_var.set(request_id)
        started = time.perf_counter()
        try:
            response = await call_next(request)
        except Exception:
            # Last line of defence: never leak a stack trace to the client.
            logger.exception("unhandled error")
            if request.method == "POST" and request.url.path == "/v1/appointments":
                APPOINTMENT_SUBMISSIONS.labels("error").inc()
            response = _error(500, "internal_error", "An unexpected error occurred.")
        elapsed = time.perf_counter() - started

        route = request.scope.get("route")
        route_template = getattr(route, "path", "unmatched")
        if route_template not in _UNTRACKED_ROUTES:
            HTTP_REQUESTS.labels(request.method, route_template, str(response.status_code)).inc()
            HTTP_LATENCY.labels(request.method, route_template).observe(elapsed)
            logger.info(
                "request completed",
                extra={
                    "method": request.method,
                    "route": route_template,
                    "status": response.status_code,
                    "duration_ms": round(elapsed * 1000, 2),
                },
            )
        response.headers["X-Request-ID"] = request_id
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["Cache-Control"] = "no-store"
        request_id_var.reset(token)
        return response

    # ------------------------------------------------------- error handlers ---
    @app.exception_handler(RequestValidationError)
    async def on_validation_error(request: Request, exc: RequestValidationError):
        if request.method == "POST" and request.url.path == "/v1/appointments":
            APPOINTMENT_SUBMISSIONS.labels("rejected_validation").inc()
        # Echo field names and reasons, never the submitted values.
        details = [
            {"field": ".".join(str(p) for p in err["loc"]), "issue": err["msg"]}
            for err in exc.errors()
        ]
        return _error(422, "validation_error", "Request failed validation.", details)

    @app.exception_handler(HTTPException)
    async def on_http_error(request: Request, exc: HTTPException):
        return _error(exc.status_code, "http_error", str(exc.detail))

    # ---------------------------------------------------------------- routes ---
    @app.get("/healthz", tags=["ops"])
    def healthz() -> dict:
        return {"status": "ok"}

    @app.get("/readyz", tags=["ops"])
    def readyz(request: Request):
        if request.app.state.store.ping():
            return {"status": "ready"}
        return _error(503, "not_ready", "Storage is unavailable.")

    @app.get("/metrics", tags=["ops"], include_in_schema=False)
    def metrics() -> Response:
        return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)

    @app.post(
        "/v1/appointments",
        status_code=status.HTTP_201_CREATED,
        response_model=Appointment,
        responses={409: {"model": ErrorResponse}, 422: {"model": ErrorResponse}},
        tags=["appointments"],
    )
    def create_appointment(payload: AppointmentCreate, request: Request, response: Response):
        problem = payload.check_booking_window(datetime.now(UTC), settings.max_days_ahead)
        if problem:
            APPOINTMENT_SUBMISSIONS.labels("rejected_validation").inc()
            return _error(
                422, "validation_error", problem, [{"field": "body.start_time", "issue": problem}]
            )
        try:
            appointment = request.app.state.store.create(payload)
        except SlotConflictError:
            APPOINTMENT_SUBMISSIONS.labels("conflict").inc()
            return _error(409, "slot_unavailable", "The provider already has a booking then.")
        APPOINTMENT_SUBMISSIONS.labels("created").inc()
        logger.info(
            "appointment created",
            extra={"appointment_id": str(appointment.id), "clinic_id": appointment.clinic_id},
        )
        response.headers["Location"] = f"/v1/appointments/{appointment.id}"
        return appointment

    @app.get(
        "/v1/appointments/{appointment_id}",
        response_model=Appointment,
        responses={404: {"model": ErrorResponse}},
        tags=["appointments"],
    )
    def get_appointment(appointment_id: uuid.UUID, request: Request):
        appointment = request.app.state.store.get(appointment_id)
        if appointment is None:
            raise HTTPException(status_code=404, detail="Appointment not found.")
        return appointment

    @app.get("/v1/appointments", response_model=AppointmentList, tags=["appointments"])
    def list_appointments(
        request: Request,
        clinic_id: Annotated[str | None, Query(pattern=CLINIC_ID_PATTERN)] = None,
        limit: Annotated[int, Query(ge=1, le=100)] = 50,
    ):
        items = request.app.state.store.list(clinic_id, limit)
        return AppointmentList(items=items, count=len(items))

    # Health/metrics endpoints are excluded so probes don't flood the traces.
    FastAPIInstrumentor.instrument_app(app, excluded_urls="healthz,readyz,metrics")
    return app


app = create_app()
