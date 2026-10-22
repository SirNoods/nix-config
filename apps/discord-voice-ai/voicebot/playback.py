"""An audio source the bot can start playing before the whole reply has been synthesized."""

from __future__ import annotations

import threading

import discord

FRAME_BYTES = 3840  # 20 ms of 48 kHz stereo s16
SILENCE = b"\x00" * FRAME_BYTES


class StreamingPCMSource(discord.AudioSource):
    """Sentences are pushed in as they are synthesized. While the next one is still
    rendering, it plays silence instead of ending, so the bot does not cut out."""

    def __init__(self) -> None:
        self._buf = bytearray()
        self._lock = threading.Lock()
        self._finished = False

    def push(self, pcm: bytes) -> None:
        with self._lock:
            self._buf.extend(pcm)

    def finish(self) -> None:
        with self._lock:
            self._finished = True

    def clear(self) -> None:
        with self._lock:
            self._buf.clear()
            self._finished = True

    def read(self) -> bytes:
        with self._lock:
            if len(self._buf) >= FRAME_BYTES:
                frame = bytes(self._buf[:FRAME_BYTES])
                del self._buf[:FRAME_BYTES]
                return frame
            if self._finished:
                if self._buf:  # pad the last partial frame
                    frame = bytes(self._buf) + SILENCE[len(self._buf):]
                    self._buf.clear()
                    return frame
                return b""
            return SILENCE

    def is_opus(self) -> bool:
        return False
