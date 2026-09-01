r"""TRACE pipeline benchmark / evaluation harness.

Runs every image (or first page of every PDF) in a folder through the real
`run_pipeline` and reports, per image:
  * quality-gate metrics (clarity % / exposure %) and whether it passed
  * final verdict
  * every declaration: extracted value, level, confidence
  * violations
  * the raw OCR text (so you can see what PaddleOCR actually read)

Outputs (in eval_out/):
  summary.csv        one row per image: verdict + per-field value/level/conf
  <image>.txt        full per-image dump incl. raw OCR text
  score.json         field-level P/R/F1 (also printed) when ground_truth.json exists
  ground_truth.json  hand-checked answer key; "" = declaration not on this panel,
                     "a|b" = either value accepted

Usage:
  .\.venv\Scripts\python.exe benchmark.py                # ./eval_images
  .\.venv\Scripts\python.exe benchmark.py --dir some/dir
  .\.venv\Scripts\python.exe benchmark.py --no-llm       # force OCR+regex only
  .\.venv\Scripts\python.exe scoring.py eval_out/summary.csv   # re-score without re-OCRing
"""
import argparse, json, os, sys, traceback
from datetime import datetime

import pandas as pd

from trace_pipeline import run_pipeline, RULES_CONFIG
import scoring

IMG_EXTS = {".jpg", ".jpeg", ".png", ".bmp", ".webp", ".tif", ".tiff"}
PDF_EXTS = {".pdf"}


def _load_any(path, work_dir):
    """Return a path to a real raster image for `path`. PDFs -> first page PNG."""
    ext = os.path.splitext(path)[1].lower()
    if ext in IMG_EXTS:
        return path
    if ext in PDF_EXTS:
        import pypdfium2 as pdfium
        pdf = pdfium.PdfDocument(path)
        page = pdf[0]
        # Render the first page so its long side is ~2200px (enough detail for
        # OCR; the pipeline caps at MAX_DIM=1600 anyway). Fixed-DPI rendering
        # blows up on these large-page WhatsApp "scan" PDFs.
        w_pt, h_pt = page.get_size()
        scale = 2200 / max(w_pt, h_pt)
        pil = page.render(scale=scale).to_pil()
        out = os.path.join(work_dir, os.path.splitext(os.path.basename(path))[0] + ".png")
        pil.save(out)
        return out
    raise ValueError(f"Unsupported file type: {path}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", default="eval_images", help="folder of label images / PDFs")
    ap.add_argument("--out", default="eval_out", help="output folder")
    ap.add_argument("--no-llm", action="store_true", help="disable LLM correction + VLM escalation")
    ap.add_argument("--score", action="store_true", help="score against <out>/ground_truth.json")
    args = ap.parse_args()

    in_dir = os.path.abspath(args.dir)
    out_dir = os.path.abspath(args.out)
    os.makedirs(out_dir, exist_ok=True)
    rendered_dir = os.path.join(out_dir, "_rendered")
    os.makedirs(rendered_dir, exist_ok=True)

    files = sorted(
        os.path.join(in_dir, f) for f in os.listdir(in_dir)
        if os.path.splitext(f)[1].lower() in (IMG_EXTS | PDF_EXTS)
    ) if os.path.isdir(in_dir) else []

    if not files:
        print(f"No images or PDFs found in {in_dir}")
        print("Drop your label photos there (jpg/png/pdf) and re-run.")
        sys.exit(1)

    has_key = bool(os.environ.get("GROQ_API_KEY"))
    use_llm = has_key and not args.no_llm
    print(f"{len(files)} file(s) in {in_dir}")
    print(f"GROQ_API_KEY {'set' if has_key else 'NOT set'}  ->  "
          f"LLM correction + VLM escalation: {'ON' if use_llm else 'OFF'}")
    print("-" * 70)

    req = [k for k, v in RULES_CONFIG.items() if v["required"]]
    all_keys = list(RULES_CONFIG.keys())
    rows, gt_template = [], {}

    for path in files:
        name = os.path.basename(path)
        try:
            img_path = _load_any(path, rendered_dir)
            result = run_pipeline(img_path, use_llm_correction=use_llm,
                                  use_llm_agent=use_llm, capture_mode="upload")
        except Exception:
            print(f"[{name}] ERROR")
            traceback.print_exc()
            rows.append({"image": name, "verdict": "ERROR"})
            continue

        qm = result["quality_metrics"]
        row = {
            "image": name,
            "quality_passed": result["quality_passed"],
            "verdict": result["verdict"],
            "clarity_pct": qm.get("clarity_pct"),
            "exposure_pct": qm.get("exposure_pct"),
            "exposure_label": qm.get("exposure_label"),
            "wxh": f"{qm.get('width')}x{qm.get('height')}",
            "n_violations": len(result.get("violations", [])),
            "ocr_source": result.get("ocr_source"),
        }
        for k in all_keys:
            f = result.get("fields", {}).get(k, {})
            row[f"{k}__value"] = f.get("value")
            row[f"{k}__level"] = f.get("level")
            row[f"{k}__conf"] = f.get("confidence")
        rows.append(row)

        gt_template[name] = {k: "" for k in all_keys}

        # per-image dump
        lines = [
            f"IMAGE: {name}",
            f"source file: {path}",
            f"run: {datetime.now().isoformat(timespec='seconds')}   llm={'on' if use_llm else 'off'}",
            "",
            f"quality_passed : {result['quality_passed']}",
            f"clarity        : {qm.get('clarity_pct')}%",
            f"exposure       : {qm.get('exposure_pct')}%  ({qm.get('exposure_label')})",
            f"size           : {qm.get('width')}x{qm.get('height')}",
            f"quality_reasons: {result.get('quality_reasons')}",
            "",
            f"VERDICT        : {result['verdict']}",
            f"ocr_source     : {result.get('ocr_source')}",
            "",
            "FIELDS",
        ]
        for k in all_keys:
            f = result.get("fields", {}).get(k, {})
            star = "*" if RULES_CONFIG[k]["required"] else " "
            lines.append(
                f"  {star} {k:<18} [{str(f.get('level')):<7} conf={f.get('confidence')}]  "
                f"{str(f.get('value'))[:80]}"
            )
        lines += ["", "VIOLATIONS"]
        lines += [f"  - {v}" for v in result.get("violations", [])] or ["  (none)"]
        lines += ["", "FONT WARNINGS"]
        lines += [f"  - {w}" for w in result.get("font_warnings", [])] or ["  (none)"]
        lines += ["", "RAW OCR TEXT", "-" * 40, result.get("raw_text") or "(empty)"]
        with open(os.path.join(out_dir, name + ".txt"), "w", encoding="utf-8") as fh:
            fh.write("\n".join(lines))

        miss = [k for k in req
                if (result.get("fields", {}).get(k, {}).get("value") in (None, ""))]
        print(f"[{name}]  {result['verdict']:<9} clarity={qm.get('clarity_pct')}% "
              f"exp={qm.get('exposure_pct')}% missing_required={miss}")

    df = pd.DataFrame(rows)
    csv_path = os.path.join(out_dir, "summary.csv")
    df.to_csv(csv_path, index=False)
    print("-" * 70)
    print("wrote", csv_path)
    print("wrote", os.path.join(out_dir, "<image>.txt"), "for each image")

    gt_path = os.path.join(out_dir, "ground_truth.json")
    if not os.path.exists(gt_path):
        with open(gt_path, "w", encoding="utf-8") as fh:
            json.dump(gt_template, fh, indent=2, ensure_ascii=False)
        print("wrote", gt_path, "-- fill in the correct values, then re-run")

    if os.path.exists(gt_path):
        print("\n" + "=" * 62)
        print("FIELD-LEVEL SCORING vs ground_truth.json")
        print("=" * 62)
        res = scoring.score(scoring.read_predictions(csv_path), gt_path)
        with open(os.path.join(out_dir, "score.json"), "w", encoding="utf-8") as fh:
            json.dump(res, fh, indent=2)


if __name__ == "__main__":
    main()
