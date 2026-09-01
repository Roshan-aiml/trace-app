# TRACE Mobile (Flutter)

Camera-first client for the TRACE Legal-Metrology label-compliance backend.
One Flutter codebase → **Android** (primary) and **web** (used for the demo,
since no Android SDK is set up on the build machine yet).

## What's here

| Screen | File | Does |
|---|---|---|
| Login / Register | `lib/screens/login_screen.dart` | JWT auth, role pick, editable API URL + a "ping server" check |
| Scan | `lib/screens/scan_screen.dart` | camera / gallery capture (`image_picker`), upload, live poll of `/api/scan/{id}` |
| Result | `lib/screens/result_screen.dart` | verdict banner, quality metrics, per-declaration table, violations, human-in-the-loop decision (Approve / Hold / Rescan / manager Override), JSON / CSV / PDF export |
| History | `lib/screens/history_screen.dart` | debounced product-name search, verdict filter chips, infinite scroll |
| Sessions | `lib/screens/sessions_screen.dart` | group a shipment's scans; the active session is attached to new scans |
| Dashboard | `lib/screens/dashboard_screen.dart` | manager-only: totals, pass rate, verdict/mode mix, recent |
| Audit log | `lib/screens/audit_screen.dart` | manager-only enforcement view |

`lib/api/api_client.dart` is a typed client that matches the backend contract 1:1;
`lib/api/models.dart` holds the DTOs; `lib/state/` has the `provider` stores.

## Run it

The backend must be running first (see `../backend` and `../RUN.md`).

### Web (works today, no Android SDK needed)

```powershell
cd mobile
C:\flutter\bin\flutter run -d chrome --dart-define=API_BASE=http://localhost:8000
```

Camera capture on web uses the browser file/camera picker. On a laptop you pick a
file; on a phone browser it opens the camera.

### Android (once an Android SDK / Android Studio is installed)

```powershell
flutter run -d <device-id>          # emulator: API_BASE defaults to http://10.0.2.2:8000
flutter build apk --release --dart-define=API_BASE=http://<your-lan-ip>:8000
```

The manifest already declares `CAMERA` + `INTERNET` and allows cleartext HTTP so a
device on the same Wi-Fi can reach a dev backend. `com.squarematrix.trace_mobile`
is the application id.

### Point at a different backend

Set it on the login screen ("Server settings"), or pass
`--dart-define=API_BASE=http://host:8000` at build/run time. The value you type is
persisted.

## Demo logins

`manager@trace.local` / `worker@trace.local` — password `trace1234`
(seeded by the backend on first start).
