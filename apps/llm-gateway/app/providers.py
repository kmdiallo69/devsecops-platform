"""LLM backends behind one interface.

OpenAICompatibleProvider speaks the /v1/chat/completions API, which vLLM,
Ollama and Azure AI Foundry all expose — swapping the inference platform is
a configuration change, not a code change.
"""

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


class OpenAICompatibleProvider:
    def __init__(self, settings: Settings):
        self.model = settings.model
        headers = {"Authorization": f"Bearer {settings.api_key}"} if settings.api_key else {}
        # Explicit timeout: without one, a hung model server would hold the
        # request (and a worker) open forever.
        self._client = httpx.AsyncClient(
            base_url=settings.base_url, headers=headers, timeout=settings.timeout_seconds
        )

    async def ready(self) -> bool:
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
