"""Cloned-voice text to speech with Chatterbox, plus speed/pitch/volume shaping via ffmpeg."""

from __future__ import annotations

import logging
import re
import subprocess
from pathlib import Path

import numpy as np

log = logging.getLogger(__name__)

DISCORD_RATE = 48_000
MIN_SAMPLE_S = {"turbo": 5.0, "nano": 5.0}  # Turbo/Nano refuse shorter voice samples


def atempo_chain(factor: float) -> list[str]:
    """ffmpeg's atempo only accepts 0.5..2.0 per stage, so split bigger changes."""
    stages: list[str] = []
    while factor < 0.5:
        stages.append("atempo=0.5")
        factor /= 0.5
    while factor > 2.0:
        stages.append("atempo=2.0")
        factor /= 2.0
    if abs(factor - 1.0) > 1e-3:
        stages.append(f"atempo={factor:.4f}")
    return stages


def build_filter(sr: int, speed: float, pitch: float, volume: float) -> str:
    """Pitch via resampling, then tempo correction so pitch does not change speed."""
    filters: list[str] = []
    if abs(pitch - 1.0) > 1e-3:
        filters += [f"asetrate={int(sr * pitch)}", f"aresample={sr}"]
    filters += atempo_chain(speed / pitch)
    if abs(volume - 1.0) > 1e-3:
        filters.append(f"volume={volume:.3f}")
    filters.append(f"aresample={DISCORD_RATE}")
    return ",".join(filters)


def to_discord_pcm(audio: np.ndarray, sr: int, speed=1.0, pitch=1.0, volume=1.0) -> bytes:
    """Mono float32 at `sr` -> 48 kHz stereo s16le bytes, ready for Discord."""
    audio = np.clip(np.asarray(audio, dtype=np.float32).reshape(-1), -1.0, 1.0)
    cmd = [
        "ffmpeg", "-hide_banner", "-loglevel", "error",
        "-f", "f32le", "-ar", str(sr), "-ac", "1", "-i", "pipe:0",
        "-af", build_filter(sr, speed, pitch, volume),
        "-f", "s16le", "-ar", str(DISCORD_RATE), "-ac", "2", "pipe:1",
    ]
    proc = subprocess.run(cmd, input=audio.tobytes(), capture_output=True, check=False)
    if proc.returncode != 0:
        raise RuntimeError(f"ffmpeg failed: {proc.stderr.decode(errors='replace')[:300]}")
    return proc.stdout


_SENTENCE_END = re.compile(r"(?<=[.!?…])\s+")
_MARKDOWN = re.compile(r"[*_`#>~]|\[(.*?)\]\(.*?\)")


def clean_for_speech(text: str) -> str:
    text = _MARKDOWN.sub(lambda m: m.group(1) or "", text)
    text = re.sub(r"https?://\S+", "", text)
    return re.sub(r"\s+", " ", text).strip()


def split_sentences(text: str, min_len: int = 25, max_len: int = 300) -> list[str]:
    """Split into chunks small enough to start speaking fast, big enough to sound natural."""
    pieces = [p.strip() for p in _SENTENCE_END.split(text) if p.strip()]
    chunks: list[str] = []
    for piece in pieces:
        if chunks and len(chunks[-1]) < min_len:
            chunks[-1] = f"{chunks[-1]} {piece}"
        else:
            chunks.append(piece)
    out: list[str] = []
    for chunk in chunks:  # break run-on sentences at commas
        while len(chunk) > max_len:
            cut = chunk.rfind(",", 0, max_len)
            cut = cut if cut > min_len else chunk.rfind(" ", 0, max_len)
            cut = cut if cut > 0 else max_len
            out.append(chunk[: cut + 1].strip())
            chunk = chunk[cut + 1 :].strip()
        if chunk:
            out.append(chunk)
    return out


class VoiceEngine:
    def __init__(self, cfg: dict, voices_dir: Path):
        self.cfg = cfg
        self.variant = cfg["model"]
        self.voices_dir = voices_dir
        self.model = None
        self.sr = 24_000
        self._builtin_conds = None
        self._conds_key: tuple | None = None

    def load(self) -> None:
        import torch

        device = self.cfg["device"]
        if device == "auto":
            device = "cuda" if torch.cuda.is_available() else "cpu"
        log.info("Loading Chatterbox %s on %s", self.variant, device)
        if self.variant in ("turbo", "nano"):
            import inspect

            from chatterbox.tts_turbo import ChatterboxTurboTTS

            if self.variant == "nano" and "nano" not in inspect.signature(ChatterboxTurboTTS.from_pretrained).parameters:
                raise RuntimeError(
                    "The installed chatterbox-tts has no Nano model. Install it from GitHub as in "
                    "requirements.txt, or set tts.model to \"turbo\"."
                )
            kwargs = {"nano": True} if self.variant == "nano" else {}
            self.model = ChatterboxTurboTTS.from_pretrained(device=device, **kwargs)
        elif self.variant == "multilingual":
            from chatterbox.mtl_tts import ChatterboxMultilingualTTS

            self.model = ChatterboxMultilingualTTS.from_pretrained(device=torch.device(device))
        elif self.variant == "standard":
            from chatterbox.tts import ChatterboxTTS

            self.model = ChatterboxTTS.from_pretrained(device=device)
        else:
            raise ValueError(f"Unknown tts.model {self.variant!r}")
        self.sr = self.model.sr
        self._builtin_conds = self.model.conds

    def voice_path(self, name: str) -> Path | None:
        if not name:
            return None
        path = self.voices_dir / f"{name}.wav"
        return path if path.exists() else None

    def list_voices(self) -> list[str]:
        if not self.voices_dir.exists():
            return []
        return sorted(p.stem for p in self.voices_dir.glob("*.wav"))

    def _use_voice(self, path: Path | None, exaggeration: float) -> None:
        """Computing a voice's conditioning is slow, so only redo it when something changed."""
        key = (str(path), path.stat().st_mtime if path else 0, round(exaggeration, 3))
        if key == self._conds_key:
            return
        if path is None:
            self.model.conds = self._builtin_conds
        else:
            self.model.prepare_conditionals(str(path), exaggeration=exaggeration)
        self._conds_key = key

    def synthesize(self, text: str, settings: dict) -> np.ndarray:
        """Returns mono float32 audio at self.sr. Blocking: call from a worker thread."""
        assert self.model is not None, "VoiceEngine.load() was not called"
        self._use_voice(self.voice_path(settings["voice"]), settings["exaggeration"])
        temperature = float(settings["temperature"])
        if self.variant in ("turbo", "nano"):
            wav = self.model.generate(text, temperature=temperature)
        elif self.variant == "multilingual":
            wav = self.model.generate(
                text,
                language_id=self.cfg["language"],
                exaggeration=settings["exaggeration"],
                cfg_weight=settings["cfg_weight"],
                temperature=temperature,
            )
        else:
            wav = self.model.generate(
                text,
                exaggeration=settings["exaggeration"],
                cfg_weight=settings["cfg_weight"],
                temperature=temperature,
            )
        return wav.squeeze().detach().cpu().numpy().astype(np.float32)

    def render(self, text: str, settings: dict) -> bytes:
        audio = self.synthesize(text, settings)
        return to_discord_pcm(audio, self.sr, settings["speed"], settings["pitch"], settings["volume"])


def import_voice_sample(src: Path, dest: Path, max_seconds: int = 30) -> float:
    """Convert any audio file to a clean mono WAV voice sample. Returns its length in seconds."""
    dest.parent.mkdir(parents=True, exist_ok=True)
    cmd = [
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", str(src),
        "-t", str(max_seconds), "-ac", "1", "-ar", "24000", "-sample_fmt", "s16", str(dest),
    ]
    proc = subprocess.run(cmd, capture_output=True, check=False)
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.decode(errors="replace")[:300] or "ffmpeg could not read that file")
    return (dest.stat().st_size - 44) / (24000 * 2)
