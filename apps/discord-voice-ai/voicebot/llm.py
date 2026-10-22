"""Talks to the language model. Supports any OpenAI-compatible server and the Claude API."""

from __future__ import annotations

import os

import aiohttp


class LLMError(RuntimeError):
    pass


def merge_turns(history: list[dict]) -> list[dict]:
    """Join consecutive messages from the same role (several people can talk in a row)."""
    merged: list[dict] = []
    for msg in history:
        if merged and merged[-1]["role"] == msg["role"]:
            merged[-1] = {"role": msg["role"], "content": merged[-1]["content"] + "\n" + msg["content"]}
        else:
            merged.append(dict(msg))
    # Both APIs want the conversation to start with the user.
    while merged and merged[0]["role"] != "user":
        merged.pop(0)
    return merged


class Brain:
    def __init__(self, cfg: dict):
        self.cfg = cfg
        self._session: aiohttp.ClientSession | None = None

    async def _http(self) -> aiohttp.ClientSession:
        if self._session is None or self._session.closed:
            self._session = aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=120))
        return self._session

    async def close(self) -> None:
        if self._session and not self._session.closed:
            await self._session.close()

    async def reply(self, system: str, history: list[dict]) -> str:
        messages = merge_turns(history)
        if not messages:
            return ""
        if self.cfg["backend"] == "anthropic":
            return await self._anthropic(system, messages)
        return await self._openai(system, messages)

    async def _openai(self, system: str, messages: list[dict]) -> str:
        url = self.cfg["base_url"].rstrip("/") + "/chat/completions"
        headers = {"Content-Type": "application/json"}
        key = os.environ.get("OPENAI_API_KEY") or os.environ.get("LLM_API_KEY")
        if key:
            headers["Authorization"] = f"Bearer {key}"
        body = {
            "model": self.cfg["model"],
            "messages": [{"role": "system", "content": system}, *messages],
            "max_tokens": self.cfg["max_tokens"],
            "temperature": self.cfg["temperature"],
        }
        http = await self._http()
        async with http.post(url, json=body, headers=headers) as resp:
            data = await resp.json(content_type=None)
            if resp.status != 200:
                raise LLMError(f"LLM server returned {resp.status}: {str(data)[:300]}")
        return (data["choices"][0]["message"].get("content") or "").strip()

    async def _anthropic(self, system: str, messages: list[dict]) -> str:
        key = os.environ.get("ANTHROPIC_API_KEY")
        if not key:
            raise LLMError("ANTHROPIC_API_KEY is not set")
        base = self.cfg.get("base_url") or ""
        if "anthropic" not in base:
            base = "https://api.anthropic.com"
        headers = {
            "x-api-key": key,
            "anthropic-version": "2023-06-01",
            "content-type": "application/json",
        }
        body = {
            "model": self.cfg["model"],
            "system": system,
            "messages": messages,
            "max_tokens": self.cfg["max_tokens"],
            "temperature": min(float(self.cfg["temperature"]), 1.0),
        }
        http = await self._http()
        async with http.post(base.rstrip("/") + "/v1/messages", json=body, headers=headers) as resp:
            data = await resp.json(content_type=None)
            if resp.status != 200:
                raise LLMError(f"Claude API returned {resp.status}: {str(data)[:300]}")
        return "".join(b.get("text", "") for b in data.get("content", []) if b.get("type") == "text").strip()
