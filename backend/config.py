"""Runtime configuration, all overridable by environment variable.

    TRACE_JWT_SECRET     signing key for auth tokens  (MUST be set for real deploys)
    TRACE_JWT_EXPIRE_HOURS   token lifetime, default 12
    TRACE_CORS_ORIGINS   comma-separated allowed origins, or "*" (default) for dev
    TRACE_DB_PATH        sqlite file path, default backend/trace.db
    TRACE_UPLOAD_DIR     uploaded-image dir, default backend/uploads
    TRACE_SEED_DEMO      "1" (default) seeds a demo manager + worker on first run
    GROQ_API_KEY         optional -- enables the LLM correction + VLM escalation passes
"""
import os
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = BASE_DIR.parent

DB_PATH = Path(os.environ.get("TRACE_DB_PATH", BASE_DIR / "trace.db"))
UPLOAD_DIR = Path(os.environ.get("TRACE_UPLOAD_DIR", BASE_DIR / "uploads"))
UPLOAD_DIR.mkdir(parents=True, exist_ok=True)

JWT_SECRET = os.environ.get("TRACE_JWT_SECRET", "dev-insecure-change-me")
JWT_EXPIRE_HOURS = int(os.environ.get("TRACE_JWT_EXPIRE_HOURS", "12"))
IS_DEV_SECRET = JWT_SECRET == "dev-insecure-change-me"

_cors = os.environ.get("TRACE_CORS_ORIGINS", "*").strip()
CORS_ORIGINS = ["*"] if _cors == "*" else [o.strip() for o in _cors.split(",") if o.strip()]

SEED_DEMO = os.environ.get("TRACE_SEED_DEMO", "1") not in ("0", "false", "False", "")
GROQ_CONFIGURED = bool(os.environ.get("GROQ_API_KEY"))

MAX_UPLOAD_BYTES = int(os.environ.get("TRACE_MAX_UPLOAD_BYTES", str(15 * 1024 * 1024)))
ALLOWED_IMAGE_TYPES = {"image/jpeg", "image/jpg", "image/png", "image/webp"}
