"""The API key: read from a file, rotated without restart, never leaked."""

import asyncio
import os

import httpx

from app.config import Settings
from app.providers import OpenAICompatibleProvider
from app.secrets import FileSecret


def _write(path, value, bump_ns=0):
    path.write_text(value)
    if bump_ns:  # make the rotation visible even within the same mtime tick
        st = os.stat(path)
        os.utime(path, ns=(st.st_atime_ns, st.st_mtime_ns + bump_ns))


def _settings(**env):
    return Settings(**{"provider": "openai", "base_url": "http://llm.invalid/v1", **env})


def test_file_secret_strips_trailing_newline(tmp_path):
    f = tmp_path / "key"
    _write(f, "s3cret\n")
    assert FileSecret(str(f)).get() == "s3cret"


def test_file_secret_picks_up_rotation(tmp_path):
    f = tmp_path / "key"
    _write(f, "old-key")
    secret = FileSecret(str(f))
    assert secret.get() == "old-key"
    _write(f, "new-key", bump_ns=1_000_000)
    assert secret.get() == "new-key"


def test_missing_file_is_empty_not_crash(tmp_path):
    assert FileSecret(str(tmp_path / "absent")).get() == ""


def test_repr_never_contains_the_value(tmp_path):
    f = tmp_path / "key"
    _write(f, "s3cret")
    secret = FileSecret(str(f))
    secret.get()
    assert "s3cret" not in repr(secret)
    assert "s3cret" not in repr(_settings(api_key="s3cret"))


def test_file_takes_precedence_over_env(tmp_path):
    f = tmp_path / "key"
    _write(f, "from-file")
    s = _settings(api_key_file=str(f), api_key="from-env")
    assert s.api_key_source()() == "from-file"


def test_key_sent_per_request_and_rotation_applies_without_restart(tmp_path):
    f = tmp_path / "key"
    _write(f, "key-v1")
    seen = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(request.headers.get("authorization"))
        return httpx.Response(200, json={"choices": [{"message": {"content": "ok"}}]})

    provider = OpenAICompatibleProvider(
        _settings(api_key_file=str(f)), transport=httpx.MockTransport(handler)
    )

    async def two_calls():
        await provider.chat([{"role": "user", "content": "hi"}], 16)
        _write(f, "key-v2", bump_ns=1_000_000)
        await provider.chat([{"role": "user", "content": "hi"}], 16)
        await provider.aclose()

    asyncio.run(two_calls())
    assert seen == ["Bearer key-v1", "Bearer key-v2"]


def test_not_ready_when_configured_key_is_missing(tmp_path):
    calls = []

    def handler(request):
        calls.append(request)
        return httpx.Response(200)

    provider = OpenAICompatibleProvider(
        _settings(api_key_file=str(tmp_path / "absent")), transport=httpx.MockTransport(handler)
    )
    assert asyncio.run(provider.ready()) is False
    assert calls == []  # decided locally: no call made upstream without a key
    asyncio.run(provider.aclose())
