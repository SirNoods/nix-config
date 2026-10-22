"""One live voice conversation in one server: listen, transcribe, think, speak."""

from __future__ import annotations

import asyncio
import collections
import logging
import re
import time
from typing import TYPE_CHECKING

import discord
from discord.ext import voice_recv

from .config import SPOKEN_RULES
from .llm import LLMError
from .playback import StreamingPCMSource
from .tts import clean_for_speech, split_sentences
from .vad import Utterance, UtteranceCollector

if TYPE_CHECKING:
    from .bot import VoiceBot

log = logging.getLogger(__name__)


class GuildSession:
    def __init__(self, bot: "VoiceBot", vc: voice_recv.VoiceRecvClient, text_channel):
        self.bot = bot
        self.vc = vc
        self.guild_id = vc.guild.id
        self.text_channel = text_channel
        a = bot.cfg["audio"]
        self.collector = UtteranceCollector(
            energy_threshold=a["energy_threshold"],
            silence_timeout=a["silence_timeout_s"],
            min_utterance=a["min_utterance_s"],
            max_utterance=a["max_utterance_s"],
            barge_in=a["barge_in_s"],
        )
        self.queue: asyncio.Queue[Utterance] = asyncio.Queue(maxsize=8)
        self.history: collections.deque[dict] = collections.deque(maxlen=bot.cfg["llm"]["history_turns"] * 2)
        self.followups: dict[int, float] = {}
        self.current_source: StreamingPCMSource | None = None
        self.speak_lock = asyncio.Lock()
        self.loop = asyncio.get_running_loop()
        self._tasks: list[asyncio.Task] = []

    # ---- lifecycle -------------------------------------------------------

    def start(self) -> None:
        self.vc.listen(voice_recv.BasicSink(self._on_packet))
        self._tasks = [
            asyncio.create_task(self._monitor(), name=f"monitor-{self.guild_id}"),
            asyncio.create_task(self._worker(), name=f"worker-{self.guild_id}"),
        ]

    async def stop(self, disconnect: bool = True) -> None:
        for task in self._tasks:
            task.cancel()
        self.interrupt()
        if disconnect and self.vc.is_connected():
            try:
                self.vc.stop_listening()
            except Exception:
                pass
            await self.vc.disconnect(force=True)

    # ---- listening (runs on the voice receive thread) ---------------------

    def _on_packet(self, user, data: voice_recv.VoiceData) -> None:
        if user is None or getattr(user, "bot", False) or not data.pcm:
            return
        settings = self.bot.settings.get(self.guild_id)
        if self.bot.cfg["bot"]["require_opt_in"] and user.id not in settings["opted_in"]:
            return
        barge = self.collector.feed(user.id, user.display_name, data.pcm, time.monotonic())
        if barge and self.current_source is not None:
            self.loop.call_soon_threadsafe(self.interrupt)

    def forget_user(self, user_id: int) -> None:
        self.collector.drop(user_id)
        self.followups.pop(user_id, None)

    async def _monitor(self) -> None:
        while True:
            await asyncio.sleep(0.1)
            for utt in self.collector.poll(time.monotonic()):
                try:
                    self.queue.put_nowait(utt)
                except asyncio.QueueFull:
                    log.warning("Dropping a sentence from %s, the bot is falling behind", utt.name)

    async def _worker(self) -> None:
        while True:
            utt = await self.queue.get()
            try:
                await self._handle(utt)
            except asyncio.CancelledError:
                raise
            except Exception:
                log.exception("Failed to handle a sentence from %s", utt.name)

    # ---- thinking ----------------------------------------------------------

    def _addressed(self, user_id: int, text: str, listen_mode: str) -> bool:
        if listen_mode == "always":
            return True
        if self.followups.get(user_id, 0) > time.monotonic():
            return True
        lowered = text.lower()
        return any(re.search(rf"\b{re.escape(w)}\b", lowered) for w in self.bot.cfg["bot"]["wake_words"])

    def system_prompt(self, settings: dict) -> str:
        name = self.bot.cfg["bot"]["name"]
        persona = settings["persona"].replace("{name}", name)
        return f"{persona}\n\n{SPOKEN_RULES}"

    async def _handle(self, utt: Utterance) -> None:
        text = await self.loop.run_in_executor(self.bot.stt_pool, self.bot.stt.transcribe, utt.pcm)
        if not text:
            return
        settings = self.bot.settings.get(self.guild_id)
        if not self._addressed(utt.user_id, text, settings["listen_mode"]):
            log.debug("Heard %s but was not addressed", utt.name)
            return

        log.info("%s: %s", utt.name, text)
        await self.post(f"**{discord.utils.escape_markdown(utt.name)}:** {text}")
        self.history.append({"role": "user", "content": f"[{utt.name}] {text}"})

        try:
            reply = await self.bot.brain.reply(self.system_prompt(settings), list(self.history))
        except (LLMError, OSError, asyncio.TimeoutError) as e:
            self.history.pop()
            await self.post(f"*(could not reach the language model: {e})*")
            return

        reply = clean_for_speech(reply)
        if not reply:
            return
        self.history.append({"role": "assistant", "content": reply})
        log.info("%s: %s", self.bot.cfg["bot"]["name"], reply)
        await self.post(f"**{self.bot.cfg['bot']['name']}:** {reply}")
        await self.speak(reply, settings)
        self.followups[utt.user_id] = time.monotonic() + float(self.bot.cfg["bot"]["followup_window_s"])

    async def post(self, text: str) -> None:
        if not (self.bot.cfg["bot"]["show_transcript"] and self.text_channel):
            return
        try:
            await self.text_channel.send(text[:2000], allowed_mentions=discord.AllowedMentions.none())
        except discord.HTTPException:
            log.warning("Could not post to the transcript channel")

    # ---- speaking ----------------------------------------------------------

    def interrupt(self) -> None:
        source, self.current_source = self.current_source, None
        if source is not None:
            source.clear()
        if self.vc.is_connected() and self.vc.is_playing():
            self.vc.stop_playing()

    async def speak(self, text: str, settings: dict | None = None) -> None:
        settings = settings or self.bot.settings.get(self.guild_id)
        async with self.speak_lock:
            if not self.vc.is_connected():
                return
            source = StreamingPCMSource()
            self.current_source = source
            done = asyncio.Event()
            started = False
            try:
                for chunk in split_sentences(clean_for_speech(text)):
                    pcm = await self.loop.run_in_executor(self.bot.tts_pool, self.bot.tts.render, chunk, settings)
                    if self.current_source is not source:  # someone talked over us
                        break
                    source.push(pcm)
                    if not started:
                        if self.vc.is_playing():
                            self.vc.stop_playing()
                        self.vc.play(source, after=lambda _e: self.loop.call_soon_threadsafe(done.set))
                        started = True
            finally:
                source.finish()
            if started:
                try:
                    await asyncio.wait_for(done.wait(), timeout=600)
                except asyncio.TimeoutError:
                    self.interrupt()
            if self.current_source is source:
                self.current_source = None
