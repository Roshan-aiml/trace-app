# TRACE — Legal Metrology Label-Compliance App

PaddleOCR + qwen/qwen3.6-27b (Groq) pipeline that turns a photo of an Indian
packaged-commodity label into a **PASS / REVIEW / HOLD** verdict.

Pipeline: quality gate (clarity % / exposure %) → PaddleOCR (always-on reader,
built-in orientation correction) → LLM text-correction pass → deterministic rule
engine → VLM escalation on weak fields (only if a Groq key is set) → verdict
(biased toward caution: uncertain never becomes PASS).

Two capture modes, one pipeline:
* **Upload** — strict. A bad photo shows clarity/exposure % and stops. No override.
* **Live scan** — same diagnostics **plus** Rescan / Approve-manually on a bad
  photo, and an Approve / Rescan / Hold / Override step on the final verdict.

Extracted from `TRACE_paddleocr_qwen.ipynb` (the `%%writefile` cells) and adapted
to run as a plain local project — no Colab, no localtunnel.

## Three ways to run the same pipeline

| Surface | Path | Use |
|---|---|---|
| **Streamlit app** | `app.py` | quickest single-machine demo / tuning |
| **REST backend** | `backend/` (FastAPI + SQLite + JWT) | the API the mobile app and any web frontend call — auth, sessions, async scan, inspections search, verify/override, JSON/CSV/PDF export, analytics, audit |
| **Flutter mobile app** | `mobile/` | camera-first Android client (also builds for web); talks only to the backend |

Full-stack run instructions: **[RUN.md](RUN.md)**. Backend detail: `backend/` ·
Mobile detail: `mobile/README.md`.

## Requirements

* Windows, **Python 3.11 or 3.12** (this project was built and tested on 3.12.10).
  Do **not** use 3.13 — `paddlepaddle` / `paddleocr` have broken wheels / a
  modelscope import crash there.

## Setup

```powershell
cd "C:\Users\Roshan Sivakumar\trace-app"
py -3.12 -m venv .venv
.\.venv\Scripts\python.exe -m pip install --upgrade pip
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
```

## Run

```powershell
.\.venv\Scripts\python.exe -m streamlit run app.py
```

Then open http://localhost:8501 . First run downloads the PaddleOCR models
(~4 files each for detector / recognizer / 2 orientation classifiers) into
`%USERPROFILE%\.paddlex\official_models` — one-time, ~30–60 s.

`run.ps1` does the same thing.

## Groq API key (optional)

Without a key the pipeline still runs (PaddleOCR + regex rules); every uncertain
field just routes to REVIEW. With a key it also does LLM text correction and VLM
escalation on weak fields. Set it either way:

```powershell
$env:GROQ_API_KEY = "gsk_..."
```

or paste it into the sidebar field in the app.

## Files

| file | what |
|------|------|
| `trace_pipeline.py` | the whole ML pipeline as importable functions (`run_pipeline`, `quality_gate`, `generate_pdf_report`, `log_telemetry`, `RULES_CONFIG`) |
| `app.py` | Streamlit UI — Scan & Inspect / Dashboard / History tabs |
| `backend/` | FastAPI service wrapping `run_pipeline` — `main.py` (routes), `db.py` (SQLite), `security.py` (PBKDF2 + HS256 JWT, no crypto deps), `worker.py` (background scan thread), `run.ps1` |
| `mobile/` | Flutter app — `lib/api/` typed client, `lib/screens/` (login, scan, result, history, sessions, dashboard, audit), Android + web targets |
| `RUN.md` / `run_stack.ps1` | full-stack setup + launcher |
| `requirements.txt` | from the notebook's install cell |
| `trace_history.csv` | telemetry log, created on first "Save to history" |
| `trace_report.pdf` | last generated inspection report |
| `benchmark.py` | evaluation harness — runs a folder of label photos/PDFs through `run_pipeline`, writes per-image dumps + `summary.csv`, and scores against `ground_truth.json` |
| `scoring.py` | field-level P/R/F1 scorer (also runnable standalone: `python scoring.py eval_out/summary.csv`) |
| `eval_images/` | the 8-label evaluation set (`01_…pdf` … `08_…pdf`); `_archive/` holds other sample images, ignored by the harness |
| `eval_out/` | `summary.csv`, `summary_before.csv`, `ground_truth.json`, per-image `.txt` dumps, `score.json` |

## Benchmarking accuracy on real labels

```powershell
# label photos / PDFs go in eval_images\  (top level; subfolders are ignored)
.\.venv\Scripts\python.exe benchmark.py
```

Writes `eval_out\summary.csv`, an `eval_out\<image>.txt` dump per image (quality
metrics, verdict, every declaration + confidence, raw OCR text), and — when
`eval_out\ground_truth.json` exists — a field-level P/R/F1 table + `score.json`.
`ground_truth.json` is the hand-checked answer key; `""` there means the
declaration is genuinely not on the photographed panel (a correct HOLD, not a
miss) and `"a|b"` accepts either value. Re-score any run without re-OCRing:

```powershell
.\.venv\Scripts\python.exe scoring.py eval_out\summary.csv
```

Add `$env:GROQ_API_KEY` before running to benchmark with the LLM/VLM passes on.

## Accuracy on real phone photos (`eval_images/real/`)

The 8 PDFs above are clean synthetic renders. `eval_images/real/` holds **14
hand-verified photographed labels** — glare, skew, dot-matrix batch codes,
sideways variable-data panels, Tamil/Hindi text, plus 2 e-commerce screenshots —
scored with the full pipeline (PaddleOCR + LLM correction + VLM escalation, Groq
key set). Full write-up: `eval_out/real/before_after.md`.

| field | F1 before | F1 after |
|---|---|---|
| manufacturer | 0.58 | 0.58 |
| generic_name | 0.44 | **0.59** |
| net_quantity | 0.67 | 0.67 |
| mrp | 0.60 | 0.57 |
| mfg_date | 0.42 | 0.42 |
| consumer_care | 0.13 | **0.60** |
| country_of_origin | 0.50 | 0.50 |
| fssai_license | 0.83 | 0.83 |
| **overall** | **0.542** | **0.609** |

```powershell
$env:GROQ_API_KEY = "gsk_..."
.\.venv\Scripts\python.exe benchmark.py --dir eval_images\real --out eval_out\real
```

## Extraction tuning applied against the 8 real labels

Field-level accuracy on the 8-label set (PaddleOCR + regex only, no Groq key),
before vs after this tuning — same scorer + ground truth, only `trace_pipeline.py`
changed (full table in `eval_out/before_after.txt`):

| field | F1 before | F1 after |
|---|---|---|
| manufacturer | 0.55 | **0.93** |
| generic_name | 0.00 | **0.75** |
| net_quantity | 0.29 | **0.67** |
| mrp | 0.25 | **0.55** |
| mfg_date | 0.00 | **0.40** |
| consumer_care | 0.18 | **0.57** |
| country_of_origin | 0.00 | **0.50** |
| fssai_license | 0.22 | **0.67** |
| **overall** | **0.21** | **0.66** |

The regex field-extractor was hardened on this label set (see `RULES_CONFIG`
and the helpers in `trace_pipeline.py`):

* **country_of_origin** — also matches `PRODUCT OF INDIA` / `MADE IN INDIA` → `India`.
* **mfg_date** — `DATE_TOKEN` now covers `JUN/26`, `MAY 2026`, `28/MAR/2026`,
  month ranges; plus a proximity fallback for when OCR order splits the label
  from its date.
* **mrp** — collapses dot-matrix digit spacing (`1 9 5 . 0 0`) and doubled
  `Rs.` prefixes before the numeric match; tolerates junk between "MRP" and the price.
* **net_quantity** — "See on main panel" / "See other panel" wording produces a
  HOLD reading *"declared on a different panel, not captured in this photo"*
  instead of a bare "missing". This is correct behaviour, not a bug.
* **consumer_care** — accepts dashed toll-free numbers (`1-800-425-2931`) and
  `+91-…` formats, not just bare 10-digit strings.
* **manufacturer / consumer_care** — the block after the cue line is filtered to
  drop interleaved nutrition-table rows.
* **fssai_license** — recovers a 14-digit licence from OCR noise like
  `LicTo.:1001-047000301`.

### Quality gate recalibration

Indian retail labels are routinely on white pouches / foil / large white
declaration stickers, which tripped the old glare + over-exposure thresholds and
rejected perfectly readable photos (4 of the 8 test labels). `brightness_max`
90→**245**, `brightness_ideal_max`→**215**, and the glare check now fires only
when **>55 %** of the frame is blown to pure white.

### OCR preprocessing (`run_paddle_ocr`)

CLAHE (`cv2.createCLAHE`, applied to the grayscale image after the 1600 px
resize) lifts text out of foil glare / crumple shadows before OCR.
Doc-unwarping (UVDoc) was evaluated but costs **5+ min per image on CPU** and
never completed an 8-image run — left as an opt-in for GPU users via
`TRACE_UNWARP=1`.

## Local adaptations vs. the notebook

1. `HUB_DATASET_ENDPOINT` is pinned at the top of `trace_pipeline.py` before
   `paddleocr` imports — works around the modelscope
   `replace() argument 2 must be str, not None` crash on import.
2. `get_paddle_ocr()` passes `enable_mkldnn=False`. paddlepaddle 3.3.x CPU
   inference otherwise crashes in the oneDNN path
   (`ConvertPirAttribute2RuntimeAttribute not support
   pir::ArrayAttribute<pir::DoubleAttribute>`) on the PP-OCRv6 detector.
3. `/content/...` Colab paths → files next to the module.
4. Colab launch cell (localtunnel / ngrok) dropped — `streamlit run app.py`
   serves on http://localhost:8501 directly.

The 1600px long-side cap in `_to_cv2` (prevents an OOM on full-res phone photos)
and the 0-byte OneDrive-placeholder guard are kept as-is from the notebook.
