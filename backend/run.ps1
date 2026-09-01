# Launch the TRACE FastAPI backend from the project venv.
$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
Set-Location -Path $root

$py = Join-Path $root ".venv\Scripts\python.exe"
if (-not (Test-Path $py)) {
    Write-Error "venv not found. Create it:  py -3.12 -m venv .venv ; .\.venv\Scripts\python.exe -m pip install -r requirements.txt -r backend\requirements.txt"
}

# Bind on all interfaces so a phone on the same Wi-Fi can reach it too.
& $py -m uvicorn backend.main:app --host 0.0.0.0 --port 8000 --reload
