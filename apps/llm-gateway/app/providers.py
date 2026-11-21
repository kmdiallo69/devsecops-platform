"""LLM backends behind one interface.

OpenAICompatibleProvider speaks the /v1/chat/completions API, which vLLM,
Ollama and Azure AI Foundry all expose — swapping the inference platform is
a configuration change, not a code change.
"""

from collections.abc import Callable

import httpx

from .config import Settings


class ProviderError(Exception):
    """Upstream model failure. The message stays internal (logs only)."""


class MockProvider:
    """Deterministic, offline. Used by tests and CI: no model, no API key."""

    def __init__(self, settings: Settings):
        self.model = settings.model

    async def ready(self) -> bool:
        return True

    async def chat(self, messages: list[dict], max_tokens: int) -> str:
        last_user = next(m["content"] for m in reversed(messages) if m["role"] == "user")
        return f"[mock] You said: {last_user[:200]}"

    async def aclose(self) -> None:
        pass


class _BearerFromSource(httpx.Auth):
    """Adds the API key at REQUEST time, read from its source each time —
    never stored as a default header, so a rotated key is used on the very
    next call."""

    def __init__(self, source: Callable[[], str]):
        self._source = source

    def auth_flow(self, request):
        key = self._source()
        if key:
            request.headers["Authorization"] = f"Bearer {key}"
        yield request


class OpenAICompatibleProvider:
    def __init__(self, settings: Settings, transport: httpx.AsyncBaseTransport | None = None):
        self.model = settings.model
        self._key = settings.api_key_source()
        self._key_required = settings.key_required
        # Explicit timeout: without one, a hung model server would hold the
        # request (and a worker) open forever.
        self._client = httpx.AsyncClient(
            base_url=settings.base_url,
            auth=_BearerFromSource(self._key),
            timeout=settings.timeout_seconds,
            transport=transport,
        )

    async def ready(self) -> bool:
        # A configured but missing/empty key = not ready: the pod receives no
        # traffic it would answer with upstream 401s.
        if self._key_required and not self._key():
            return False
        try:
            r = await self._client.get("/models", timeout=3)
            return r.status_code == 200
        except httpx.HTTPError:
            return False

    async def chat(self, messages: list[dict], max_tokens: int) -> str:
        try:
            r = await self._client.post(
                "/chat/completions",
                json={"model": self.model, "messages": messages, "max_tokens": max_tokens},
            )
            r.raise_for_status()
            return r.json()["choices"][0]["message"]["content"]
        except (httpx.HTTPError, KeyError, IndexError, ValueError) as exc:
            raise ProviderError(f"upstream LLM call failed: {exc!r}") from exc

    async def aclose(self) -> None:
        await self._client.aclose()


def build_provider(settings: Settings):
    if settings.provider == "mock":
        return MockProvider(settings)
    if settings.provider == "openai":
        return OpenAICompatibleProvider(settings)
    raise ValueError(f"unknown LLM_PROVIDER: {settings.provider!r}")
