"""Tests for the parts that need no Discord connection or models.
Run with: python -m unittest discover tests
"""

import json
import tempfile
import unittest
from pathlib import Path

import numpy as np

from voicebot.config import load_config
from voicebot.llm import merge_turns
from voicebot.settings import SettingsStore
from voicebot.tts import (
    atempo_chain,
    build_filter,
    clean_for_speech,
    import_voice_sample,
    split_sentences,
    to_discord_pcm,
)
from voicebot.vad import BYTES_PER_SECOND, UtteranceCollector, to_whisper_input

FRAME = 3840  # 20 ms


def tone(seconds: float, amp: int = 4000) -> bytes:
    n = int(48000 * seconds)
    t = np.arange(n) / 48000
    mono = (np.sin(2 * np.pi * 220 * t) * amp).astype(np.int16)
    return np.repeat(mono, 2).tobytes()


def frames(pcm: bytes):
    for i in range(0, len(pcm), FRAME):
        yield pcm[i : i + FRAME]


class CollectorTests(unittest.TestCase):
    def make(self, **kw):
        args = dict(energy_threshold=350, silence_timeout=0.9, min_utterance=0.4, max_utterance=25, barge_in=0.4)
        args.update(kw)
        return UtteranceCollector(**args)

    def feed(self, col, pcm, start):
        t, barges = start, 0
        for f in frames(pcm):
            barges += col.feed(1, "Ana", f, t)
            t += 0.02
        return t, barges

    def test_sentence_ends_after_silence(self):
        col = self.make()
        t, barges = self.feed(col, tone(1.0), 0.0)
        self.assertEqual(barges, 1)  # fires once, after 0.4 s
        self.assertEqual(col.poll(t + 0.5), [])  # not quiet long enough yet
        done = col.poll(t + 1.0)
        self.assertEqual(len(done), 1)
        self.assertEqual(done[0].name, "Ana")
        self.assertAlmostEqual(done[0].duration, 1.0, delta=0.05)

    def test_preroll_keeps_quiet_lead_in(self):
        col = self.make()
        t, _ = self.feed(col, tone(0.3, amp=50), 0.0)  # quiet, below threshold
        t, _ = self.feed(col, tone(1.0), t)
        utt = col.poll(t + 1.0)[0]
        self.assertAlmostEqual(utt.duration, 1.2, delta=0.05)  # 200 ms preroll + 1 s

    def test_short_noise_is_dropped(self):
        col = self.make()
        t, barges = self.feed(col, tone(0.2), 0.0)
        self.assertEqual(barges, 0)
        self.assertEqual(col.poll(t + 1.0), [])

    def test_quiet_audio_never_starts(self):
        col = self.make()
        t, _ = self.feed(col, tone(2.0, amp=50), 0.0)
        self.assertEqual(col.poll(t + 5), [])

    def test_max_length_forces_cut(self):
        col = self.make(max_utterance=2.0)
        t, _ = self.feed(col, tone(2.5), 0.0)
        self.assertEqual(len(col.poll(t)), 1)

    def test_barge_in_disabled(self):
        col = self.make(barge_in=0)
        _, barges = self.feed(col, tone(2.0), 0.0)
        self.assertEqual(barges, 0)

    def test_whisper_input_shape(self):
        audio = to_whisper_input(tone(1.0))
        self.assertEqual(audio.dtype, np.float32)
        self.assertEqual(len(audio), 16000)
        self.assertLessEqual(float(np.abs(audio).max()), 1.0)


class SpeechTextTests(unittest.TestCase):
    def test_clean(self):
        self.assertEqual(clean_for_speech("**Hi** there, see [docs](http://x.y) or https://a.b now"), "Hi there, see docs or now")
        self.assertEqual(clean_for_speech("Ha [laugh] nice"), "Ha [laugh] nice")

    def test_split_merges_short_and_breaks_long(self):
        self.assertEqual(split_sentences("Hi! How are you doing today? Great."), ["Hi! How are you doing today?", "Great."])
        long = "word, " * 100
        parts = split_sentences(long, max_len=120)
        self.assertTrue(all(len(p) <= 121 for p in parts))
        self.assertEqual(" ".join(parts).split(), long.split())


class AudioShapingTests(unittest.TestCase):
    def test_atempo_chain_stays_in_range(self):
        for f in (0.25, 0.5, 1.0, 1.5, 4.0):
            stages = atempo_chain(f)
            prod = 1.0
            for s in stages:
                v = float(s.split("=")[1])
                self.assertTrue(0.5 <= v <= 2.0)
                prod *= v
            self.assertAlmostEqual(prod, f, places=3)

    def test_filter(self):
        self.assertEqual(build_filter(24000, 1, 1, 1), "aresample=48000")
        self.assertIn("asetrate=28800", build_filter(24000, 1, 1.2, 1))

    def test_pcm_conversion_lengths(self):
        sr = 24000
        audio = np.sin(np.arange(sr * 2) / sr * 2 * np.pi * 200).astype(np.float32) * 0.5
        normal = to_discord_pcm(audio, sr)
        self.assertAlmostEqual(len(normal) / BYTES_PER_SECOND, 2.0, delta=0.05)
        fast = to_discord_pcm(audio, sr, speed=2.0)
        self.assertAlmostEqual(len(fast) / BYTES_PER_SECOND, 1.0, delta=0.05)
        high = to_discord_pcm(audio, sr, pitch=1.5)  # pitch must not change length
        self.assertAlmostEqual(len(high) / BYTES_PER_SECOND, 2.0, delta=0.08)
        quiet = to_discord_pcm(audio, sr, volume=0.5)
        a = np.frombuffer(normal, np.int16).astype(float)
        b = np.frombuffer(quiet, np.int16).astype(float)
        self.assertAlmostEqual(np.abs(b).mean() / np.abs(a).mean(), 0.5, delta=0.05)

    def test_import_voice_sample(self):
        import subprocess

        with tempfile.TemporaryDirectory() as tmp:
            src = Path(tmp) / "in.mp3"
            subprocess.run(
                ["ffmpeg", "-loglevel", "error", "-f", "lavfi", "-i", "sine=frequency=300:duration=40", str(src)],
                check=True,
            )
            secs = import_voice_sample(src, Path(tmp) / "voices" / "me.wav")
            self.assertAlmostEqual(secs, 30.0, delta=0.1)  # capped at 30 s


class ConfigAndSettingsTests(unittest.TestCase):
    def test_example_config_loads(self):
        cfg = load_config(Path(__file__).parent.parent / "config.example.toml")
        self.assertEqual(cfg["tts"]["model"], "nano")
        self.assertIn("{name}", cfg["llm"]["persona"])
        self.assertNotIn("\\", cfg["llm"]["persona"])

    def test_missing_config_uses_defaults(self):
        cfg = load_config("/nonexistent.toml")
        self.assertEqual(cfg["bot"]["wake_words"], ["echo"])

    def test_settings_roundtrip(self):
        cfg = load_config("/nonexistent.toml")
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "s.json"
            store = SettingsStore(path, cfg["tts"], cfg["bot"], "persona")
            store.set(1, "speed", 1.3)
            store.set_opt_in(1, 42, True)
            store2 = SettingsStore(path, cfg["tts"], cfg["bot"], "persona")
            self.assertEqual(store2.get(1)["speed"], 1.3)
            self.assertEqual(store2.get(1)["opted_in"], [42])
            self.assertEqual(store2.get(2)["speed"], 1.0)  # other servers untouched
            store2.set_opt_in(1, 42, False)
            store2.reset(1, ["speed"])
            self.assertEqual(store2.get(1)["speed"], 1.0)
            self.assertEqual(json.loads(path.read_text())["1"]["opted_in"], [])


class LLMTests(unittest.TestCase):
    def test_merge_turns(self):
        hist = [
            {"role": "assistant", "content": "orphan"},
            {"role": "user", "content": "[A] hi"},
            {"role": "user", "content": "[B] hey"},
            {"role": "assistant", "content": "hello both"},
        ]
        self.assertEqual(
            merge_turns(hist),
            [{"role": "user", "content": "[A] hi\n[B] hey"}, {"role": "assistant", "content": "hello both"}],
        )


if __name__ == "__main__":
    unittest.main()
