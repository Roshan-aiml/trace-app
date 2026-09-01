# Running the full TRACE stack

Three parts, one machine:

```
Flutter app  ──REST/JSON──▶  FastAPI backend  ──import──▶  trace_pipeline.py
(mobile/)                    (backend/, :8000)             (PaddleOCR + Groq)
```

## 0. One-time setup

```powershell
cd "C:\Users\Roshan Sivakumar\trace-app"

# Python side (backend + ML pipeline share one venv)
py -3.12 -m venv .venv
.\.venv\Scripts\python.exe -m pip install --upgrade pip
.\.venv\Scripts\python.exe -m pip install -r requirements.txt -r backend\requirements.txt

# Flutter side
C:\flutter\bin\flutter --version        # first run precaches the toolchain
cd mobile ; C:\flutter\bin\flutter pub get ; cd ..
```

Optional: `setx GROQ_API_KEY "gsk_..."` to enable the LLM text-correction and
VLM-escalation passes. Without it the pipeline still runs (PaddleOCR + regex) and
uncertain fields route to REVIEW.

## 1. Backend

```powershell
cd "C:\Users\Roshan Sivakumar\trace-app"
$env:TRACE_JWT_SECRET = "change-me-for-real-use"
.\backend\run.ps1
# -> http://localhost:8000     docs at /docs     health at /api/health
```

On first start it creates `backend/trace.db` (SQLite) and seeds two logins:

| email | role | password |
|---|---|---|
| `manager@trace.local` | manager | `trace1234` |
| `worker@trace.local`  | worker  | `trace1234` |

`run.ps1` binds `0.0.0.0` so a phone on the same Wi-Fi can reach it at
`http://<your-PC-LAN-IP>:8000`.

## 2. Mobile app

### Web (no Android SDK required — this is the current demo path)

```powershell
cd mobile
C:\flutter\bin\flutter run -d chrome --dart-define=API_BASE=http://localhost:8000
```

### Android (after installing Android Studio / an SDK + `flutter doctor` is green)

```powershell
flutter run -d <emulator|device>          # emulator uses http://10.0.2.2:8000 by default
flutter build apk --release --dart-define=API_BASE=http://<PC-LAN-IP>:8000
```

## 3. Try it

1. Sign in as `worker@trace.local`.
2. Sessions tab → **New session** ("Warehouse A").
3. Scan tab → **Camera** or **Gallery** → pick a label photo
   (`eval_images/_archive/*.jpeg` are good test inputs) → **Run inspection**.
4. Watch the poll, land on the Result screen: verdict, quality %, declaration
   table, violations. Record **Approve / Hold / Rescan**.
5. Sign in as `manager@trace.local` → **More → Compliance dashboard** / **Audit log**.

## Env vars (backend)

| var | default | meaning |
|---|---|---|
| `TRACE_JWT_SECRET` | `dev-insecure-change-me` | token signing key — **set this** |
| `TRACE_CORS_ORIGINS` | `*` | comma-separated allowed origins for prod |
| `GROQ_API_KEY` | — | enables LLM/VLM passes |
| `TRACE_SEED_DEMO` | `1` | seed the two demo logins on first run |
| `TRACE_DB_PATH` / `TRACE_UPLOAD_DIR` | under `backend/` | storage locations |

## Deploy sketch

* Backend → Render / Railway (free tier) with a persistent disk for `trace.db`
  + `uploads/`. Set `TRACE_JWT_SECRET`, `TRACE_CORS_ORIGINS`, `GROQ_API_KEY`.
* Mobile → `flutter build apk` / Play Store internal testing; point `API_BASE`
  at the deployed backend URL.
