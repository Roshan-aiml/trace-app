"""Background scan runner. `POST /api/scan` returns immediately; this module
does the slow PaddleOCR / LLM work on a daemon thread and writes the result
back into the inspections row the endpoint created."""
import json
import sqlite3
import sys
import threading
import traceback
from datetime import datetime, timezone
from pathlib import Path

from .config import DB_PATH, PROJECT_ROOT

# The ML pipeline lives at the repo root, next to this backend/ package.
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

_pipeline = None
_pipeline_error: str | None = None
_lock = threading.Lock()


def _load_pipeline():
    global _pipeline, _pipeline_error
    with _lock:
        if _pipeline is None and _pipeline_error is None:
            try:
                import trace_pipeline  # noqa: heavy import (paddleocr) -- done once, lazily
                _pipeline = trace_pipeline
            except Exception as exc:  # pragma: no cover - environment dependent
                _pipeline_error = f"{type(exc).__name__}: {exc}"
    return _pipeline


def pipeline_status() -> dict:
    _load_pipeline()
    return {"loaded": _pipeline is not None, "error": _pipeline_error}


def rules_meta() -> dict:
    tp = _load_pipeline()
    if tp is None:
        return {}
    return {k: {"label": v["label"], "required": v["required"]}
            for k, v in tp.RULES_CONFIG.items()}


def _now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def run_scan_job(inspection_id: int, image_path: str, capture_mode: str,
                 use_llm: bool, quality_override: bool = False) -> None:
    tp = _load_pipeline()
    con = sqlite3.connect(DB_PATH, timeout=30)
    con.execute("PRAGMA journal_mode=WAL")
    try:
        if tp is None:
            con.execute(
                "UPDATE inspections SET status='FAILED', error=?, completed_at=? WHERE id=?",
                (f"ML pipeline unavailable: {_pipeline_error}", _now(), inspection_id),
            )
            con.commit()
            return

        result = tp.run_pipeline(
            image_path,
            use_llm_correction=use_llm,
            use_llm_agent=use_llm,
            capture_mode=capture_mode,
            quality_override=quality_override,
        )
        con.execute(
            "UPDATE inspections SET status='DONE', verdict=?, result_json=?, completed_at=? WHERE id=?",
            (result.get("verdict"), json.dumps(result, default=str), _now(), inspection_id),
        )
        # Log to audit trail
        try:
            insp_row = con.execute("SELECT product_name, created_by FROM inspections WHERE id=?", (inspection_id,)).fetchone()
            pname = insp_row["product_name"] if insp_row else None
            user_id = insp_row["created_by"] if insp_row else None
            user_row = con.execute("SELECT email, role, full_name FROM users WHERE id=?", (user_id,)).fetchone() if user_id else None
            user_email = user_row["email"] if user_row else None
            detail_str = json.dumps({
                "verdict": result.get("verdict"),
                "product_name": pname,
                "violations_count": len(result.get("violations", [])),
                "quality_passed": result.get("quality_passed"),
            })
            con.execute(
                "INSERT INTO audit_log(ts, user_id, user_email, action, entity, entity_id, detail) "
                "VALUES (?,?,?,?,?,?,?)",
                (_now(), user_id, user_email, "ai.recommendation", "inspection", inspection_id, detail_str)
            )
        except Exception:
            pass
        con.commit()
        try:
            tp.log_telemetry(result)
        except Exception:
            pass
    except Exception as exc:
        con.execute(
            "UPDATE inspections SET status='FAILED', error=?, completed_at=? WHERE id=?",
            (f"{type(exc).__name__}: {exc}\n{traceback.format_exc()[-1500:]}", _now(), inspection_id),
        )
        try:
            con.execute(
                "INSERT INTO audit_log(ts, user_id, user_email, action, entity, entity_id, detail) "
                "VALUES (?,?,?,?,?,?,?)",
                (_now(), None, "system", "scan.failed", "inspection", inspection_id, str(exc)[:200])
            )
        except Exception:
            pass
        con.commit()
    finally:
        con.close()


def start_scan_job(inspection_id: int, image_path: str, capture_mode: str,
                   use_llm: bool, quality_override: bool = False) -> None:
    threading.Thread(
        target=run_scan_job,
        args=(inspection_id, str(Path(image_path)), capture_mode, use_llm, quality_override),
        daemon=True,
    ).start()
