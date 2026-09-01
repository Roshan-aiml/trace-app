"""Request/response bodies. Responses that mirror a DB row are built as plain
dicts in main.py; these models cover the typed request payloads and a few
response shapes worth pinning down."""
from typing import Any, Literal, Optional

from pydantic import BaseModel, Field, field_validator

_EMAIL_RE = r"^[^@\s]+@[^@\s]+\.[^@\s]+$"


class RegisterRequest(BaseModel):
    email: str = Field(min_length=3, max_length=190)
    password: str = Field(min_length=6, max_length=128)
    full_name: Optional[str] = None
    role: Literal["worker", "manager"] = "worker"

    @field_validator("email")
    @classmethod
    def _email_shape(cls, v: str) -> str:
        import re
        v = v.strip().lower()
        if not re.match(_EMAIL_RE, v):
            raise ValueError("not a valid email address")
        return v


class LoginRequest(BaseModel):
    email: str
    password: str

    @field_validator("email")
    @classmethod
    def _lower(cls, v: str) -> str:
        return v.strip().lower()


class TokenResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"
    role: str
    user: dict[str, Any]


class SessionCreate(BaseModel):
    name: str = Field(min_length=1, max_length=120)
    location: Optional[str] = None
    note: Optional[str] = None


class VerifyRequest(BaseModel):
    decision: Literal["Approve", "Rescan", "Hold", "Override"]
    note: Optional[str] = None


class OverrideRequest(BaseModel):
    verdict: Literal["PASS", "REVIEW", "HOLD"]
    reason: str = Field(min_length=3, max_length=500)
