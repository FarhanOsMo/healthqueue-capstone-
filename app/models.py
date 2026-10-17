"""Request/response schemas and validation rules.

Privacy by design: the API never accepts names, dates of birth, phone numbers
or free-text notes. A patient is identified only by an opaque, pseudonymous
reference (e.g. "PT-000123") issued by a separate identity system.
`extra="forbid"` rejects any unexpected field so PHI cannot be smuggled in.
"""

from __future__ import annotations

from datetime import UTC, datetime, timedelta
from enum import StrEnum
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, field_validator

PATIENT_REF_PATTERN = r"^PT-[0-9]{6}$"
CLINIC_ID_PATTERN = r"^CLN-[0-9]{3}$"
PROVIDER_ID_PATTERN = r"^PRV-[0-9]{4}$"


class AppointmentType(StrEnum):
    checkup = "checkup"
    follow_up = "follow_up"
    vaccination = "vaccination"
    consultation = "consultation"


class AppointmentStatus(StrEnum):
    booked = "booked"


class AppointmentCreate(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)

    patient_ref: str = Field(pattern=PATIENT_REF_PATTERN, examples=["PT-000123"])
    clinic_id: str = Field(pattern=CLINIC_ID_PATTERN, examples=["CLN-001"])
    provider_id: str = Field(pattern=PROVIDER_ID_PATTERN, examples=["PRV-0042"])
    appointment_type: AppointmentType
    start_time: datetime = Field(examples=["2026-11-03T14:30:00Z"])
    duration_minutes: int = Field(ge=15, le=120, examples=[30])

    @field_validator("start_time")
    @classmethod
    def must_be_timezone_aware(cls, value: datetime) -> datetime:
        if value.tzinfo is None or value.utcoffset() is None:
            raise ValueError("start_time must include a timezone, e.g. 2026-11-03T14:30:00Z")
        return value.astimezone(UTC)

    @field_validator("duration_minutes")
    @classmethod
    def must_be_slot_multiple(cls, value: int) -> int:
        if value % 15 != 0:
            raise ValueError("duration_minutes must be a multiple of 15")
        return value

    def check_booking_window(self, now: datetime, max_days_ahead: int) -> str | None:
        """Business rules that depend on 'now'. Returns an error message or None."""
        if self.start_time <= now:
            return "start_time must be in the future"
        if self.start_time > now + timedelta(days=max_days_ahead):
            return f"start_time must be within {max_days_ahead} days"
        return None


class Appointment(BaseModel):
    id: UUID
    patient_ref: str
    clinic_id: str
    provider_id: str
    appointment_type: AppointmentType
    start_time: datetime
    duration_minutes: int
    status: AppointmentStatus
    created_at: datetime


class AppointmentList(BaseModel):
    items: list[Appointment]
    count: int


class ErrorResponse(BaseModel):
    error: str
    message: str
    request_id: str | None = None
    details: list[dict] | None = None
