"""Per-server settings that slash commands can change, saved to a JSON file."""

from __future__ import annotations

import json
import os
import threading
from pathlib import Path
from typing import Any

# name -> (min, max, description). These are the knobs /tune exposes.
TUNABLES: dict[str, tuple[float, float, str]] = {
    "speed": (0.5, 2.0, "Speaking speed, 1.0 is normal"),
    "pitch": (0.5, 2.0, "Voice pitch, 1.0 is normal"),
    "volume": (0.0, 2.0, "Loudness, 1.0 is normal"),
    "exaggeration": (0.0, 2.0, "Emotional intensity (standard and multilingual models)"),
    "cfg_weight": (0.0, 1.0, "Lower is slower and more deliberate (standard and multilingual models)"),
    "temperature": (0.1, 1.5, "Voice randomness, higher is more varied"),
}


class SettingsStore:
    def __init__(self, path: Path, tts_defaults: dict[str, Any], bot_defaults: dict[str, Any], persona: str):
        self.path = path
        self._lock = threading.Lock()
        self._defaults = {
            **{k: float(tts_defaults[k]) for k in TUNABLES},
            "voice": tts_defaults.get("default_voice", ""),
            "listen_mode": bot_defaults["listen_mode"],
            "persona": persona,
            "opted_in": [],
        }
        self._data: dict[str, dict[str, Any]] = {}
        if path.exists():
            try:
                self._data = json.loads(path.read_text())
            except (OSError, json.JSONDecodeError):
                self._data = {}

    def get(self, guild_id: int) -> dict[str, Any]:
        with self._lock:
            stored = self._data.get(str(guild_id), {})
            return {**self._defaults, **stored}

    def set(self, guild_id: int, key: str, value: Any) -> None:
        with self._lock:
            self._data.setdefault(str(guild_id), {})[key] = value
            self._save()

    def reset(self, guild_id: int, keys: list[str]) -> None:
        with self._lock:
            stored = self._data.get(str(guild_id), {})
            for key in keys:
                stored.pop(key, None)
            self._save()

    def set_opt_in(self, guild_id: int, user_id: int, opted: bool) -> None:
        with self._lock:
            stored = self._data.setdefault(str(guild_id), {})
            users = set(stored.get("opted_in", []))
            users.add(user_id) if opted else users.discard(user_id)
            stored["opted_in"] = sorted(users)
            self._save()

    def _save(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.path.with_suffix(".tmp")
        tmp.write_text(json.dumps(self._data, indent=2))
        os.replace(tmp, self.path)
