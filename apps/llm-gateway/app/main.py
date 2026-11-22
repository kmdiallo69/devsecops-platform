"""LLM gateway — the single, controlled path between users and a model.

Request path: rate limit -> schema validation -> injection check -> input
redaction -> model -> canary check -> output redaction + markup stripping.
Guardrail decisions are logged as structured events (type and counts,
never the text). See guardrails.py for the OWASP LLM Top 10 mapping.
"""

import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException, Request, Response

from . import guardrails
from .config import get_settings
from .providers import ProviderError, build_provider
from .schemas import ChatRequest, ChatResponse

logger = logging.getLogger("llm-gateway")
audit = logging.getLogger("llm-gateway.audit")

WITHHELD = "The response was withheld by the content policy."


@asynccontextmanager
async def lifespan(app: FastAPI):
    settings = get_settings()
    app.state.settings = settings
    app.state.provider = build_provider(settings)
    app.state.limiter = guardrails.RateLimiter(settings.rate_limit_per_minute)
    app.state.canary = guardrails.new_canary()
    # Logs the provider and model, never the API key (repr=False in Settings)
    logger.info("starting with provider=%s model=%s", settings.provider, settings.model)
    yield
    await app.state.provider.aclose()


_settings = get_settings()
app = FastAPI(
    title="LLM Gateway",
    lifespan=lifespan,
    docs_url="/docs" if _settings.enable_docs else None,
    redoc_url=None,
    openapi_url="/openapi.json" if _settings.enable_docs else None,
)


def _client_id(request: Request) -> str:
    if app.state.settings.trust_forwarded_for:
        xff = request.headers.get("x-forwarded-for", "")
        if xff:
            return xff.split(",")[-1].strip()
    return request.client.host if request.client else "unknown"


@app.get("/healthz")
async def healthz():
    """Liveness: the process is up. Never depends on the model."""
    return {"status": "ok"}


@app.get("/readyz")
async def readyz(response: Response):
    """Readiness: can serve traffic now (model backend reachable)."""
    if await app.state.provider.ready():
        return {"status": "ready"}
    response.status_code = 503
    return {"status": "not ready"}


@app.post("/v1/chat", response_model=ChatResponse)
async def chat(req: ChatRequest, request: Request):
    settings = app.state.settings
    client = _client_id(request)

    # LLM10: rate limit before any work is done for the caller.
    retry_after = app.state.limiter.check(client)
    if retry_after:
        audit.warning("guardrail=rate_limit client=%s", client)
        raise HTTPException(
            status_code=429,
            detail="rate limit exceeded",
            headers={"Retry-After": str(int(retry_after) + 1)},
        )

    # LLM01: known injection phrasings are refused, not forwarded.
    for m in req.messages:
        if m.role == "user" and (pattern := guardrails.detect_injection(m.content)):
            audit.warning("guardrail=prompt_injection pattern=%s client=%s", pattern, client)
            raise HTTPException(status_code=400, detail="request blocked by content policy")

    # LLM02: sensitive values never reach the model provider.
    redacted_in: dict[str, int] = {}
    history = []
    for m in req.messages:
        content, counts = guardrails.redact(m.content)
        for k, v in counts.items():
            redacted_in[k] = redacted_in.get(k, 0) + v
        history.append({"role": m.role, "content": content})
    if redacted_in:
        audit.info("guardrail=redact_input types=%s client=%s", redacted_in, client)

    # LLM07: the canary rides along with the server-owned system prompt.
    system = f"{settings.system_prompt}\n[{app.state.canary}]"
    messages = [{"role": "system", "content": system}, *history]

    try:
        reply = await app.state.provider.chat(messages, req.max_tokens)
    except ProviderError:
        # Full detail goes to the logs; the caller gets a generic message —
        # upstream errors can leak internal URLs, model names or keys.
        logger.exception("LLM provider error")
        raise HTTPException(status_code=502, detail="upstream model error")

    # LLM07: a reply carrying the canary is leaking the system prompt.
    if app.state.canary in reply:
        audit.warning("guardrail=system_prompt_leak client=%s", client)
        return ChatResponse(reply=WITHHELD, model=app.state.provider.model, filtered=True)

    # LLM02 + LLM05: model output is untrusted data, filtered like input.
    reply, redacted_out = guardrails.redact(reply)
    reply, stripped = guardrails.strip_exfil_markdown(reply)
    if redacted_out or stripped:
        audit.info("guardrail=filter_output types=%s markup=%d client=%s", redacted_out, stripped, client)

    return ChatResponse(
        reply=reply,
        model=app.state.provider.model,
        filtered=bool(redacted_in or redacted_out or stripped),
    )
