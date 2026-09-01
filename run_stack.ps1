# Start the TRACE backend (new window) and the Flutter app (this window, Chrome).
# Usage:  .\run_stack.ps1  [-ApiBase http://localhost:8000]  [-Device chrome]
param(
    [string]$ApiBase = "http://localhost:8000",
    [string]$Device  = "chrome"
)
$ErrorActionPreference = "Stop"
Set-Location -Path $PSScriptRoot

$py = Join-Path $PSScriptRoot ".venv\Scripts\python.exe"
if (-not (Test-Path $py)) { Write-Error "venv missing -- see RUN.md step 0" }

$flutter = "C:\flutter\bin\flutter.bat"
if (-not (Test-Path $flutter)) {
    $flutter = (Get-Command flutter -ErrorAction SilentlyContinue).Source
    if (-not $flutter) { Write-Error "flutter not found on PATH or at C:\flutter" }
}

Write-Host "Starting backend on :8000 in a new window..." -ForegroundColor Cyan
Start-Process powershell -ArgumentList @(
    "-NoExit", "-Command",
    "Set-Location '$PSScriptRoot'; `$env:TRACE_JWT_SECRET='dev-demo-secret'; & '$py' -m uvicorn backend.main:app --host 0.0.0.0 --port 8000"
)

Start-Sleep -Seconds 4
Write-Host "Launching Flutter app (device: $Device, API_BASE: $ApiBase)..." -ForegroundColor Cyan
Set-Location (Join-Path $PSScriptRoot "mobile")
& $flutter run -d $Device --dart-define=API_BASE=$ApiBase
