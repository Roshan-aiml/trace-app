"""SQLite access. A fresh connection per call keeps it safe to use from the
request thread and the background scan worker at the same time (WAL mode)."""
import sqlite3
from datetime import datetime, timezone

from .config import DB_PATH

SCHEMA = """
CREATE TABLE IF NOT EXISTS users (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    email         TEXT UNIQUE NOT NULL,
    password_hash TEXT NOT NULL,
    role          TEXT NOT NULL DEFAULT 'worker',      -- worker | manager
    full_name     TEXT,
    created_at    TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS sessions (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    name        TEXT NOT NULL,
    location    TEXT,
    note        TEXT,
    created_by  INTEGER REFERENCES users(id),
    created_at  TEXT NOT NULL,
    closed_at   TEXT
);

CREATE TABLE IF NOT EXISTS inspections (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id       INTEGER REFERENCES sessions(id),
    created_by       INTEGER REFERENCES users(id),
    product_name     TEXT,
    capture_mode     TEXT,
    image_path       TEXT,
    status           TEXT NOT NULL DEFAULT 'PROCESSING', -- PROCESSING | DONE | FAILED
    verdict          TEXT,                               -- PASS | REVIEW | HOLD | REJECTED
    result_json      TEXT,
    error            TEXT,
    human_decision   TEXT,
    decision_note    TEXT,
    decided_by       INTEGER REFERENCES users(id),
    decided_at       TEXT,
    override_verdict TEXT,
    override_reason  TEXT,
    created_at       TEXT NOT NULL,
    completed_at     TEXT
);

CREATE TABLE IF NOT EXISTS audit_log (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    ts          TEXT NOT NULL,
    user_id     INTEGER,
    user_email  TEXT,
    action      TEXT NOT NULL,
    entity      TEXT,
    entity_id   INTEGER,
    detail      TEXT
);

CREATE INDEX IF NOT EXISTS ix_inspections_session ON inspections(session_id);
CREATE INDEX IF NOT EXISTS ix_inspections_status  ON inspections(status);
CREATE INDEX IF NOT EXISTS ix_inspections_created ON inspections(created_at);
CREATE INDEX IF NOT EXISTS ix_audit_ts            ON audit_log(ts);
"""


def utcnow() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def get_db() -> sqlite3.Connection:
    con = sqlite3.connect(DB_PATH, timeout=15)
    con.row_factory = sqlite3.Row
    con.execute("PRAGMA journal_mode=WAL")
    con.execute("PRAGMA foreign_keys=ON")
    return con


def init_db() -> None:
    con = get_db()
    try:
        con.executescript(SCHEMA)
        con.commit()
    finally:
        con.close()


def audit(con: sqlite3.Connection, user: dict | None, action: str,
          entity: str | None = None, entity_id: int | None = None, detail=None) -> None:
    import json
    if not isinstance(detail, (str, type(None))):
        detail = json.dumps(detail, default=str)
    con.execute(
        "INSERT INTO audit_log(ts, user_id, user_email, action, entity, entity_id, detail) "
        "VALUES (?,?,?,?,?,?,?)",
        (utcnow(), (user or {}).get("id"), (user or {}).get("email"),
         action, entity, entity_id, detail),
    )
