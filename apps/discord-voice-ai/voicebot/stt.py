"""Speech to text with faster-whisper, fully local."""

from __future__ import annotations

import logging

from .vad import to_whisper_input

log = logging.getLogger(__name__)

# Whisper likes to "hear" these in noise or breathing.
HALLUCINATIONS = {
    "thank you.", "thanks for watching!", "thank you for watching.", "you", ".", "bye.",
    "untertitel der amara.org-community", "vielen dank.", "untertitel im auftrag des zdf, 2017",
}


class Transcriber:
    def __init__(self, cfg: dict):
        self.cfg = cfg
        self.model = None

    def load(self) -> None:
        from faster_whisper import WhisperModel

        device = self.cfg["device"]
        if device == "auto":
            try:
                import torch

                device = "cuda" if torch.cuda.is_available() else "cpu"
            except ImportError:
                device = "cpu"
        compute = self.cfg["compute_type"]
        if compute == "auto":
            compute = "float16" if device == "cuda" else "int8"
        log.info("Loading Whisper %s on %s (%s)", self.cfg["model"], device, compute)
        self.model = WhisperModel(self.cfg["model"], device=device, compute_type=compute)

    def transcribe(self, pcm: bytes) -> str:
        assert self.model is not None, "Transcriber.load() was not called"
        audio = to_whisper_input(pcm)
        segments, _info = self.model.transcribe(
            audio,
            language=self.cfg["language"] or None,
            beam_size=1,
            condition_on_previous_text=False,
            vad_filter=True,
        )
        parts = [
            s.text.strip()
            for s in segments
            if s.no_speech_prob < 0.6 and s.avg_logprob > -1.0
        ]
        text = " ".join(p for p in parts if p).strip()
        if text.lower() in HALLUCINATIONS:
            return ""
        return text
