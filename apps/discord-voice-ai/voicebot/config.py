"""Loads config.toml and fills in defaults for anything left out."""

from __future__ import annotations

import copy
import tomllib
from pathlib import Path
from typing import Any

DEFAULTS: dict[str, Any] = {
    "bot": {
        "name": "Echo",
        # Words that make the bot answer when listen_mode is "wake".
        "wake_words": ["echo"],
        # "wake": only answer when addressed. "always": answer everything it hears.
        "listen_mode": "wake",
        # Only listen to people who ran /optin. Strongly recommended.
        "require_opt_in": True,
        # After answering someone, keep listening to them without the wake word for this long.
        "followup_window_s": 20.0,
        # Post "Name: text" and the bot's reply in the text channel /join was used in.
        "show_transcript": True,
        "data_dir": "data",
        "voices_dir": "voices",
        # Set to a server ID to register slash commands there instantly while testing.
        "dev_guild_id": 0,
    },
    "audio": {
        # How long someone has to stay quiet before their sentence counts as finished.
        "silence_timeout_s": 0.9,
        "min_utterance_s": 0.4,
        "max_utterance_s": 25.0,
        # RMS level (16 bit) a 20 ms frame needs to count as speech.
        "energy_threshold": 350,
        # Stop talking when someone talks over the bot for this long. 0 disables it.
        "barge_in_s": 0.4,
    },
    "stt": {
        # faster-whisper model: tiny, base, small, medium, large-v3, distil-large-v3, ...
        "model": "small",
        "device": "auto",
        "compute_type": "auto",
        # Empty means auto-detect each time. "en", "de", ... to force a language.
        "language": "",
    },
    "llm": {
        # "openai" covers anything OpenAI-compatible: Ollama, llama.cpp, LM Studio, vLLM.
        # "anthropic" uses the Claude API (needs ANTHROPIC_API_KEY).
        "backend": "openai",
        "base_url": "http://localhost:11434/v1",
        "model": "",
        "max_tokens": 300,
        "temperature": 0.8,
        "history_turns": 12,
        "persona": (
            "You are {name}, a friendly and witty voice in a Discord voice channel. "
            "Several people may be talking; each message starts with the speaker's name in brackets."
        ),
    },
    "tts": {
        # "turbo" (fast, English, needs GPU for real-time), "nano" (English, runs on CPU),
        # "standard" (English, supports exaggeration/cfg_weight), "multilingual" (23 languages).
        "model": "nano",
        "device": "auto",
        # Only used by the multilingual model.
        "language": "en",
        # File name (without .wav) in voices_dir. Empty means the model's built-in voice.
        "default_voice": "",
        "speed": 1.0,
        "pitch": 1.0,
        "volume": 1.0,
        "exaggeration": 0.5,
        "cfg_weight": 0.5,
        "temperature": 0.8,
    },
}

# Rules the bot always appends to the persona so replies work as speech.
SPOKEN_RULES = (
    "Your replies are converted to speech, so: answer in one to three short sentences unless asked "
    "for more, never use markdown, lists, emojis, URLs or code, and write numbers the way you would say them. "
    "Do not start your reply with your own name in brackets."
)


def _merge(base: dict, override: dict) -> dict:
    out = copy.deepcopy(base)
    for key, value in override.items():
        if isinstance(value, dict) and isinstance(out.get(key), dict):
            out[key] = _merge(out[key], value)
        else:
            out[key] = value
    return out


def load_config(path: str | Path = "config.toml") -> dict[str, Any]:
    path = Path(path)
    user: dict[str, Any] = {}
    if path.exists():
        with path.open("rb") as f:
            user = tomllib.load(f)
    cfg = _merge(DEFAULTS, user)
    cfg["bot"]["wake_words"] = [w.lower().strip() for w in cfg["bot"]["wake_words"] if w.strip()]
    return cfg
