"""Turns the stream of 20 ms voice packets into finished sentences per speaker.

Discord sends 48 kHz, stereo, 16-bit PCM. A speaker's sentence starts on the first
frame that is loud enough and ends after `silence_timeout` of quiet (Discord also
stops sending packets while someone is silent, which counts as quiet too).
"""

from __future__ import annotations

import collections
import threading
from dataclasses import dataclass, field

import numpy as np

SAMPLE_RATE = 48_000
CHANNELS = 2
BYTES_PER_SECOND = SAMPLE_RATE * CHANNELS * 2
PREROLL_FRAMES = 10  # 200 ms kept from before speech starts, so first syllables survive


def frame_rms(pcm: bytes) -> float:
    if not pcm:
        return 0.0
    samples = np.frombuffer(pcm, dtype=np.int16).astype(np.float32)
    return float(np.sqrt(np.mean(samples * samples)))


@dataclass
class Utterance:
    user_id: int
    name: str
    pcm: bytes

    @property
    def duration(self) -> float:
        return len(self.pcm) / BYTES_PER_SECOND


@dataclass
class _Speaker:
    name: str
    chunks: list[bytes] = field(default_factory=list)
    voiced_s: float = 0.0
    total_s: float = 0.0
    last_voiced: float = 0.0
    barge_fired: bool = False


class UtteranceCollector:
    def __init__(
        self,
        energy_threshold: float,
        silence_timeout: float,
        min_utterance: float,
        max_utterance: float,
        barge_in: float,
    ):
        self.energy_threshold = energy_threshold
        self.silence_timeout = silence_timeout
        self.min_utterance = min_utterance
        self.max_utterance = max_utterance
        self.barge_in = barge_in
        self._active: dict[int, _Speaker] = {}
        self._preroll: dict[int, collections.deque[bytes]] = {}
        self._lock = threading.Lock()

    def feed(self, user_id: int, name: str, pcm: bytes, now: float) -> bool:
        """Add one packet. Returns True once per sentence when the speaker has talked
        long enough to count as interrupting the bot (barge-in)."""
        if not pcm:
            return False
        dur = len(pcm) / BYTES_PER_SECOND
        voiced = frame_rms(pcm) >= self.energy_threshold
        with self._lock:
            sp = self._active.get(user_id)
            if sp is None:
                pre = self._preroll.setdefault(user_id, collections.deque(maxlen=PREROLL_FRAMES))
                if not voiced:
                    pre.append(pcm)
                    return False
                sp = _Speaker(name=name, chunks=list(pre))
                sp.total_s = sum(len(c) for c in pre) / BYTES_PER_SECOND
                pre.clear()
                self._active[user_id] = sp
            sp.chunks.append(pcm)
            sp.total_s += dur
            if voiced:
                sp.voiced_s += dur
                sp.last_voiced = now
            if self.barge_in > 0 and not sp.barge_fired and sp.voiced_s >= self.barge_in:
                sp.barge_fired = True
                return True
            return False

    def poll(self, now: float) -> list[Utterance]:
        """Return every sentence that has finished by `now`."""
        done: list[Utterance] = []
        with self._lock:
            for user_id, sp in list(self._active.items()):
                finished = (now - sp.last_voiced) >= self.silence_timeout
                too_long = sp.total_s >= self.max_utterance
                if not (finished or too_long):
                    continue
                del self._active[user_id]
                if sp.voiced_s >= self.min_utterance:
                    done.append(Utterance(user_id, sp.name, b"".join(sp.chunks)))
        return done

    def drop(self, user_id: int) -> None:
        with self._lock:
            self._active.pop(user_id, None)
            self._preroll.pop(user_id, None)


def to_whisper_input(pcm: bytes) -> np.ndarray:
    """48 kHz stereo int16 bytes -> 16 kHz mono float32 in [-1, 1]."""
    audio = np.frombuffer(pcm, dtype=np.int16).astype(np.float32) / 32768.0
    audio = audio[: len(audio) - len(audio) % 2].reshape(-1, 2).mean(axis=1)
    audio = audio[: len(audio) - len(audio) % 3].reshape(-1, 3).mean(axis=1)
    return np.ascontiguousarray(audio, dtype=np.float32)
