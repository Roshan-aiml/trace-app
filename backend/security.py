"""Password hashing (PBKDF2-SHA256, stdlib) and a self-contained HS256 JWT.

No third-party crypto dependency on purpose -- the algorithms here are small,
well understood, and one less thing that can fail to `pip install` on a demo
machine.
"""
import base64
import hashlib
import hmac
import json
import os
import time

from .config import JWT_SECRET, JWT_EXPIRE_HOURS

_PBKDF2_ITERS = 200_000


def hash_password(password: str) -> str:
    salt = os.urandom(16)
    dk = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, _PBKDF2_ITERS)
    return "pbkdf2_sha256${}${}${}".format(
        _PBKDF2_ITERS,
        base64.b64encode(salt).decode(),
        base64.b64encode(dk).decode(),
    )


def verify_password(password: str, stored: str) -> bool:
    try:
        _algo, iters, b64salt, b64dk = stored.split("$")
        salt = base64.b64decode(b64salt)
        expected = base64.b64decode(b64dk)
        dk = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, int(iters))
        return hmac.compare_digest(dk, expected)
    except Exception:
        return False


def _b64u(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def _b64u_dec(seg: str) -> bytes:
    return base64.urlsafe_b64decode(seg + "=" * (-len(seg) % 4))


def create_token(user_id: int, email: str, role: str) -> str:
    now = int(time.time())
    header = _b64u(json.dumps({"alg": "HS256", "typ": "JWT"}, separators=(",", ":")).encode())
    payload = _b64u(json.dumps({
        "sub": str(user_id), "email": email, "role": role,
        "iat": now, "exp": now + JWT_EXPIRE_HOURS * 3600,
    }, separators=(",", ":")).encode())
    signing_input = f"{header}.{payload}"
    sig = hmac.new(JWT_SECRET.encode(), signing_input.encode(), hashlib.sha256).digest()
    return f"{signing_input}.{_b64u(sig)}"


def decode_token(token: str) -> dict:
    try:
        header_b64, payload_b64, sig_b64 = token.split(".")
    except ValueError:
        raise ValueError("malformed token")
    signing_input = f"{header_b64}.{payload_b64}"
    expected = hmac.new(JWT_SECRET.encode(), signing_input.encode(), hashlib.sha256).digest()
    if not hmac.compare_digest(_b64u_dec(sig_b64), expected):
        raise ValueError("bad signature")
    payload = json.loads(_b64u_dec(payload_b64))
    if int(payload.get("exp", 0)) < int(time.time()):
        raise ValueError("token expired")
    return payload
