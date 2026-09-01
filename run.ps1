# Launch the TRACE Streamlit app from the project venv.
$ErrorActionPreference = "Stop"
Set-Location -Path $PSScriptRoot

$py = Join-Path $PSScriptRoot ".venv\Scripts\python.exe"
if (-not (Test-Path $py)) {
    Write-Error "venv not found. Create it first:  py -3.12 -m venv .venv ; .\.venv\Scripts\python.exe -m pip install -r requirements.txt"
}

& $py -m streamlit run app.py --server.port 8501
