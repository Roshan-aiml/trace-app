# TRACE — Delivery status

SIH 2026 · Problem 26034 · Team Square Matrix · 30 Aug 2026

A mobile-first system that reads a photographed packaged-commodity label and
returns a defensible **PASS / REVIEW / HOLD** against the Legal Metrology
(Packaged Commodities) Rules, 2011.

Visual summary (shareable): the delivery dossier artifact published from this
session — architecture diagram, endpoint list, accuracy bars, run steps.

---

## Built and wired end to end

| Piece | Location | State |
|---|---|---|
| ML pipeline | `trace_pipeline.py` | quality gate → PaddleOCR PP-OCRv6 → LLM text-correction → regex rule-pack → VLM escalation → rule engine. Groq (`qwen/qwen3.6-27b`) for the LLM + VLM roles. |
| REST backend | `backend/` (FastAPI + SQLite) | 21 endpoints under `/api`: JWT auth (worker/manager), sessions, async `POST /scan` + `GET /scan/{id}` poll, inspection search, `verify` / manager `override`, JSON/CSV/PDF export, `analytics/dashboard` + `audit` (manager-only). No external services. Imports the pipeline in-process. |
| Mobile app | `mobile/` (Flutter, Android + web) | login/register, live scan with progress, result (verdict, quality %, per-declaration table, violations, decision), history (search + verdict filters), sessions, manager dashboard, audit. Typed client 1:1 with the backend. |

Verified this session: `flutter analyze` clean · unit test passes ·
`flutter build web` compiles · backend end-to-end (login → multipart upload →
background OCR → verdict → verify → export → PDF) run against a live server ·
CORS + token-in-URL downloads confirmed.

## Run

See **[RUN.md](RUN.md)** (or `run_stack.ps1`). In short:

```powershell
$env:TRACE_JWT_SECRET = "change-me" ; $env:GROQ_API_KEY = "gsk_..."
.\backend\run.ps1                                    # :8000, docs at /docs
cd mobile ; C:\flutter\bin\flutter run -d chrome --dart-define=API_BASE=http://localhost:8000
```

Demo logins (seeded on first backend start): `manager@trace.local` /
`worker@trace.local`, password `trace1234`.

## Accuracy

Two benchmarks, both via `benchmark.py` + `scoring.py`:

* `eval_images/` — 8 synthetic label PDFs. PaddleOCR + regex only: F1 ≈ 0.60.
* `eval_images/real/` — **14 hand-verified real phone photos** (glare, skew,
  dot-matrix codes, sideways panels, Tamil/Hindi, 2 screenshots). Full pipeline
  with Groq key: **F1 0.542 → 0.609** after the 30 Aug tuning pass
  (consumer-care 0.13 → 0.60, generic-name 0.44 → 0.59). Detail:
  **[eval_out/real/before_after.md](eval_out/real/before_after.md)**.

## Open edges

* No Android SDK on the build machine → demo runs on Flutter web; the project is
  Android-ready (manifest, permissions, app id), an APK needs only the SDK.
* `mfg_date` extraction (F1 0.42) — dot-matrix date OCR + mfg-vs-expiry ambiguity.
* Placement-on-label checks, Rule 18 true letter-height, exemption
  auto-detection — presence/format only, as documented.
* `eval_images/_archive/` (~40 more photos) not yet ground-truthed.
