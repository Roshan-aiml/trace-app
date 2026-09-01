"""TRACE ML pipeline -- PaddleOCR + qwen/qwen3.6-27b (Groq). Consolidated module.

Extracted from the `%%writefile trace_pipeline.py` cell of the source notebook and
adapted to run as a standalone local module:
  * HUB_DATASET_ENDPOINT is pinned before PaddleOCR ever imports (works around the
    modelscope `replace() argument 2 must be str, not None` crash on import).
  * output paths point next to this module instead of an absolute /content path.
  * quality-gate thresholds + regex field-extraction hardened against a set of
    real Indian retail labels (see README).

2026-08-30 -- second tuning pass against the phone-photo set in eval_images/real/
(14 hand-verified real labels, scored in eval_out/real/):
  * generic_name: strict 2-4-word ASCII fallback + a bigger commodity vocab;
    a blank (-> REVIEW / VLM) now beats a confident wrong guess.
  * net_quantity / consumer_care: cue-anchored *proximity* fallbacks for when OCR
    reading order splits "Net Quantity :" or a care email from its cue.
  * mfg_date: a date sitting right after "Use By / Best Before" is skipped.
  * mrp: the price may be on the line directly under "MRP (incl. of all taxes)".
  * qwen3 reasoning: _groq_chat() forces reasoning_format="hidden" and
    _strip_think() removes any <think> block that still leaks.
"""
import os, re, io, base64, json as _json
from datetime import datetime

# Must be set before paddleocr (and its modelscope dependency) is imported anywhere.
os.environ.setdefault("HUB_DATASET_ENDPOINT", "https://modelscope.cn/api/v1/datasets")

import cv2
import numpy as np
import pandas as pd
from PIL import Image
from dateutil import parser as dateparser
from reportlab.lib.pagesizes import A4
from reportlab.lib.units import mm
from reportlab.pdfgen import canvas as pdfcanvas

_BASE_DIR = os.path.dirname(os.path.abspath(__file__))

HISTORY_CSV = os.path.join(_BASE_DIR, "trace_history.csv")
CONFIDENCE_THRESHOLD = 0.55
VERDICT_ORDER = {"PASS": 0, "REVIEW": 1, "HOLD": 2}
MAX_DIM = 1600
# When at least this many *required* declarations cannot be read from a photo,
# the label (or the photo of it) is treated as unusable -> HOLD. Below this,
# an unread required field is routed to human REVIEW instead of auto-HOLD: a
# missed OCR line is an extraction limitation, not proof the declaration is
# absent, and should not by itself block an otherwise-fine label.
REQUIRED_UNREADABLE_HOLD = 4

QUALITY_THRESHOLDS = {
    "blur_var_min": 100.0, "blur_var_target": 300.0,
    "brightness_min": 45, "brightness_max": 245,
    "brightness_ideal_min": 90, "brightness_ideal_max": 215,
    "min_dimension_px": 500,
    # Fraction of near-clipped (>250) pixels that counts as content-destroying
    # glare. Indian retail labels are routinely printed on white pouches / foil
    # / large white declaration stickers, so a low bar here rejects perfectly
    # readable photos -- only flag when over half the frame is blown out.
    "glare_ratio_max": 0.55,
}

# A date token as printed on Indian labels: dd/mm/yyyy, dd/MON/yyyy, MON/yy,
# "MON 2026", mm/yyyy. The month-word branch requires a real 3-letter month so
# it doesn't latch onto nutrition rows like "Per 100" or "Energy 140".
_MON = r"jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec"
DATE_TOKEN = (
    r"\d{1,2}[\/\-. ](?:" + _MON + r")[a-z]*[\/\-. ]\d{2,4}"     # 28/MAR/2026
    r"|\d{1,2}[\/\-.]\d{1,2}[\/\-.]\d{2,4}"                       # 16/07/2026
    r"|(?:" + _MON + r")[a-z]*[\/\-. ]\d{2,4}"                    # JUN/26, MAY 2026
    r"|\d{1,2}[\/\-](?:" + _MON + r")[a-z]*[\/\-]?\d{0,4}"        # 28-MAR / 28-MAR-26
    r"|\d{2}[\/\-]\d{4}"                                          # 07/2026
)

RULES_CONFIG = {
    "manufacturer": {"label": "Name & address of manufacturer/packer/importer", "required": True,
        "pattern": r"(?:Manufactured|Marketed|Mkt(?:d|\.)?|Packed|Mfd|Mfg\.?\s*by|Imported)\s*(?:&\s*(?:Packed|Marketed)\s*)?(?:by|and\s*packed\s*by|for)\s*[:\-]?\s*",
        "multiline": True, "min_len": 10},
    "generic_name": {"label": "Common / generic name of the commodity", "required": True, "pattern": None, "min_len": 2},
    "net_quantity": {"label": "Net quantity (standard unit)", "required": True,
        "pattern": r"Net\s*(?:Wt\.?|Weight|Qty\.?|Quantity|Vol\.?|Volume|Contents?|Pack)?\s*[:\-]?\s*([\d]+(?:\.\d+)?)\s*(g|gm|gms|gram|grams|kg|kgs|ml|millilitre|millilitres|l|ltr|litre|litres|pcs|piece|pieces|nos|n)\b",
        "valid_units": {"g","gm","gms","gram","grams","kg","kgs","ml","millilitre","millilitres","l","ltr","litre","litres","pcs","piece","pieces","nos","n"},
        # OCR frequently splits "NET QUANTITY :" from its value onto separate
        # lines / far-apart boxes -- look for a quantity within a window of the cue.
        "proximity_keywords": ["net quantity", "net qty", "net weight", "net wt", "net content", "net vol"],
        "proximity_value": r"([\d]+(?:\.\d+)?)\s*(g|gm|gms|gram|grams|kg|kgs|ml|millilitre|millilitres|l|ltr|litre|litres)\b"},
    "mrp": {"label": "Maximum Retail Price (inclusive of all taxes)", "required": True,
        # Same line, OR the price on the immediately following line (one \n only)
        # -- "MRP Rs. (incl. of all taxes)\n16.00". Not more, or "MRP" binds to an
        # unrelated number (USP / Rs-per-gram / a weight) further down.
        "pattern": r"M\.?\s?R\.?\s?P\.?(?:\s*/\s*[A-Z]{2,4})?[^\d\n]{0,40}?\n?[^\d\n]{0,22}?(?:Rs\.?|₹|INR)?\s*([\d]+(?:[.,]\d{1,2})?)",
        "must_have_nearby": [r"incl(?:usive|\.)?\s*(?:of)?\s*(?:all)?\s*tax", r"incl\.?\s*of\s*taxes",
                             r"inclusive\s*of\s*all\s*tax"], "nearby_window": 120},
    "mfg_date": {"label": "Month & year of manufacture / packing / import", "required": True,
        "pattern": (r"(?:Mfg|Manufacture(?:d)?|Mfd|Pkd|Packed|Packing|Packaging|Prod(?:uced|n)?|"
                    r"Date\s*of\s*(?:Mfg|Manufacture|Packing|Packaging))\.?\s*"
                    r"(?:Date|Dt\.?|on)?\s*[:\.\-]*\s*(" + DATE_TOKEN + r")"),
        # Fallback for when 'Mfg: <date>' adjacency is broken by OCR reading order.
        "proximity_keywords": ["mfd", "mfg", "manufacture", "pkd", "packed", "packing",
                               "packaging", "date of pack", "date of mfg", "prod"],
        "proximity_date": DATE_TOKEN},
    "consumer_care": {"label": "Consumer / customer care details", "required": True,
        "pattern": r"(?:Consumer\s*Care|Customer\s*Care|Care\s*of\s*Consumers?|For\s*Feedback[^\n]*Customer\s*Care)\s*[:\-]?\s*",
        "multiline": True,
        # A consumer-care declaration needs a real contact channel: a phone,
        # toll-free, or email. A bare 6-digit PIN (present in every address) is
        # NOT enough -- dropping it stops manufacturer address blocks from being
        # accepted as "consumer care".
        "must_have_one_of": [r"\b\d{10}\b", r"[\w\.-]+@[\w\.-]+\.\w+",
                             r"\b1[\s\-]?800[\s\-]?\d{3}[\s\-]?\d{3,4}\b",   # 1-800-425-2931 / 1800 102 0831
                             r"\b\d{3,5}[\s\-]\d{3}[\s\-]\d{3,4}\b",         # other dashed groupings
                             r"\+?91[\s\-]?\d{2,4}[\s\-]?\d{6,8}"]},         # +91-44-26185410
    "country_of_origin": {"label": "Country of origin (imported goods)", "required": False,
        # Literal "Country of Origin: X", or the common Indian phrasings
        # "PRODUCT / PRODUCE OF INDIA" and "MADE IN INDIA" -> value "India".
        "pattern": (r"Country\s*of\s*Origin\s*[:\-]?\s*([A-Za-z][A-Za-z .,'\-]{1,49})"
                    r"|\b(?:Product|Produce|Made)\s*(?:of|in)\s*(India)\b")},
    "fssai_license": {"label": "FSSAI license number (food products)", "required": False,
        # OCR mangles this badly ("LicTo.:1001-047000301", "fssat Lic.No 100..").
        # Grab a 14-ish digit blob that may contain stray spaces/dashes after a
        # Lic/FSSAI cue; extract_fields strips it back to 14 digits.
        "pattern": r"(?:FSSAI|F\s?S\s?S\s?A\s?I|Lic(?:ense)?)[^\d\n]{0,12}?(\d[\d \-]{11,18}\d)"},
}
REQUIRED_FIELDS = [k for k, v in RULES_CONFIG.items() if v["required"]]
# (DATE_TOKEN is defined above RULES_CONFIG)

FIELD_KEYWORDS = {
    "manufacturer": ["marketed by", "manufactured by", "mfd by", "packed by"],
    "net_quantity": ["net wt", "net weight", "net qty", "net quantity", "net vol"],
    "mrp": ["mrp", "m.r.p", "maximum retail price"],
    "mfg_date": ["mfg", "manufactured", "pkd", "packed", "packing date"],
    "consumer_care": ["consumer care", "customer care"],
    "country_of_origin": ["country of origin", "product of", "made in"],
    "fssai_license": ["fssai", "lic no", "lic.no"],
    "generic_name": [],
}

# Common-name vocabulary for the generic_name heuristic. If an OCR line contains
# one of these (and isn't a nutrition-table row) it is a far better "common /
# generic name of the commodity" than the largest-font brand line.
COMMODITY_WORDS = [
    "vermicelli", "sevai", "semiya", "semia", "noodles", "pasta", "macaroni",
    "iodised salt", "iodized salt", "salt", "sugar", "atta", "maida", "flour",
    "whole wheat", "ragi", "jowar", "bajra", "millet", "puttu podi", "puttu",
    "rice", "basmati", "dal", "pulse", "moong dal", "moong", "toor", "urad",
    "chana", "besan", "rava", "sooji", "suji", "poha",
    "pickle", "achar", "thokku", "murabba", "jam", "ketchup", "sauce", "paste",
    "masala", "garam masala", "sambar powder", "rasam powder", "curry powder",
    "powder", "chilli powder", "red chilli", "chilly powder", "kashmiri",
    "turmeric", "haldi", "coriander", "dhania", "cumin", "jeera", "pepper",
    "mustard", "rai", "sarso", "star anise", "chakri phool", "cinnamon",
    "cardamom", "clove", "fennel", "saunf", "hing", "asafoetida",
    "instant coffee", "coffee", "tea", "tea leaves", "chicory", "ice cream",
    "frozen dessert", "curd", "dahi", "yoghurt", "yogurt", "paneer", "butter",
    "ghee", "cheese", "milk", "biscuit", "cookies", "namkeen", "snack", "chips",
    "potato chips", "wafers", "chocolate", "candy", "confectionery", "lollipop",
    "oil", "refined oil", "sunflower oil", "groundnut oil", "mustard oil",
    "coconut oil", "vegetable oil", "olive oil", "honey", "spread", "cereal",
    "oats", "cornflakes", "vermiccelli", "carbonated water", "carbonated beverage",
    "soft drink", "aerated", "juice", "drink", "beverage", "seasoning",
]

# Marketing / boilerplate lines that must never be kept inside a manufacturer or
# consumer-care address block (they interleave with it in OCR reading order).
_MARKETING_RE = re.compile(
    r"taste\s*great|select\s*and\s*source|right\s*origins?|checked\s*for\s*pur|"
    r"provide\s*you|trust\s*daily|our\s*(?:other\s*)?range|try\s*our|carefully\s*"
    r"(?:select|graded)|farm[\s-]*fresh|premium\s*quality|hygienic(?:ally)?\s*"
    r"process|store\s*in\s*a?\s*cool|keep\s*(?:your|away)|shake\s*well|best\s*before|"
    r"recycl|save\s*the\s*(?:earth|planet)|scan\s*the\s*(?:qr|barcode)|"
    r"no\s*(?:artificial|preservativ|added)|once\s*opened|for\s*best\s*(?:taste|"
    r"results)|serve\s*(?:hot|with)|cooking\s*(?:directions|instructions)|"
    r"read\s*the\s*first|match\s*the\s*first|see\s*(?:the\s*)?address\s*panel|"
    r"^\W*p?r?oduct\W*$|inclusive\s*of\s*all\s*tax", re.I)

def _to_cv2(image):
    if isinstance(image, str):
        if not os.path.exists(image):
            raise ValueError(f"No file found at: {image}")
        if os.path.getsize(image) == 0:
            raise ValueError(f"File at {image} is 0 bytes -- likely a cloud-only placeholder.")
        img = cv2.imread(image)
        if img is None:
            try:
                pil_img = Image.open(image).convert("RGB")
                img = cv2.cvtColor(np.array(pil_img), cv2.COLOR_RGB2BGR)
            except Exception as e:
                raise ValueError(f"Could not read image at {image}: {e}")
    elif isinstance(image, Image.Image):
        img = cv2.cvtColor(np.array(image.convert("RGB")), cv2.COLOR_RGB2BGR)
    elif isinstance(image, np.ndarray):
        img = image
    else:
        raise TypeError(f"Unsupported image type: {type(image)}")
    h, w = img.shape[:2]
    if max(h, w) > MAX_DIM:
        scale = MAX_DIM / max(h, w)
        img = cv2.resize(img, None, fx=scale, fy=scale, interpolation=cv2.INTER_AREA)
    return img

def quality_gate(image, thresholds=QUALITY_THRESHOLDS):
    img = _to_cv2(image)
    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    h, w = gray.shape[:2]
    blur_var = cv2.Laplacian(gray, cv2.CV_64F).var()
    brightness = float(gray.mean())
    min_dim = min(h, w)
    overexposed_ratio = float((gray > 250).mean())
    clarity_pct = round(min(100.0, blur_var / thresholds["blur_var_target"] * 100), 1)
    if brightness < thresholds["brightness_ideal_min"]:
        exposure_pct = round((thresholds["brightness_ideal_min"] - brightness) / thresholds["brightness_ideal_min"] * 100, 1)
        exposure_label = "underexposed"
    elif brightness > thresholds["brightness_ideal_max"]:
        exposure_pct = round((brightness - thresholds["brightness_ideal_max"]) / (255 - thresholds["brightness_ideal_max"]) * 100, 1)
        exposure_label = "overexposed"
    else:
        exposure_pct, exposure_label = 0.0, "normal"
    reasons = []
    if blur_var < thresholds["blur_var_min"]:
        reasons.append(f"Too blurry -- {clarity_pct:.0f}% clarity")
    if brightness < thresholds["brightness_min"]:
        reasons.append(f"Too dark -- {exposure_pct:.0f}% underexposed")
    if brightness > thresholds["brightness_max"]:
        reasons.append(f"Too bright -- {exposure_pct:.0f}% overexposed")
    if overexposed_ratio > thresholds.get("glare_ratio_max", 0.55):
        reasons.append(f"Glare on {overexposed_ratio*100:.0f}% of the image")
    if min_dim < thresholds["min_dimension_px"]:
        reasons.append(f"Resolution too low ({w}x{h}px)")
    metrics = {"blur_var": round(blur_var, 1), "brightness": round(brightness, 1),
               "clarity_pct": clarity_pct, "exposure_pct": exposure_pct, "exposure_label": exposure_label,
               "width": w, "height": h, "overexposed_ratio": round(overexposed_ratio, 3)}
    return (len(reasons) == 0), reasons, metrics

_paddle_ocr = None
def get_paddle_ocr():
    global _paddle_ocr
    if _paddle_ocr is None:
        from paddleocr import PaddleOCR
        # enable_mkldnn=False: paddlepaddle 3.3.x CPU inference crashes inside the
        # oneDNN path with "ConvertPirAttribute2RuntimeAttribute not support
        # pir::ArrayAttribute<pir::DoubleAttribute>" on the PP-OCRv6 detector.
        # Disabling MKLDNN uses the plain CPU kernels and runs clean.
        # Doc-unwarping (UVDoc) rectifies curved pouches / crumpled foil, but on
        # CPU it costs 5+ minutes PER image -- unusable for an interactive scan
        # and it never finished an 8-image benchmark here. CLAHE (below) is the
        # cheap, effective half of that idea and is always on. Unwarping is left
        # as an opt-in for anyone running on GPU: set TRACE_UNWARP=1.
        unwarp = os.environ.get("TRACE_UNWARP", "") in ("1", "true", "True")
        _paddle_ocr = PaddleOCR(lang="en", use_doc_orientation_classify=True,
                                 use_doc_unwarping=unwarp, use_textline_orientation=True,
                                 enable_mkldnn=False)
    return _paddle_ocr

def _clahe_enhance(bgr):
    """Contrast-limited adaptive histogram equalisation, on the grayscale image,
    re-stacked to 3 channels -- lifts text out of foil glare and the shadow
    gradients on crumpled labels before OCR. Applied after the MAX_DIM resize.

    Only fires when the frame actually needs it: a washed-out / low-contrast /
    glary image (low global std-dev or many near-clipped pixels). On a normally
    exposed label it is skipped -- an unconditional CLAHE amplifies paper
    texture and JPEG noise into spurious detections, which both slows OCR down
    several-fold and hurts accuracy."""
    gray = cv2.cvtColor(bgr, cv2.COLOR_BGR2GRAY)
    blown = float((gray > 245).mean())
    if gray.std() >= 55 and blown < 0.10:
        return bgr
    clahe = cv2.createCLAHE(clipLimit=1.8, tileGridSize=(8, 8))
    return cv2.cvtColor(clahe.apply(gray), cv2.COLOR_GRAY2BGR)

def run_paddle_ocr(image):
    img = _clahe_enhance(_to_cv2(image))
    result = get_paddle_ocr().predict(img)
    if not result:
        return []
    res = result[0]
    polys = res.get("rec_polys", res.get("dt_polys", []))
    texts = res.get("rec_texts", [])
    scores = res.get("rec_scores", [])
    out = []
    for poly, text, score in zip(polys, texts, scores):
        bbox = [[float(p[0]), float(p[1])] for p in poly]
        out.append((bbox, text, float(score)))
    return out

def ocr_usable(text, min_chars=25, min_alpha_ratio=0.4):
    if not text or len(text.strip()) < min_chars:
        return False
    alpha = sum(c.isalnum() for c in text)
    return (alpha / max(len(text), 1)) >= min_alpha_ratio

def normalize_text(ocr_results):
    text = "\n".join(t for _, t, _ in ocr_results)
    text = re.sub(r"[ \t]+", " ", text)
    text = re.sub(r"\n{2,}", "\n", text)
    return text.strip()

def _image_to_b64(image, fmt="JPEG"):
    if isinstance(image, np.ndarray):
        image = Image.fromarray(cv2.cvtColor(image, cv2.COLOR_BGR2RGB))
    elif isinstance(image, str):
        image = Image.open(image).convert("RGB")
    buf = io.BytesIO()
    image.convert("RGB").save(buf, format=fmt)
    return base64.b64encode(buf.getvalue()).decode()

def _strip_think(text):
    """qwen3-family models on Groq prepend a <think>...</think> chain-of-thought
    to the message content. Passing reasoning_format='hidden' normally removes it;
    this strips any that still leaks through so it never reaches the extractor /
    a json.loads."""
    if not text:
        return text
    text = re.sub(r"<think>.*?</think>", "", text, flags=re.S | re.I)
    text = re.sub(r"<think>.*$", "", text, flags=re.S | re.I)      # dangling open tag
    return text.strip()


def _groq_chat(client, **kwargs):
    """client.chat.completions.create with reasoning_format='hidden', retried
    without it for any endpoint/model that rejects the parameter."""
    try:
        return client.chat.completions.create(reasoning_format="hidden", **kwargs)
    except Exception:
        return client.chat.completions.create(**kwargs)


def correct_ocr_text_with_llm(raw_text, model="qwen/qwen3.6-27b"):
    if not os.environ.get("GROQ_API_KEY") or not raw_text.strip():
        return raw_text
    try:
        from groq import Groq
        client = Groq()
        prompt = ("This is raw OCR output from a packaged-commodity label. Fix obvious "
            "character-level OCR mistakes (e.g. 'Rc' -> 'Rs', 'l0g' -> '10g', stray "
            "'O'/'0' confusion) using context. Do NOT invent, translate, summarise, or "
            "remove any content -- only correct clear misreadings, and keep the "
            "original line breaks. Return only the corrected text, nothing else.\n\n"
            "OCR text:\n" + raw_text)
        resp = _groq_chat(client, model=model,
                          messages=[{"role": "user", "content": prompt}], temperature=0)
        corrected = _strip_think(resp.choices[0].message.content)
        # A refusal / empty / think-only reply must not blank out the OCR text.
        return corrected if len(corrected) >= 0.5 * len(raw_text.strip()) else raw_text
    except Exception:
        return raw_text

def _ocr_conf_for_snippet(ocr_results, snippet, window=60):
    snippet_low = snippet.lower()[:window]
    for bbox, text, conf in ocr_results:
        if text and (text.lower() in snippet_low or snippet_low[:15] in text.lower()):
            return conf
    return None

_NUTRI_RE = re.compile(
    r"kcal|k\s*cal|energy|protein|carbohydrate|\bfat\b|saturated|trans\s*fat|"
    r"cholesterol|sodium|sugar|fibre|fiber|calcium|\biron\b|zinc|vitamin\s*b|"
    r"\brda\b|serv(?:e|ing)\s*size|servings?\s*per|per\s*100\s*g|%\s*rda|"
    r"nutrition|informat(?:ion|on)|trinional|ingred|approx|allergen|"
    r"daily\s*intake|added\s*sugar|not\s*more\s*than", re.I)

_OTHER_PANEL_RE = re.compile(
    r"see\s+(?:on\s+)?(?:the\s+)?(?:main|other|front|reverse|back|side|body|lid|top|bottom)\s*"
    r"(?:panel|pack|side|of\s*pack)?|see\s+(?:body|lid|pack)\b|see\s+side\s+for|"
    r"on\s+(?:the\s+)?main\s+panel|refer\s+(?:front|main|other)|as\s+per\s+main\s+panel", re.I)


def _digits_only(s):
    return re.sub(r"\D", "", s or "")


def _mrp_search_text(text):
    """Collapse dot-matrix digit spacing and doubled currency prefixes so the
    MRP regex sees 'Rs 195.00' instead of 'Rs. Rs. 1 9 5 . 0 0'."""
    t = re.sub(r"(?i)(?:rs\.?\s*){2,}", "Rs ", text)
    t = re.sub(r"(?:₹\s*){2,}", "₹ ", t)
    t = re.sub(r"(?<=\d)\s+(?=[\d.,])", "", t)
    return t


_COMPANY_RE = re.compile(
    r"\b(?:pvt|p\s*ltd|ltd|limited|llp|industries|enterprises?|company|"
    r"co\.|corporation|federation|\bmills\b)\b|"
    r"marketed\s*by|manufactured\s*by|regd\.?\s*office", re.I)


def _clean_address_block(text, start, max_lines=9, window=650, drop_marketing=True):
    """Take the lines following char offset `start` that read like a name /
    address, dropping OCR interleave from an adjacent nutrition table. Keeps
    collecting past table noise (doesn't stop at the first bad line) and stops
    once it has a company line plus a line carrying a 6-digit PIN.

    `drop_marketing` also filters brand-copy lines -- wanted for the manufacturer
    block, but for consumer_care it can shift the window onto a worse line, so
    that caller leaves it off."""
    out, have_company, have_pin = [], False, False
    for ln in text[start:start + window].splitlines():
        s = ln.strip(" .,:-\t|")
        if len(s) < 4 or _NUTRI_RE.search(s) or not re.search(r"[aeiou]", s, re.I) \
                or (drop_marketing and _MARKETING_RE.search(s)):
            continue
        letters = sum(c.isalpha() for c in s)
        digits = sum(c.isdigit() for c in s)
        if letters < 3 or digits > letters + 2:
            continue
        out.append(s)
        have_company = have_company or bool(_COMPANY_RE.search(s))
        have_pin = have_pin or bool(re.search(r"\b\d{6}\b", s))
        if len(out) >= max_lines or (have_company and have_pin and len(out) >= 3):
            break
    value = re.sub(r'["\x27]', "", ", ".join(out))
    return value[:220].strip(" ,")


_EXPIRY_CUE_RE = re.compile(r"use\s*by|best\s*before|expiry|exp\.?\b|consume\s*before|"
                            r"bb\s*(?:date|before)|valid\s*(?:up\s*to|till)", re.I)


def _proximity_date(text, rule):
    """mfg_date fallback when 'Mfg: <date>' adjacency is broken by OCR order.
    A date that sits right after a use-by / best-before cue is skipped -- that is
    the expiry date, not the manufacture date."""
    date_re = re.compile(rule["proximity_date"], re.I)
    low = text.lower()
    for kw in rule.get("proximity_keywords", []):
        for km in re.finditer(re.escape(kw), low):
            seg = text[km.end(): km.end() + 45]
            dm = date_re.search(seg)
            if dm and not _EXPIRY_CUE_RE.search(text[max(0, km.start() - 18): km.start()]):
                return dm.group(0).strip(), 0.5
    if re.search(r"mf[dg]|manufactur|packed|pkd", low) and re.search(r"best\s*before|use\s*by|expiry|exp\b", low):
        parsed = []
        for d in date_re.finditer(text):
            tok = d.group(0).strip()
            try:
                dt = dateparser.parse(tok, fuzzy=True)
            except Exception:
                continue
            if dt and 2015 <= dt.year <= 2035:
                parsed.append((dt, tok))
        if parsed:
            parsed.sort(key=lambda x: x[0])
            return parsed[0][1], 0.4
    return None


def _proximity_quantity(text, rule):
    """net_quantity fallback: a 'Net Weight / Net Quantity' cue whose value landed
    on a different OCR line. Take the first <number><unit> within ~60 chars."""
    val_re = re.compile(rule["proximity_value"], re.I)
    low = text.lower()
    best = None
    for kw in rule.get("proximity_keywords", []):
        for km in re.finditer(re.escape(kw), low):
            vm = val_re.search(text[km.end(): km.end() + 60])
            if vm:
                cand = f"{vm.group(1)} {vm.group(2).lower()}"
                # Prefer a hit that is closest to the cue.
                if best is None or vm.start() < best[1]:
                    best = (cand, vm.start())
    return (best[0], 0.55) if best else None


_CARE_EMAIL_RE = re.compile(r"[\w.\-]+@[\w.\-]+\.[a-z]{2,}", re.I)
_CARE_TOLLFREE_RE = re.compile(r"\b1[\s\-]?800[\s\-]?\d{3}[\s\-]?\d{3,4}\b|\b18\d{2}[\s\-]?\d{3}[\s\-]?\d{4}\b")
_CARE_ISH = re.compile(r"care|custom|consumer|feedback|complaint|contact|help|support|"
                       r"grievance|query|queries|hello@|cs\.|reach\s*us|write\s*to", re.I)


def _consumer_care_fallback(text):
    """Last resort when no 'Consumer Care' cue is near a contact channel: a
    toll-free number, or an email that either looks care-ish (care@, feedback@,
    hello@, cs.) or sits within ~50 chars of a care/feedback/contact word. A
    contact channel *is* the consumer-care declaration."""
    lines = text.splitlines()
    for i, ln in enumerate(lines):
        tf = _CARE_TOLLFREE_RE.search(ln)
        em = _CARE_EMAIL_RE.search(ln)
        ok_email = False
        if em:
            local = em.group(0).split("@")[0].lower()
            near = text[max(0, text.find(em.group(0)) - 50): text.find(em.group(0)) + 50]
            ok_email = bool(_CARE_ISH.search(local) or _CARE_ISH.search(near))
        if not (tf or ok_email):
            continue
        ctx = []
        if i and 3 < len(lines[i - 1].strip()) and not _NUTRI_RE.search(lines[i - 1]) \
                and not _MARKETING_RE.search(lines[i - 1]):
            ctx.append(lines[i - 1].strip(" .,:-"))
        ctx.append(ln.strip(" .,:-"))
        if i + 1 < len(lines) and _CARE_TOLLFREE_RE.search(lines[i + 1]):
            ctx.append(lines[i + 1].strip(" .,:-"))
        value = re.sub(r'["\x27]', "", ", ".join(ctx))[:200].strip(" ,")
        return value, (0.5 if tf else 0.45)
    return None


def _pick_generic_name(ocr_results):
    """Best OCR line for 'common / generic name of the commodity': a short line
    naming a commodity type, not an ingredient list or a company name."""
    cands = []
    for _, line, conf in ocr_results:
        s = re.sub(r"^\s*(?:common\s*)?(?:name|product|commodity)s?\b[\s:.\-]*", "", line, flags=re.I).strip(" .:-")
        low = s.lower()
        if len(s) < 3 or len(s) > 45 or _NUTRI_RE.search(s) or _MARKETING_RE.search(s):
            continue
        if low.startswith("ingredient") or _COMPANY_RE.search(s) or s.count(",") >= 2:
            continue
        if "%" in s or ";" in s or sum(ch.isdigit() for ch in s) > 2 \
                or re.search(r"content\s+(?:above|below|not)|incl.*tax", low):
            continue
        hit = next((w for w in COMMODITY_WORDS
                    if re.search(r"(?<![a-z])" + re.escape(w) + r"(?![a-z])", low)), None)
        if hit:
            cands.append((len(s), s, round(conf * 0.8, 2), "commodity_match"))
    if cands:
        cands.sort()
        _, s, c, st = cands[0]
        return {"value": s, "confidence": c, "snippet": s, "status": st}
    # Strict fallback: a short, clean, mostly-alpha 1-4 word phrase that reads
    # like a product name -- not a fragment of a tax line / ingredient list /
    # instruction. Deliberately conservative: a blank here routes to REVIEW (and
    # the VLM), which scores better than a confident wrong guess.
    for _, line, conf in ocr_results:
        s = line.strip(" .:-–—")
        low = s.lower()
        words = s.split()
        letters = sum(c.isalpha() for c in s)
        # 2-4 words, at least one substantial: a single non-commodity token is
        # almost always a brand or OCR garble, never the "common name".
        if not (4 < len(s) <= 34 and 2 <= len(words) <= 4):
            continue
        if max(len(w) for w in words) < 4:
            continue
        if letters / max(len(s), 1) < 0.75 or any(ch.isdigit() for ch in s):
            continue
        # ASCII words only -- OCR garble like "Éecer" / "PQNRTCICT" is not a name.
        if not re.fullmatch(r"[A-Za-z][A-Za-z '&()\-]+", s):
            continue
        if s.isupper() and len(re.sub(r"[^A-Za-z]", "", s)) < 4:
            continue
        # need a plausible vowel/consonant mix in the longest word
        lw = max(words, key=len).lower()
        if len(lw) >= 4 and (not re.search(r"[aeiou]", lw) or
                             not re.search(r"[bcdfghjklmnpqrstvwxyz]", lw)):
            continue
        if _NUTRI_RE.search(s) or _COMPANY_RE.search(s) or _MARKETING_RE.search(s):
            continue
        if re.search(r"tax|incl|content|recipe|net\s|mrp|batch|\blic\b|www|@|"
                     r"\bfor\b|direction|address|panel|origin|weight|price|code", low):
            continue
        # reject a lone generic modifier ("Powder", "Steam Made", "Mixed")
        if len(words) == 1 and low in {"powder", "mix", "mixed", "made", "special",
                                       "premium", "classic", "original", "natural"}:
            continue
        if all(w.lower() in {"powder", "mix", "mixed", "made", "steam", "special",
                             "instant", "pure", "premium", "fresh"} for w in words):
            continue
        return {"value": s, "confidence": round(conf * 0.5, 2), "snippet": s, "status": "heuristic"}
    return {"value": None, "confidence": 0.0, "snippet": None, "status": "not_found"}


def extract_fields(text, ocr_results):
    fields = {}
    for key, rule in RULES_CONFIG.items():
        pattern = rule.get("pattern")
        if not pattern:
            fields[key] = {"value": None, "confidence": 0.0, "snippet": None, "status": "skip_no_pattern"}
            continue
        search_text = _mrp_search_text(text) if key == "mrp" else text
        if key == "fssai_license":
            m = next((mm for mm in re.finditer(pattern, search_text, flags=re.IGNORECASE)
                      if len(_digits_only(mm.group(1))) == 14), None)
        elif key == "mfg_date":
            # first cue-anchored date that isn't immediately preceded by a
            # use-by / best-before cue -- that one is the expiry, not the mfg date
            # (OCR reading order often drops an expiry line between the mfg cue
            # and its date).
            m = next((mm for mm in re.finditer(pattern, search_text, flags=re.IGNORECASE)
                      if not _EXPIRY_CUE_RE.search(
                          search_text[max(0, mm.start(1) - 22): mm.start(1)])),
                     None)
        else:
            m = re.search(pattern, search_text, flags=re.IGNORECASE)
        if not m:
            if key == "mfg_date":
                prox = _proximity_date(text, rule)
                if prox:
                    fields[key] = {"value": prox[0], "confidence": prox[1],
                                   "snippet": prox[0], "status": "matched_proximity"}
                    continue
            if key == "net_quantity" and rule.get("proximity_value"):
                prox = _proximity_quantity(text, rule)
                if prox:
                    fields[key] = {"value": prox[0], "confidence": prox[1],
                                   "snippet": prox[0], "status": "matched_proximity"}
                    continue
            if key == "consumer_care":
                prox = _consumer_care_fallback(text)
                if prox:
                    fields[key] = {"value": prox[0], "confidence": prox[1],
                                   "snippet": prox[0][:60], "status": "matched_proximity"}
                    continue
            status = "not_found"
            if key == "net_quantity" and _OTHER_PANEL_RE.search(text):
                status = "other_panel"
            fields[key] = {"value": None, "confidence": 0.0, "snippet": None, "status": status}
            continue
        if key in ("manufacturer", "consumer_care"):
            value = _clean_address_block(search_text, m.end(),
                                        drop_marketing=(key == "manufacturer"))
            snippet = (m.group(0) + " " + value[:40]).strip()
        elif key == "fssai_license":
            value = _digits_only(m.group(1))[:14]
            snippet = m.group(0).strip()
        elif key == "net_quantity":
            value = f"{m.group(1)} {m.group(2)}".strip()
            snippet = m.group(0).strip()
        else:
            groups = [g for g in (m.groups() or ()) if g]
            value = (groups[0] if groups else m.group(0)).strip()
            snippet = m.group(0).strip()
        base_conf = 0.85 if key == "fssai_license" else 0.6
        ocr_conf = _ocr_conf_for_snippet(ocr_results, snippet)
        if ocr_conf is not None:
            base_conf = 0.8 * base_conf + 0.2 * ocr_conf
        if key == "mrp" and rule.get("must_have_nearby"):
            window_text = search_text[max(0, m.start() - 5): m.end() + rule["nearby_window"]].lower()
            if not any(re.search(p, window_text) for p in rule["must_have_nearby"]):
                base_conf *= 0.5
        if key == "net_quantity" and rule.get("valid_units"):
            unit = m.group(2).lower() if len(m.groups()) > 1 and m.group(2) else ""
            if unit not in rule["valid_units"]:
                base_conf *= 0.4
        if key == "consumer_care" and rule.get("must_have_one_of"):
            if not any(re.search(p, value) for p in rule["must_have_one_of"]):
                # cue matched but the block carried no phone/email/PIN -- try the
                # cue-free fallback (a bare care@brand.com / toll-free line).
                fb = _consumer_care_fallback(text)
                if fb:
                    value, snippet = fb[0], fb[0][:60]
                    base_conf = fb[1]
                else:
                    base_conf *= 0.5
        min_len = rule.get("min_len", 0)
        if min_len and len(value) < min_len:
            base_conf *= 0.5
        fields[key] = {"value": value, "confidence": round(min(base_conf, 1.0), 2),
                       "snippet": snippet, "status": "matched"}
    fields["generic_name"] = _pick_generic_name(ocr_results)
    return fields

def run_compliance_rules(fields, quality_metrics, confidence_threshold=CONFIDENCE_THRESHOLD):
    violations, ambiguous_fields = [], []
    for key, rule in RULES_CONFIG.items():
        f = fields.get(key, {"value": None, "confidence": 0.0, "status": "not_found"})
        required = rule["required"]
        if f["value"] is None:
            # "declared on another panel" is a settled HOLD, not something a VLM
            # pass over this photo can resolve -- don't escalate it.
            if required and f.get("status") != "other_panel":
                ambiguous_fields.append(key)
            continue
        if f["confidence"] < confidence_threshold:
            ambiguous_fields.append(key)
            continue
        if key == "mrp" and rule.get("must_have_nearby") and f["confidence"] < 0.4:
            violations.append(f"{rule['label']}: 'inclusive of all taxes' wording not detected near MRP")
        if key == "mfg_date":
            try:
                dateparser.parse(f["value"], fuzzy=True, default=None)
            except Exception:
                violations.append(f"{rule['label']}: '{f['value']}' is not a recognisable date")
    return violations, ambiguous_fields

def font_readability_check(ocr_results, fields):
    if len(ocr_results) < 3:
        return []
    heights = [max(p[1] for p in bbox) - min(p[1] for p in bbox) for bbox, _, _ in ocr_results]
    median_h = float(np.median(heights))
    warnings = []
    for key in ("mrp", "net_quantity"):
        snippet = (fields.get(key) or {}).get("snippet")
        if not snippet:
            continue
        for bbox, text, conf in ocr_results:
            if snippet[:10].lower() in text.lower():
                h = max(p[1] for p in bbox) - min(p[1] for p in bbox)
                if h < 0.6 * median_h:
                    warnings.append(f"{RULES_CONFIG[key]['label']} text looks smaller than the label average ({h:.0f}px vs median {median_h:.0f}px)")
                break
    return warnings

def _crop_for_field(image, ocr_results, key, pad_ratio=0.6):
    img = _to_cv2(image)
    h, w = img.shape[:2]
    keywords = FIELD_KEYWORDS.get(key, [])
    for bbox, text, conf in ocr_results:
        low = text.lower()
        if any(kw in low for kw in keywords):
            xs = [p[0] for p in bbox]; ys = [p[1] for p in bbox]
            x0, x1 = min(xs), max(xs); y0, y1 = min(ys), max(ys)
            bw, bh = x1 - x0, y1 - y0
            x0 = max(0, int(x0 - bw * pad_ratio)); x1 = min(w, int(x1 + bw * 2.5))
            y0 = max(0, int(y0 - bh * pad_ratio)); y1 = min(h, int(y1 + bh * 1.5))
            return img[y0:y1, x0:x1]
    return None

def resolve_ambiguous_field(image, ocr_results, key, model="qwen/qwen3.6-27b"):
    if not os.environ.get("GROQ_API_KEY"):
        return {"value": None, "confidence": 0.0, "found": False, "resolved": False}
    rule = RULES_CONFIG[key]
    crop = _crop_for_field(image, ocr_results, key)
    region = crop if crop is not None else _to_cv2(image)
    try:
        from groq import Groq
        client = Groq()
        b64 = _image_to_b64(region)
        prompt = (f'This is a cropped region of an Indian packaged-commodity label. '
                  f'Find the value for: "{rule["label"]}". '
                  f'Respond ONLY as JSON: {{"value": <string or null>, "confidence": <0-1 float>, "found": <true/false>}}. '
                  f'If the field genuinely is not visible in this image, set found to false.')
        resp = _groq_chat(
            client,
            model=model,
            messages=[{"role": "user", "content": [
                {"type": "text", "text": prompt},
                {"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{b64}"}},
            ]}],
            temperature=0, response_format={"type": "json_object"},
        )
        parsed = _json.loads(_strip_think(resp.choices[0].message.content))
        return {"value": parsed.get("value"), "confidence": float(parsed.get("confidence", 0.5)),
                "found": bool(parsed.get("found", False)), "resolved": True}
    except Exception:
        return {"value": None, "confidence": 0.0, "found": False, "resolved": False}

def merge_and_verdict(fields, ambiguous_fields, agent_results, violations):
    """Fold in any VLM agent results, assign a per-field level, and derive the
    overall verdict.

    Verdict semantics:
      PASS   -- every required declaration was read with adequate confidence and
                nothing failed a content check.
      REVIEW -- the label looks fine but something needs a human eye: a low
                confidence value, a content check that is borderline, or a
                required field OCR simply could not pull off this photo. A
                missed field is an extraction limitation, not proof the
                declaration is absent, so on its own it does NOT force HOLD.
      HOLD   -- positive evidence the label is non-compliant or the photo is
                unusable: a required declaration the review agent confirmed
                absent, or so many unreadable required fields
                (>= REQUIRED_UNREADABLE_HOLD) that nothing can be verified.

    Returns (overall_verdict, field_status, hard_violations, review_notes).
    `hard_violations` are content-rule failures / confirmed-missing declarations;
    `review_notes` are the softer "a human should look at this" items.
    """
    field_status = {}
    unreadable_required = []            # required fields neither OCR nor the agent could resolve
    hard_violations = list(violations)  # content-rule failures carried in from run_compliance_rules
    review_notes = []

    for key, rule in RULES_CONFIG.items():
        f = dict(fields.get(key, {}))
        required = rule["required"]

        if key in ambiguous_fields and key in agent_results:
            agent = agent_results[key]
            if agent["resolved"] and agent["found"] and agent["confidence"] >= 0.5:
                f = {"value": agent["value"], "confidence": agent["confidence"],
                     "snippet": f.get("snippet"), "status": "llm_resolved"}
            elif agent["resolved"] and not agent["found"]:
                f["status"] = "agent_absent"
            else:
                f["status"] = "needs_review"

        missing = f.get("value") in (None, "") or f.get("status") in ("not_found", "agent_absent")

        if missing:
            if not required:
                level = "PASS"
            elif fields.get(key, {}).get("status") == "other_panel":
                level = "REVIEW"
                f["status"] = "other_panel"
                review_notes.append(f"{rule['label']}: declared on another panel -- confirm on the physical pack")
            elif f.get("status") == "agent_absent":
                level = "HOLD"
                f["status"] = "agent_absent"
                hard_violations.append(f"{rule['label']}: missing (confirmed by review agent)")
            else:
                level = "REVIEW"
                f["status"] = "unverified"
                unreadable_required.append(key)
                review_notes.append(f"{rule['label']}: could not be read from this photo -- verify manually")
        elif f.get("status") == "needs_review":
            level = "REVIEW"
        elif f.get("confidence", 0) < CONFIDENCE_THRESHOLD:
            level = "REVIEW"
        else:
            level = "PASS"

        f["level"] = level
        field_status[key] = f

    overall = max((f["level"] for f in field_status.values()), key=lambda l: VERDICT_ORDER[l])

    if len(unreadable_required) >= REQUIRED_UNREADABLE_HOLD:
        overall = "HOLD"
        hard_violations.append(
            f"{len(unreadable_required)} required declarations could not be read -- retake with the "
            "whole label sharp and in frame, or hold the batch for manual inspection")
    elif hard_violations and VERDICT_ORDER[overall] < VERDICT_ORDER["REVIEW"]:
        overall = "REVIEW"

    return overall, field_status, hard_violations, review_notes

def run_pipeline(image, use_llm_correction=True, use_llm_agent=True, capture_mode="upload", quality_override=False):
    result = {"quality_passed": False, "quality_reasons": [], "quality_metrics": {},
              "verdict": None, "fields": {}, "violations": [], "review_notes": [], "font_warnings": [],
              "ocr_source": None, "raw_text": "", "capture_mode": capture_mode, "quality_overridden": False}
    passed, reasons, metrics = quality_gate(image)
    result.update(quality_passed=passed, quality_reasons=reasons, quality_metrics=metrics)
    if not passed and not quality_override:
        result["verdict"] = "REJECTED"
        return result
    if not passed and quality_override:
        result["quality_overridden"] = True
    ocr_results = run_paddle_ocr(image)
    raw_text = normalize_text(ocr_results)
    text = correct_ocr_text_with_llm(raw_text) if use_llm_correction else raw_text
    result["ocr_source"] = "paddleocr+llm" if (use_llm_correction and os.environ.get("GROQ_API_KEY")) else "paddleocr"
    result["raw_text"] = text
    fields = extract_fields(text, ocr_results)
    violations, ambiguous = run_compliance_rules(fields, metrics)
    font_warnings = font_readability_check(ocr_results, fields)
    agent_results = {}
    if use_llm_agent and ambiguous:
        for key in ambiguous:
            agent_results[key] = resolve_ambiguous_field(image, ocr_results, key)
    overall, field_status, violations, review_notes = merge_and_verdict(
        fields, ambiguous, agent_results, violations)
    result.update(verdict=overall, fields=field_status, violations=violations,
                   review_notes=review_notes, font_warnings=font_warnings,
                   ambiguous_fields=ambiguous)
    return result

def generate_pdf_report(record, image_path, out_path=None):
    if out_path is None:
        out_path = os.path.join(_BASE_DIR, "trace_report.pdf")
    c = pdfcanvas.Canvas(out_path, pagesize=A4)
    w, h = A4
    y = h - 20 * mm
    c.setFont("Helvetica-Bold", 16)
    c.drawString(20 * mm, y, "TRACE -- Compliance Inspection Report")
    y -= 8 * mm
    c.setFont("Helvetica", 10)
    c.drawString(20 * mm, y, f"Generated: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')} | Mode: {record.get('capture_mode','?')}")
    y -= 10 * mm
    try:
        c.drawImage(image_path, 20 * mm, y - 60 * mm, width=50 * mm, height=60 * mm, preserveAspectRatio=True)
    except Exception:
        pass
    verdict_color = {"PASS": (0, 0.5, 0), "REVIEW": (0.8, 0.5, 0), "HOLD": (0.7, 0, 0), "REJECTED": (0.5, 0.5, 0.5)}
    r, g, b = verdict_color.get(record["verdict"], (0, 0, 0))
    c.setFillColorRGB(r, g, b)
    c.setFont("Helvetica-Bold", 14)
    c.drawString(80 * mm, y - 10 * mm, f"VERDICT: {record['verdict']}")
    c.setFillColorRGB(0, 0, 0)
    y -= 70 * mm
    c.setFont("Helvetica-Bold", 12)
    c.drawString(20 * mm, y, "Extracted Declarations")
    y -= 7 * mm
    c.setFont("Helvetica", 9)
    for key, f in record.get("fields", {}).items():
        label = RULES_CONFIG[key]["label"]
        val = f.get("value") or "--"
        line = f"{label}: {val}  [{f.get('level','?')}, conf {f.get('confidence',0)}]"
        c.drawString(22 * mm, y, line[:110]); y -= 5.5 * mm
        if y < 30 * mm:
            c.showPage(); y = h - 20 * mm
    if record.get("violations"):
        y -= 4 * mm
        c.setFont("Helvetica-Bold", 12); c.drawString(20 * mm, y, "Violations"); y -= 7 * mm
        c.setFont("Helvetica", 9)
        for v in record["violations"]:
            c.drawString(22 * mm, y, f"- {v}"[:110]); y -= 5.5 * mm
            if y < 30 * mm:
                c.showPage(); y = h - 20 * mm
    if record.get("review_notes"):
        y -= 4 * mm
        c.setFont("Helvetica-Bold", 12); c.drawString(20 * mm, y, "Needs manual check"); y -= 7 * mm
        c.setFont("Helvetica", 9)
        for n in record["review_notes"]:
            c.drawString(22 * mm, y, f"- {n}"[:110]); y -= 5.5 * mm
            if y < 30 * mm:
                c.showPage(); y = h - 20 * mm
    c.save()
    return out_path

def log_telemetry(record, product_name="", inspector="", human_decision=""):
    row = {"timestamp": datetime.now().isoformat(timespec="seconds"),
           "product_name": product_name or record.get("fields", {}).get("generic_name", {}).get("value", ""),
           "verdict": record["verdict"], "capture_mode": record.get("capture_mode", ""),
           "quality_overridden": record.get("quality_overridden", False),
           "clarity_pct": record.get("quality_metrics", {}).get("clarity_pct"),
           "exposure_pct": record.get("quality_metrics", {}).get("exposure_pct"),
           "num_violations": len(record.get("violations", [])),
           "ocr_source": record.get("ocr_source"), "inspector": inspector, "human_decision": human_decision}
    df_new = pd.DataFrame([row])
    if os.path.exists(HISTORY_CSV):
        df_new.to_csv(HISTORY_CSV, mode="a", header=False, index=False)
    else:
        df_new.to_csv(HISTORY_CSV, index=False)
    return row
