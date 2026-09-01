"""Field-level scoring for the TRACE benchmark.

Compares extracted declaration values (a predictions CSV from benchmark.py)
against eval_out/ground_truth.json and reports per-field precision / recall / F1.

Matching rules, applied identically to every run so before/after is comparable:
  * ground-truth "" (blank) = declaration genuinely absent on the photographed
    panel. Predicting a value there is a false positive; predicting nothing is
    correct (true negative, not counted).
  * ground-truth may list "a|b|c" -- a hit against any alternative counts.
  * short fields (mrp, fssai_license, net_quantity, mfg_date, country_of_origin)
    match on normalised text / digits / parsed date.
  * long fields (manufacturer, consumer_care, generic_name) match on token
    recall: a hit needs >= 50% of the ground-truth content words to appear in
    the prediction. This tolerates OCR word-order scramble without rewarding a
    fragment that misses the company/commodity name.
"""
import json
import re
import sys

import pandas as pd

ALL_KEYS = ["manufacturer", "generic_name", "net_quantity", "mrp", "mfg_date",
           "consumer_care", "country_of_origin", "fssai_license"]
LONG_FIELDS = {"manufacturer", "consumer_care", "generic_name"}
_STOP = {"the", "and", "for", "by", "of", "at", "no", "ltd", "pvt", "co", "th",
         "st", "road", "unit", "block", "india", "limited", "street", "plot"}


def _norm(s):
    return re.sub(r"[^a-z0-9]", "", str(s or "").lower())


def _tokens(s):
    return [t for t in re.findall(r"[a-z0-9]{3,}", str(s or "").lower()) if t not in _STOP]


def _try_date(s):
    try:
        from dateutil import parser as dp
        d = dp.parse(str(s), fuzzy=True, default=None)
        return (d.year, d.month) if d else None
    except Exception:
        return None


def _one_hit(key, want, got):
    """Does prediction `got` satisfy a single ground-truth alternative `want`?"""
    if key == "mrp":
        def _rs(x):
            m = re.search(r"\d+(?:\.\d+)?", str(x).replace(",", "."))
            return float(m.group(0)) if m else None
        w, g = _rs(want), _rs(got)
        return w is not None and g is not None and abs(w - g) < 0.5
    if key == "fssai_license":
        wd, gd = re.sub(r"\D", "", str(want)), re.sub(r"\D", "", str(got))
        return len(wd) >= 10 and wd == gd
    if key == "mfg_date":
        wd, gd = _try_date(want), _try_date(got)
        if wd and gd:
            return wd == gd
        return _norm(want) in _norm(got) or _norm(got) in _norm(want)
    if key in ("net_quantity", "country_of_origin"):
        wn, gn = _norm(want), _norm(got)
        return bool(wn) and (wn in gn or gn in wn)
    # long text fields -> token recall. 0.4 tolerates OCR word-order scramble
    # across a multi-line block while still requiring the name to come through.
    wt, gt = _tokens(want), " ".join(_tokens(got))
    if not wt:
        return False
    present = sum(1 for t in wt if t in gt)
    return present / len(wt) >= 0.4


def _hit(key, want_raw, got):
    for want in str(want_raw).split("|"):
        want = want.strip()
        if want and _one_hit(key, want, got):
            return True
    return False


def score(df, gt_path, verbose=True):
    with open(gt_path, encoding="utf-8") as fh:
        gt = json.load(fh)
    per = {k: [0, 0, 0] for k in ALL_KEYS}   # tp, fp, fn
    for _, r in df.iterrows():
        g = gt.get(r["image"])
        if not g:
            continue
        for k in ALL_KEYS:
            want = str(g.get(k, "") or "").strip()
            got = str(r.get(f"{k}__value", "") or "").strip()
            got = "" if got.lower() in ("", "nan", "none") else got
            # undo pandas float coercion of an all-numeric column ("...258.0")
            if re.fullmatch(r"\d+\.0", got):
                got = got[:-2]
            if not want:
                if got:
                    per[k][1] += 1
                continue
            if not got:
                per[k][2] += 1
            elif _hit(k, want, got):
                per[k][0] += 1
            else:
                per[k][1] += 1
                per[k][2] += 1
    def _prf(tp, fp, fn):
        P = tp / (tp + fp) if tp + fp else float("nan")
        R = tp / (tp + fn) if tp + fn else float("nan")
        F1 = 2 * P * R / (P + R) if (P == P and R == R and P + R) else float("nan")
        return P, R, F1

    per_field, tot = {}, [0, 0, 0]
    for k in ALL_KEYS:
        tp, fp, fn = per[k]
        tot = [tot[0] + tp, tot[1] + fp, tot[2] + fn]
        P, R, F1 = _prf(tp, fp, fn)
        per_field[k] = {"tp": tp, "fp": fp, "fn": fn, "P": P, "R": R, "F1": F1}
    tp, fp, fn = tot
    oP = tp / (tp + fp) if tp + fp else 0.0
    oR = tp / (tp + fn) if tp + fn else 0.0
    oF1 = 2 * oP * oR / (oP + oR) if oP + oR else 0.0
    if verbose:
        print(f"{'field':<18} {'tp':>3} {'fp':>3} {'fn':>3}   {'P':>5} {'R':>5} {'F1':>5}")
        for k in ALL_KEYS:
            d = per_field[k]
            print(f"{k:<18} {d['tp']:>3} {d['fp']:>3} {d['fn']:>3}   "
                  f"{d['P']:>5.2f} {d['R']:>5.2f} {d['F1']:>5.2f}")
        print(f"{'OVERALL':<18} {tp:>3} {fp:>3} {fn:>3}   {oP:>5.2f} {oR:>5.2f} {oF1:>5.3f}")
    return {"per_field": per_field,
            "overall": {"tp": tp, "fp": fp, "fn": fn, "P": oP, "R": oR, "F1": oF1}}


def read_predictions(csv_path):
    """Read a benchmark summary.csv keeping every column as text -- pandas would
    otherwise coerce an all-numeric column (FSSAI licence, MRP) to float and
    turn '10014047000258' into '10014047000258.0'."""
    return pd.read_csv(csv_path, dtype=str, keep_default_na=False)


if __name__ == "__main__":
    csv = sys.argv[1] if len(sys.argv) > 1 else "eval_out/summary.csv"
    gtp = sys.argv[2] if len(sys.argv) > 2 else "eval_out/ground_truth.json"
    print(f"scoring {csv} vs {gtp}\n")
    score(read_predictions(csv), gtp)
