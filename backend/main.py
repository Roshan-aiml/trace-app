"""TRACE backend -- FastAPI service that wraps the PaddleOCR + qwen pipeline.

Run from the repo root:
    backend\\.venv... -m uvicorn backend.main:app --reload --port 8000
or use  backend/run.ps1  /  python -m backend
"""
import csv
import io
import json
import os
import uuid
from pathlib import Path
from typing import Optional

from fastapi import (Depends, FastAPI, File, Form, HTTPException, Query,
                     UploadFile, status)
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse, StreamingResponse
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from .config import (ALLOWED_IMAGE_TYPES, CORS_ORIGINS, GROQ_CONFIGURED,
                     IS_DEV_SECRET, MAX_UPLOAD_BYTES, PROJECT_ROOT, SEED_DEMO,
                     UPLOAD_DIR)
from .db import audit, get_db, init_db, utcnow
from .models import (LoginRequest, OverrideRequest, RegisterRequest,
                     SessionCreate, VerifyRequest)
from .security import create_token, decode_token, hash_password, verify_password
from .worker import pipeline_status, rules_meta, start_scan_job

app = FastAPI(title="TRACE API", version="1.0.0",
              description="Legal Metrology packaged-commodity label compliance checks.")

app.add_middleware(
    CORSMiddleware,
    allow_origins=CORS_ORIGINS,
    allow_origin_regex=None if CORS_ORIGINS != ["*"] else r".*",
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)

bearer = HTTPBearer(auto_error=False)


# --------------------------------------------------------------------------- #
#  startup
# --------------------------------------------------------------------------- #
@app.on_event("startup")
def _startup() -> None:
    init_db()
    if IS_DEV_SECRET:
        print("\n  !! TRACE_JWT_SECRET is the insecure dev default -- set it before deploying.\n")
    if SEED_DEMO:
        con = get_db()
        try:
            n = con.execute("SELECT COUNT(*) FROM users").fetchone()[0]
            if n == 0:
                for email, role in (("manager@trace.local", "manager"),
                                    ("worker@trace.local", "worker")):
                    con.execute(
                        "INSERT INTO users(email, password_hash, role, full_name, created_at) "
                        "VALUES (?,?,?,?,?)",
                        (email, hash_password("trace1234"), role,
                         role.capitalize() + " Demo", utcnow()),
                    )
                con.commit()
                print("  seeded demo logins:  manager@trace.local / worker@trace.local   (password: trace1234)\n")
        finally:
            con.close()


# --------------------------------------------------------------------------- #
#  auth helpers
# --------------------------------------------------------------------------- #
def _public_user(row) -> dict:
    return {"id": row["id"], "email": row["email"], "role": row["role"],
            "full_name": row["full_name"], "created_at": row["created_at"]}


def _user_from_token(raw: str) -> dict:
    try:
        payload = decode_token(raw)
    except Exception:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Invalid or expired token")
    con = get_db()
    try:
        row = con.execute("SELECT * FROM users WHERE id=?", (int(payload["sub"]),)).fetchone()
    finally:
        con.close()
    if row is None:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "User no longer exists")
    return dict(row)


def current_user(cred: Optional[HTTPAuthorizationCredentials] = Depends(bearer)) -> dict:
    if cred is None or not cred.credentials:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Not authenticated")
    return _user_from_token(cred.credentials)


def current_user_flex(
    cred: Optional[HTTPAuthorizationCredentials] = Depends(bearer),
    token: Optional[str] = Query(None, description="bearer token as a query param, for plain <a> downloads"),
) -> dict:
    """Auth for GET endpoints that a browser hits as a bare link (export / PDF /
    image) -- accepts the token in the Authorization header *or* ?token=."""
    raw = cred.credentials if (cred and cred.credentials) else token
    if not raw:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Not authenticated")
    return _user_from_token(raw)


def require_manager(user: dict = Depends(current_user)) -> dict:
    if user["role"] != "manager":
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Manager role required")
    return user


# --------------------------------------------------------------------------- #
#  meta
# --------------------------------------------------------------------------- #
@app.get("/")
def root():
    return {"service": "TRACE API", "version": app.version, "docs": "/docs"}


@app.get("/api/health")
def health():
    return {
        "status": "ok",
        "pipeline": pipeline_status(),
        "groq_configured": GROQ_CONFIGURED,
        "dev_secret": IS_DEV_SECRET,
    }


@app.get("/api/meta/fields")
def meta_fields(_: dict = Depends(current_user)):
    """Declaration key -> {label, required}. Lets the client render field names
    without hard-coding the rule pack."""
    return rules_meta()


# --------------------------------------------------------------------------- #
#  auth
# --------------------------------------------------------------------------- #
@app.post("/api/auth/register", status_code=201)
def register(body: RegisterRequest):
    con = get_db()
    try:
        if con.execute("SELECT 1 FROM users WHERE email=?", (body.email,)).fetchone():
            raise HTTPException(status.HTTP_409_CONFLICT, "Email already registered")
        cur = con.execute(
            "INSERT INTO users(email, password_hash, role, full_name, created_at) VALUES (?,?,?,?,?)",
            (body.email, hash_password(body.password), body.role, body.full_name, utcnow()),
        )
        con.commit()
        row = con.execute("SELECT * FROM users WHERE id=?", (cur.lastrowid,)).fetchone()
        audit(con, _public_user(row), "auth.register", "user", row["id"])
        con.commit()
        return _public_user(row)
    finally:
        con.close()


@app.post("/api/auth/login")
def login(body: LoginRequest):
    con = get_db()
    try:
        row = con.execute("SELECT * FROM users WHERE email=?", (body.email,)).fetchone()
        if row is None or not verify_password(body.password, row["password_hash"]):
            raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Wrong email or password")
        audit(con, dict(row), "auth.login", "user", row["id"])
        con.commit()
        token = create_token(row["id"], row["email"], row["role"])
        return {"access_token": token, "token_type": "bearer",
                "role": row["role"], "user": _public_user(row)}
    finally:
        con.close()


@app.get("/api/auth/me")
def me(user: dict = Depends(current_user)):
    return _public_user(user)


# --------------------------------------------------------------------------- #
#  sessions
# --------------------------------------------------------------------------- #
def _session_dict(con, row) -> dict:
    counts = con.execute(
        "SELECT "
        " COUNT(*) AS total, "
        " SUM(verdict='PASS') AS pass, "
        " SUM(verdict='REVIEW') AS review, "
        " SUM(verdict='HOLD') AS hold, "
        " SUM(verdict='REJECTED') AS rejected, "
        " SUM(status='PROCESSING') AS processing "
        "FROM inspections WHERE session_id=?", (row["id"],)).fetchone()
    d = dict(row)
    d["counts"] = {k: (counts[k] or 0) for k in
                   ("total", "pass", "review", "hold", "rejected", "processing")}
    return d


@app.post("/api/sessions", status_code=201)
def create_session(body: SessionCreate, user: dict = Depends(current_user)):
    con = get_db()
    try:
        cur = con.execute(
            "INSERT INTO sessions(name, location, note, created_by, created_at) VALUES (?,?,?,?,?)",
            (body.name, body.location, body.note, user["id"], utcnow()),
        )
        audit(con, user, "session.create", "session", cur.lastrowid, {"name": body.name})
        con.commit()
        row = con.execute("SELECT * FROM sessions WHERE id=?", (cur.lastrowid,)).fetchone()
        return _session_dict(con, row)
    finally:
        con.close()


@app.get("/api/sessions")
def list_sessions(user: dict = Depends(current_user),
                  mine: bool = Query(False, description="only sessions I created")):
    con = get_db()
    try:
        if mine:
            rows = con.execute(
                "SELECT * FROM sessions WHERE created_by=? ORDER BY created_at DESC", (user["id"],)
            ).fetchall()
        else:
            rows = con.execute("SELECT * FROM sessions ORDER BY created_at DESC").fetchall()
        return [_session_dict(con, r) for r in rows]
    finally:
        con.close()


@app.get("/api/sessions/{session_id}")
def get_session(session_id: int, user: dict = Depends(current_user)):
    con = get_db()
    try:
        row = con.execute("SELECT * FROM sessions WHERE id=?", (session_id,)).fetchone()
        if row is None:
            raise HTTPException(404, "Session not found")
        return _session_dict(con, row)
    finally:
        con.close()


@app.post("/api/sessions/{session_id}/close")
def close_session(session_id: int, user: dict = Depends(current_user)):
    con = get_db()
    try:
        row = con.execute("SELECT * FROM sessions WHERE id=?", (session_id,)).fetchone()
        if row is None:
            raise HTTPException(404, "Session not found")
        con.execute("UPDATE sessions SET closed_at=? WHERE id=?", (utcnow(), session_id))
        audit(con, user, "session.close", "session", session_id)
        con.commit()
        return _session_dict(con, con.execute("SELECT * FROM sessions WHERE id=?", (session_id,)).fetchone())
    finally:
        con.close()


# --------------------------------------------------------------------------- #
#  scanning
# --------------------------------------------------------------------------- #
def _inspection_dict(row, *, with_result=True) -> dict:
    d = dict(row)
    raw = d.pop("result_json", None)
    if with_result:
        d["result"] = json.loads(raw) if raw else None
    d["effective_verdict"] = d.get("override_verdict") or d.get("verdict")
    return d


@app.post("/api/scan", status_code=202)
async def create_scan(
    file: UploadFile = File(...),
    session_id: Optional[int] = Form(None),
    product_name: Optional[str] = Form(None),
    capture_mode: str = Form("live_scan"),
    use_llm: bool = Form(True),
    quality_override: bool = Form(False),
    user: dict = Depends(current_user),
):
    if capture_mode not in ("upload", "live_scan"):
        raise HTTPException(422, "capture_mode must be 'upload' or 'live_scan'")
    if file.content_type and file.content_type not in ALLOWED_IMAGE_TYPES:
        raise HTTPException(415, f"Unsupported image type: {file.content_type}")

    data = await file.read()
    if not data:
        raise HTTPException(422, "Empty upload")
    if len(data) > MAX_UPLOAD_BYTES:
        raise HTTPException(413, f"Image exceeds {MAX_UPLOAD_BYTES // (1024*1024)} MB limit")

    ext = (Path(file.filename or "").suffix or ".jpg").lower()
    if ext not in (".jpg", ".jpeg", ".png", ".webp"):
        ext = ".jpg"
    fname = f"{uuid.uuid4().hex}{ext}"
    fpath = UPLOAD_DIR / fname
    fpath.write_bytes(data)

    con = get_db()
    try:
        if session_id is not None:
            if con.execute("SELECT 1 FROM sessions WHERE id=?", (session_id,)).fetchone() is None:
                raise HTTPException(404, "session_id does not exist")
        cur = con.execute(
            "INSERT INTO inspections(session_id, created_by, product_name, capture_mode, "
            " image_path, status, created_at) VALUES (?,?,?,?,?,'PROCESSING',?)",
            (session_id, user["id"], product_name, capture_mode, str(fpath), utcnow()),
        )
        insp_id = cur.lastrowid
        audit(con, user, "scan.create", "inspection", insp_id,
              {"session_id": session_id, "capture_mode": capture_mode})
        con.commit()
    finally:
        con.close()

    start_scan_job(insp_id, str(fpath), capture_mode, bool(use_llm), bool(quality_override))
    return {"id": insp_id, "status": "PROCESSING"}


@app.get("/api/scan/{inspection_id}")
def get_scan(inspection_id: int, user: dict = Depends(current_user)):
    con = get_db()
    try:
        row = con.execute("SELECT * FROM inspections WHERE id=?", (inspection_id,)).fetchone()
        if row is None:
            raise HTTPException(404, "Scan not found")
        return _inspection_dict(row)
    finally:
        con.close()


# --------------------------------------------------------------------------- #
#  inspections  (search / retrieval)
# --------------------------------------------------------------------------- #
@app.get("/api/inspections")
def list_inspections(
    user: dict = Depends(current_user),
    q: Optional[str] = Query(None, description="substring match on product name"),
    verdict: Optional[str] = Query(None),
    status_: Optional[str] = Query(None, alias="status"),
    session_id: Optional[int] = Query(None),
    mine: bool = Query(False),
    page: int = Query(1, ge=1),
    page_size: int = Query(20, ge=1, le=100),
):
    where, params = ["1=1"], []
    if q:
        where.append("LOWER(COALESCE(i.product_name,'')) LIKE ?")
        params.append(f"%{q.lower()}%")
    if verdict:
        where.append("(COALESCE(i.override_verdict, i.verdict) = ?)")
        params.append(verdict.upper())
    if status_:
        where.append("i.status = ?")
        params.append(status_.upper())
    if session_id is not None:
        where.append("i.session_id = ?")
        params.append(session_id)
    if mine:
        where.append("i.created_by = ?")
        params.append(user["id"])
    clause = " AND ".join(where)

    con = get_db()
    try:
        total = con.execute(f"SELECT COUNT(*) FROM inspections i WHERE {clause}", params).fetchone()[0]
        rows = con.execute(
            f"SELECT i.id, i.session_id, i.created_by, i.product_name, i.capture_mode, i.status, i.verdict, "
            f" i.override_verdict, i.override_reason, i.human_decision, i.decision_note, i.decided_at, "
            f" i.created_at, i.completed_at, i.error, "
            f" u.email AS inspector_email, u.full_name AS inspector_name, u.role AS inspector_role, "
            f" s.name AS session_name "
            f"FROM inspections i "
            f"LEFT JOIN users u ON i.created_by = u.id "
            f"LEFT JOIN sessions s ON i.session_id = s.id "
            f"WHERE {clause} ORDER BY i.created_at DESC LIMIT ? OFFSET ?",
            params + [page_size, (page - 1) * page_size],
        ).fetchall()
        items = []
        for r in rows:
            d = dict(r)
            d["effective_verdict"] = d.get("override_verdict") or d.get("verdict")
            # Inferred product category based on product name or default
            pname = (d.get("product_name") or "").lower()
            if any(k in pname for k in ("oil", "milk", "butter", "ghee", "juice", "drink", "water")):
                d["category"] = "Beverage / Liquid"
            elif any(k in pname for k in ("biscuit", "cookie", "bread", "atta", "flour", "rice", "dal", "pulse", "snack", "noodle", "pasta")):
                d["category"] = "Food / Grain / Snack"
            elif any(k in pname for k in ("soap", "shampoo", "cream", "lotion", "paste", "detergent", "cleaner")):
                d["category"] = "Personal Care / Cleaning"
            elif any(k in pname for k in ("tablet", "syrup", "capsule", "drop", "medicine", "pharma")):
                d["category"] = "Pharmaceutical"
            else:
                d["category"] = "Packaged Commodity"
            items.append(d)
        return {"items": items, "total": total, "page": page, "page_size": page_size,
                "pages": (total + page_size - 1) // page_size}
    finally:
        con.close()


@app.get("/api/inspections/{inspection_id}")
def get_inspection(inspection_id: int, user: dict = Depends(current_user)):
    con = get_db()
    try:
        row = con.execute(
            "SELECT i.*, u.email AS inspector_email, u.full_name AS inspector_name, u.role AS inspector_role, "
            " s.name AS session_name "
            "FROM inspections i "
            "LEFT JOIN users u ON i.created_by = u.id "
            "LEFT JOIN sessions s ON i.session_id = s.id "
            "WHERE i.id=?",
            (inspection_id,),
        ).fetchone()
        if row is None:
            raise HTTPException(404, "Inspection not found")
        d = _inspection_dict(row)
        pname = (d.get("product_name") or "").lower()
        if any(k in pname for k in ("oil", "milk", "butter", "ghee", "juice", "drink", "water")):
            d["category"] = "Beverage / Liquid"
        elif any(k in pname for k in ("biscuit", "cookie", "bread", "atta", "flour", "rice", "dal", "pulse", "snack", "noodle", "pasta")):
            d["category"] = "Food / Grain / Snack"
        elif any(k in pname for k in ("soap", "shampoo", "cream", "lotion", "paste", "detergent", "cleaner")):
            d["category"] = "Personal Care / Cleaning"
        elif any(k in pname for k in ("tablet", "syrup", "capsule", "drop", "medicine", "pharma")):
            d["category"] = "Pharmaceutical"
        else:
            d["category"] = "Packaged Commodity"
        return d
    finally:
        con.close()


@app.post("/api/inspections/{inspection_id}/verify")
def verify_inspection(inspection_id: int, body: VerifyRequest, user: dict = Depends(current_user)):
    con = get_db()
    try:
        row = con.execute("SELECT * FROM inspections WHERE id=?", (inspection_id,)).fetchone()
        if row is None:
            raise HTTPException(404, "Inspection not found")
        if row["status"] != "DONE":
            raise HTTPException(409, f"Inspection is {row['status']}, cannot record a decision yet")
        con.execute(
            "UPDATE inspections SET human_decision=?, decision_note=?, decided_by=?, decided_at=? WHERE id=?",
            (body.decision, body.note, user["id"], utcnow(), inspection_id),
        )
        audit(con, user, f"decision.{body.decision.lower()}", "inspection", inspection_id,
              {"decision": body.decision, "note": body.note, "product_name": row["product_name"]})
        con.commit()
        return _inspection_dict(con.execute("SELECT * FROM inspections WHERE id=?", (inspection_id,)).fetchone())
    finally:
        con.close()


@app.post("/api/inspections/{inspection_id}/override")
def override_inspection(inspection_id: int, body: OverrideRequest, user: dict = Depends(require_manager)):
    con = get_db()
    try:
        row = con.execute("SELECT * FROM inspections WHERE id=?", (inspection_id,)).fetchone()
        if row is None:
            raise HTTPException(404, "Inspection not found")
        con.execute(
            "UPDATE inspections SET override_verdict=?, override_reason=?, decided_by=?, decided_at=?, "
            " human_decision='Override' WHERE id=?",
            (body.verdict, body.reason, user["id"], utcnow(), inspection_id),
        )
        audit(con, user, "manager.override", "inspection", inspection_id,
              {"from": row["verdict"], "to": body.verdict, "reason": body.reason, "product_name": row["product_name"]})
        con.commit()
        return _inspection_dict(con.execute("SELECT * FROM inspections WHERE id=?", (inspection_id,)).fetchone())
    finally:
        con.close()


# --------------------------------------------------------------------------- #
#  reports / export
# --------------------------------------------------------------------------- #
@app.get("/api/inspections/{inspection_id}/export")
def export_inspection(inspection_id: int, format: str = Query("json", pattern="^(json|csv)$"),
                      user: dict = Depends(current_user_flex)):
    con = get_db()
    try:
        row = con.execute("SELECT * FROM inspections WHERE id=?", (inspection_id,)).fetchone()
    finally:
        con.close()
    if row is None:
        raise HTTPException(404, "Inspection not found")
    record = _inspection_dict(row)
    result = record.get("result") or {}
    fields = result.get("fields", {})

    if format == "json":
        payload = {
            "inspection_id": record["id"],
            "product_name": record.get("product_name"),
            "verdict": record.get("verdict"),
            "effective_verdict": record.get("effective_verdict"),
            "human_decision": record.get("human_decision"),
            "override": {"verdict": record.get("override_verdict"),
                         "reason": record.get("override_reason")},
            "created_at": record.get("created_at"),
            "completed_at": record.get("completed_at"),
            "quality_metrics": result.get("quality_metrics"),
            "violations": result.get("violations"),
            "review_notes": result.get("review_notes"),
            "fields": fields,
        }
        return JSONResponse(
            payload,
            headers={"Content-Disposition": f'attachment; filename="trace_inspection_{inspection_id}.json"'},
        )

    labels = {k: v["label"] for k, v in rules_meta().items()}
    buf = io.StringIO()
    w = csv.writer(buf)
    w.writerow(["declaration_key", "label", "value", "confidence", "level", "status"])
    for key, f in fields.items():
        w.writerow([key, labels.get(key, key), (f or {}).get("value"),
                    (f or {}).get("confidence"), (f or {}).get("level"), (f or {}).get("status")])
    w.writerow([])
    w.writerow(["inspection_id", inspection_id])
    w.writerow(["verdict", record.get("verdict")])
    w.writerow(["effective_verdict", record.get("effective_verdict")])
    w.writerow(["human_decision", record.get("human_decision")])
    for i, v in enumerate(result.get("violations", []) or []):
        w.writerow([f"violation_{i+1}", v])
    buf.seek(0)
    return StreamingResponse(
        iter([buf.getvalue()]),
        media_type="text/csv",
        headers={"Content-Disposition": f'attachment; filename="trace_inspection_{inspection_id}.csv"'},
    )


@app.get("/api/inspections/{inspection_id}/report.pdf")
def report_pdf(inspection_id: int, user: dict = Depends(current_user_flex)):
    con = get_db()
    try:
        row = con.execute("SELECT * FROM inspections WHERE id=?", (inspection_id,)).fetchone()
    finally:
        con.close()
    if row is None:
        raise HTTPException(404, "Inspection not found")
    record = _inspection_dict(row)
    result = record.get("result")
    if not result:
        raise HTTPException(409, "No pipeline result to report on yet")

    import sys
    if str(PROJECT_ROOT) not in sys.path:
        sys.path.insert(0, str(PROJECT_ROOT))
    from trace_pipeline import generate_pdf_report

    out = UPLOAD_DIR / f"report_{inspection_id}.pdf"
    result.setdefault("capture_mode", record.get("capture_mode"))
    generate_pdf_report(result, record.get("image_path"), str(out))

    con2 = get_db()
    try:
        audit(con2, user, "report.generate", "inspection", inspection_id, {"format": "pdf"})
        con2.commit()
    finally:
        con2.close()

    return FileResponse(str(out), media_type="application/pdf",
                        filename=f"trace_report_{inspection_id}.pdf")


@app.get("/api/inspections/{inspection_id}/image")
def inspection_image(inspection_id: int, user: dict = Depends(current_user_flex)):
    con = get_db()
    try:
        row = con.execute("SELECT image_path FROM inspections WHERE id=?", (inspection_id,)).fetchone()
    finally:
        con.close()
    if row is None or not row["image_path"] or not os.path.exists(row["image_path"]):
        raise HTTPException(404, "Image not found")
    return FileResponse(row["image_path"])


# --------------------------------------------------------------------------- #
#  Manager Reports & Audit Endpoints
# --------------------------------------------------------------------------- #
@app.get("/api/manager/session-summary")
def manager_session_summary(
    session_id: Optional[int] = Query(None),
    user: dict = Depends(require_manager)
):
    con = get_db()
    try:
        # If no session_id, pick the latest session with inspections or most recent session
        if session_id is None:
            s_row = con.execute("SELECT * FROM sessions ORDER BY created_at DESC LIMIT 1").fetchone()
        else:
            s_row = con.execute("SELECT * FROM sessions WHERE id=?", (session_id,)).fetchone()

        if s_row is None:
            # Return empty/default summary when no sessions exist
            return {
                "session": None,
                "total_inspections": 0,
                "passed_count": 0,
                "review_count": 0,
                "held_count": 0,
                "rejected_count": 0,
                "human_approvals": 0,
                "rescans": 0,
                "overrides": 0,
                "compliance_percentage": 0.0,
                "duration_seconds": 0,
                "duration_str": "0 mins",
                "inspections": [],
            }

        s_dict = dict(s_row)
        sid = s_dict["id"]

        # Calculate session time duration
        c_at = s_dict.get("created_at") or ""
        cl_at = s_dict.get("closed_at") or utcnow()
        duration_str = "Active session"
        duration_secs = 0
        try:
            from datetime import datetime
            t1 = datetime.fromisoformat(c_at.replace("Z", "+00:00"))
            t2 = datetime.fromisoformat(cl_at.replace("Z", "+00:00"))
            duration_secs = max(0, int((t2 - t1).total_seconds()))
            if duration_secs < 60:
                duration_str = f"{duration_secs}s"
            elif duration_secs < 3600:
                duration_str = f"{duration_secs // 60}m {duration_secs % 60}s"
            else:
                duration_str = f"{duration_secs // 3600}h {(duration_secs % 3600) // 60}m"
        except Exception:
            pass

        # Counts
        total = con.execute("SELECT COUNT(*) FROM inspections WHERE session_id=?", (sid,)).fetchone()[0]
        passed = con.execute(
            "SELECT COUNT(*) FROM inspections WHERE session_id=? AND COALESCE(override_verdict, verdict)='PASS'",
            (sid,)
        ).fetchone()[0]
        review = con.execute(
            "SELECT COUNT(*) FROM inspections WHERE session_id=? AND COALESCE(override_verdict, verdict)='REVIEW'",
            (sid,)
        ).fetchone()[0]
        held = con.execute(
            "SELECT COUNT(*) FROM inspections WHERE session_id=? AND COALESCE(override_verdict, verdict)='HOLD'",
            (sid,)
        ).fetchone()[0]
        rejected = con.execute(
            "SELECT COUNT(*) FROM inspections WHERE session_id=? AND COALESCE(override_verdict, verdict)='REJECTED'",
            (sid,)
        ).fetchone()[0]

        approvals = con.execute(
            "SELECT COUNT(*) FROM inspections WHERE session_id=? AND LOWER(COALESCE(human_decision,'')) LIKE '%approve%'",
            (sid,)
        ).fetchone()[0]
        rescans = con.execute(
            "SELECT COUNT(*) FROM inspections WHERE session_id=? AND LOWER(COALESCE(human_decision,'')) LIKE '%rescan%'",
            (sid,)
        ).fetchone()[0]
        overrides = con.execute(
            "SELECT COUNT(*) FROM inspections WHERE session_id=? AND override_verdict IS NOT NULL",
            (sid,)
        ).fetchone()[0]

        compliance_pct = round((passed / total * 100.0), 1) if total > 0 else 0.0

        # Session inspections list
        rows = con.execute(
            "SELECT i.id, i.session_id, i.product_name, i.status, i.verdict, i.override_verdict, "
            " i.human_decision, i.created_at, i.completed_at, u.email AS inspector_email, u.full_name AS inspector_name "
            "FROM inspections i "
            "LEFT JOIN users u ON i.created_by = u.id "
            "WHERE i.session_id=? ORDER BY i.created_at DESC",
            (sid,)
        ).fetchall()

        insp_list = []
        for r in rows:
            d = dict(r)
            d["effective_verdict"] = d.get("override_verdict") or d.get("verdict")
            insp_list.append(d)

        return {
            "session": s_dict,
            "total_inspections": total,
            "passed_count": passed,
            "review_count": review,
            "held_count": held,
            "rejected_count": rejected,
            "human_approvals": approvals,
            "rescans": rescans,
            "overrides": overrides,
            "compliance_percentage": compliance_pct,
            "duration_seconds": duration_secs,
            "duration_str": duration_str,
            "inspections": insp_list,
        }
    finally:
        con.close()


@app.get("/api/manager/review-queue")
def manager_review_queue(user: dict = Depends(require_manager)):
    """Returns inspections needing Manager attention (REVIEW, HOLD, Overrides, or Unconfirmed)."""
    con = get_db()
    try:
        rows = con.execute(
            "SELECT i.*, u.email AS inspector_email, u.full_name AS inspector_name, s.name AS session_name "
            "FROM inspections i "
            "LEFT JOIN users u ON i.created_by = u.id "
            "LEFT JOIN sessions s ON i.session_id = s.id "
            "WHERE (i.verdict IN ('REVIEW', 'HOLD') OR i.override_verdict IS NOT NULL OR i.human_decision IN ('Hold', 'Rescan') OR i.status='FAILED') "
            "ORDER BY i.created_at DESC"
        ).fetchall()

        items = []
        for r in rows:
            d = _inspection_dict(r)
            res = d.get("result") or {}
            # Categorize review reason
            reasons = []
            if d.get("verdict") == "REVIEW":
                reasons.append("AI Recommended Review (Uncertain/Weak Fields)")
            if d.get("verdict") == "HOLD":
                reasons.append("AI Recommended Hold (Missing Mandatory Declarations)")
            if res.get("violations"):
                reasons.append(f"{len(res['violations'])} Compliance Violation(s)")
            if res.get("review_notes"):
                reasons.append(f"{len(res['review_notes'])} Manual Check Item(s)")
            if d.get("override_verdict"):
                reasons.append(f"Human Override: {d['verdict']} -> {d['override_verdict']}")
            if not reasons:
                reasons.append("Flagged for Manager Verification")
            d["review_reasons"] = reasons
            items.append(d)

        return {
            "items": items,
            "total_pending": len(items),
        }
    finally:
        con.close()


@app.post("/api/manager/review-queue/{inspection_id}/action")
def manager_review_action(
    inspection_id: int,
    action: str = Form(...),  # approve | hold | rescan | confirm
    note: Optional[str] = Form(None),
    user: dict = Depends(require_manager),
):
    con = get_db()
    try:
        row = con.execute("SELECT * FROM inspections WHERE id=?", (inspection_id,)).fetchone()
        if row is None:
            raise HTTPException(404, "Inspection not found")

        action_clean = action.lower()
        if action_clean == "approve":
            con.execute(
                "UPDATE inspections SET override_verdict='PASS', override_reason=?, decided_by=?, decided_at=?, "
                " human_decision='Approve (Manager)' WHERE id=?",
                (note or "Approved by Manager", user["id"], utcnow(), inspection_id),
            )
            audit(con, user, "manager.approve", "inspection", inspection_id,
                  {"product_name": row["product_name"], "note": note, "from_verdict": row["verdict"]})
        elif action_clean == "hold":
            con.execute(
                "UPDATE inspections SET override_verdict='HOLD', override_reason=?, decided_by=?, decided_at=?, "
                " human_decision='Hold (Manager)' WHERE id=?",
                (note or "Held by Manager", user["id"], utcnow(), inspection_id),
            )
            audit(con, user, "manager.hold", "inspection", inspection_id,
                  {"product_name": row["product_name"], "note": note, "from_verdict": row["verdict"]})
        elif action_clean == "rescan":
            con.execute(
                "UPDATE inspections SET human_decision='Rescan Requested', decision_note=?, decided_by=?, decided_at=? WHERE id=?",
                (note or "Rescan requested by Manager", user["id"], utcnow(), inspection_id),
            )
            audit(con, user, "manager.rescan", "inspection", inspection_id,
                  {"product_name": row["product_name"], "note": note})
        elif action_clean == "confirm":
            con.execute(
                "UPDATE inspections SET human_decision='Confirmed (Manager)', decision_note=?, decided_by=?, decided_at=? WHERE id=?",
                (note or "Confirmed by Manager", user["id"], utcnow(), inspection_id),
            )
            audit(con, user, "manager.confirm", "inspection", inspection_id,
                  {"product_name": row["product_name"], "note": note, "verdict": row["verdict"]})
        else:
            raise HTTPException(400, f"Unsupported action: {action}")

        con.commit()
        return _inspection_dict(con.execute("SELECT * FROM inspections WHERE id=?", (inspection_id,)).fetchone())
    finally:
        con.close()


@app.get("/api/analytics/dashboard")
def analytics_dashboard(user: dict = Depends(require_manager)):
    con = get_db()
    try:
        total = con.execute("SELECT COUNT(*) FROM inspections").fetchone()[0]
        by_verdict = {v or "PENDING": c for v, c in con.execute(
            "SELECT COALESCE(override_verdict, verdict), COUNT(*) FROM inspections GROUP BY 1"
        ).fetchall()}
        done = con.execute("SELECT COUNT(*) FROM inspections WHERE status='DONE'").fetchone()[0]
        passed = by_verdict.get("PASS", 0)
        overridden = con.execute(
            "SELECT COUNT(*) FROM inspections WHERE override_verdict IS NOT NULL").fetchone()[0]
        by_day = [{"date": d, "count": c} for d, c in con.execute(
            "SELECT substr(created_at,1,10) AS d, COUNT(*) FROM inspections "
            "GROUP BY d ORDER BY d DESC LIMIT 14"
        ).fetchall()]
        by_mode = {m or "?": c for m, c in con.execute(
            "SELECT capture_mode, COUNT(*) FROM inspections GROUP BY capture_mode").fetchall()}
        recent = [dict(r) for r in con.execute(
            "SELECT id, product_name, status, verdict, override_verdict, created_at "
            "FROM inspections ORDER BY created_at DESC LIMIT 10").fetchall()]
        open_sessions = con.execute("SELECT COUNT(*) FROM sessions WHERE closed_at IS NULL").fetchone()[0]
        return {
            "total_inspections": total,
            "completed": done,
            "by_verdict": by_verdict,
            "by_capture_mode": by_mode,
            "pass_rate": round(passed / done, 3) if done else None,
            "overridden": overridden,
            "by_day": list(reversed(by_day)),
            "open_sessions": open_sessions,
            "recent": recent,
        }
    finally:
        con.close()


@app.get("/api/audit")
def audit_log(user: dict = Depends(require_manager),
              page: int = Query(1, ge=1), page_size: int = Query(50, ge=1, le=200),
              action: Optional[str] = Query(None)):
    where, params = ["1=1"], []
    if action:
        where.append("a.action LIKE ?")
        params.append(f"{action}%")
    clause = " AND ".join(where)
    con = get_db()
    try:
        total = con.execute(f"SELECT COUNT(*) FROM audit_log a WHERE {clause}", params).fetchone()[0]
        rows = con.execute(
            f"SELECT a.id, a.ts, a.user_id, a.user_email, a.action, a.entity, a.entity_id, a.detail, "
            f" u.role AS user_role, u.full_name AS user_name "
            f"FROM audit_log a "
            f"LEFT JOIN users u ON a.user_id = u.id "
            f"WHERE {clause} ORDER BY a.id DESC LIMIT ? OFFSET ?",
            params + [page_size, (page - 1) * page_size],
        ).fetchall()
        return {"items": [dict(r) for r in rows], "total": total,
                "page": page, "page_size": page_size}
    finally:
        con.close()
