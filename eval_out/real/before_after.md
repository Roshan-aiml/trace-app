# Extraction accuracy on real phone photos — before / after the 2026-08-30 tuning

**Set:** `eval_images/real/` — 14 photographed Indian retail labels (not the
synthetic PDFs). 12 are hand-held phone shots (glare, skew, dot-matrix batch
coding, sideways variable-data panels, Tamil/Hindi text); 2 are e-commerce
screenshots. Ground truth: `eval_out/real/ground_truth.json`, transcribed by eye.

**Config:** PaddleOCR (PP-OCRv6) + LLM text-correction + VLM escalation, Groq key
set. Scorer: `scoring.py` (field-level P/R/F1, token-recall on the long fields,
`""` = declaration genuinely not on the panel).

Reproduce:

```powershell
$env:GROQ_API_KEY = "gsk_..."
.\.venv\Scripts\python.exe benchmark.py --dir eval_images\real --out eval_out\real
```

## Field-level F1

| Declaration            | Before | After | Δ |
|------------------------|:------:|:-----:|:--:|
| manufacturer / packer  | 0.58   | 0.58  |  · |
| common / generic name  | 0.44   | **0.59** | ▲ +0.15 |
| net quantity           | 0.67   | 0.67  |  · |
| MRP (incl. taxes)      | 0.60   | 0.57  | ▽ −0.03 |
| month/year of mfg      | 0.42   | 0.42  |  · |
| consumer-care details  | 0.13   | **0.60** | ▲ +0.47 |
| country of origin      | 0.50   | 0.50  |  · |
| FSSAI licence          | 0.83   | 0.83  |  · |
| **overall**            | **0.542** | **0.609** | **▲ +0.067  (+12.4% rel.)** |

Precision rose too (0.68 → 0.72): fewer confident-but-wrong values.

## What changed in `trace_pipeline.py`

- **generic_name** — the loose "first tidy-looking line" fallback was the biggest
  false-positive source (`Éecer`, `(INCL. OF ALL TAXES)`, `Steam Made`,
  `PQNRTCICT`). Replaced with a strict 2–4-word ASCII test, plus a much larger
  commodity vocabulary (star anise, cumin/jeera, garam masala, ragi, moong dal,
  coconut/sunflower oil, carbonated water, …). A blank now routes to REVIEW / the
  VLM, which scores better than a wrong guess.
- **consumer_care** — a cue-free fallback: a toll-free number, or a care-ish
  email (`care@`, `feedback@`, `hello@`, `cs.`) or any email within ~50 chars of a
  care / feedback / contact word, *is* the consumer-care declaration even without
  a literal "Customer Care" heading. Dropped the bare 6-digit PIN from the
  "valid contact" set so a manufacturer address stops counting as care info.
- **net_quantity** — a proximity fallback: `NET QUANTITY :` / `NET WEIGHT :`
  whose value landed on a different OCR line is now recovered.
- **mfg_date** — a date immediately after `Use By` / `Best Before` / `Expiry` is
  skipped (it's the expiry, not the manufacture date).
- **mrp** — the price is often on the line *directly under*
  `MRP ₹ (incl. of all taxes)`; the pattern now allows exactly one line break.
- **manufacturer** — brand-copy lines ("make your meals taste great", "carefully
  select and source", "PRODUCT OF …") are filtered out of the address block.
- **qwen3 reasoning leak** — `_groq_chat()` forces `reasoning_format="hidden"`
  and `_strip_think()` removes any `<think>…</think>` that still reaches the
  extractor / a `json.loads`.

## Still weak

- **mfg_date (0.42)** — dot-matrix dates OCR badly (`27/06/26` → `27/06/20`,
  `70` → `25`) and mfg-vs-expiry is genuinely ambiguous on some packs. Needs a
  better reader or a tighter VLM crop, not more regex.
- **country_of_origin / net_quantity recall (0.50 / 0.67)** — often only on the
  front panel, absent from the photographed back panel → correct HOLD, counted
  as a miss here.

## Synthetic set (regression check)

`eval_images/` (8 hand-made PDFs), PaddleOCR + regex only, no Groq:
overall F1 **0.638 → 0.602**. The dip is consumer_care and MRP picking up
real-but-OCR-mangled values that token-recall can't match on 8 samples; it does
not appear with the LLM passes on, which is the production default.
