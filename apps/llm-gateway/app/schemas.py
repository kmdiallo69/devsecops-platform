"""Request/response contracts — input validation is the first security control.

Every limit here is enforced by Pydantic BEFORE any code (or any model) sees
the request; a violation returns 422 and costs nothing.
"""

from typing import Literal

from pydantic import BaseModel, Field

MAX_MESSAGE_CHARS = 4000
MAX_MESSAGES = 20


class Message(BaseModel):
    # No "system" role: a caller who could send a system message could
    # override the server's instructions — the most direct form of prompt
    # injection (OWASP LLM01). The system prompt is added server-side only.
    role: Literal["user", "assistant"]
    content: str = Field(min_length=1, max_length=MAX_MESSAGE_CHARS)


class ChatRequest(BaseModel):
    # Bounded conversation length and output size: caps cost per request and
    # blunts resource-exhaustion abuse (OWASP LLM10 — Unbounded Consumption).
    messages: list[Message] = Field(min_length=1, max_length=MAX_MESSAGES)
    max_tokens: int = Field(default=256, ge=1, le=1024)


class ChatResponse(BaseModel):
    reply: str
    model: str
