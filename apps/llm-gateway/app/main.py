"""LLM gateway — the single, controlled path between users and a model.

Step 1: input validation, server-owned system prompt, no error leakage.
Step 10 adds guardrails (prompt-injection detection, output filtering, PII
redaction, rate limiting) mapped to the OWASP LLM Top 10.
"""

import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException, Response

from .config import get_settings
from .providers import ProviderError, build_provider
from .schemas import ChatRequest, ChatResponse

logger = logging.getLogger("llm-gateway")


@asynccontextmanager
async def lifespan(app: FastAPI):
    settings = get_settings()
    app.state.settings = settings
    app.state.provider = build_provider(settings)
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
async def chat(req: ChatRequest):
    settings = app.state.settings
    messages = [{"role": "system", "content": settings.system_prompt}]
    messages += [m.model_dump() for m in req.messages]

    try:
        reply = await app.state.provider.chat(messages, req.max_tokens)
    except ProviderError:
        # Full detail goes to the logs; the caller gets a generic message —
        # upstream errors can leak internal URLs, model names or keys.
        logger.exception("LLM provider error")
        raise HTTPException(status_code=502, detail="upstream model error")

    return ChatResponse(reply=reply, model=app.state.provider.model)
