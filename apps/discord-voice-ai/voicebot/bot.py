"""The Discord bot: slash commands and wiring between the pieces."""

from __future__ import annotations

import asyncio
import concurrent.futures
import ctypes.util
import logging
import os
import re
import tempfile
from pathlib import Path

import discord
from discord import app_commands
from discord.ext import commands, voice_recv

from .llm import Brain
from .session import GuildSession
from .settings import TUNABLES, SettingsStore
from .stt import Transcriber
from .tts import MIN_SAMPLE_S, VoiceEngine, import_voice_sample

log = logging.getLogger(__name__)

VOICE_NAME = re.compile(r"^[a-z0-9_-]{1,32}$")
MAX_UPLOAD_BYTES = 25 * 1024 * 1024


def load_opus() -> None:
    if discord.opus.is_loaded():
        return
    path = os.environ.get("OPUS_LIB") or ctypes.util.find_library("opus")
    if not path:
        raise RuntimeError("libopus not found. Install it or set OPUS_LIB to the path of libopus.so")
    discord.opus.load_opus(path)


class VoiceBot(commands.Bot):
    def __init__(self, cfg: dict):
        intents = discord.Intents.default()
        intents.members = True  # needed to map voice packets to member names reliably
        super().__init__(command_prefix=commands.when_mentioned, intents=intents)
        self.cfg = cfg
        data_dir = Path(cfg["bot"]["data_dir"])
        self.voices_dir = Path(cfg["bot"]["voices_dir"])
        self.settings = SettingsStore(data_dir / "guild_settings.json", cfg["tts"], cfg["bot"], cfg["llm"]["persona"])
        self.stt = Transcriber(cfg["stt"])
        self.tts = VoiceEngine(cfg["tts"], self.voices_dir)
        self.brain = Brain(cfg["llm"])
        # One thread each: the models are not thread-safe and the GPU is shared anyway.
        self.stt_pool = concurrent.futures.ThreadPoolExecutor(1, thread_name_prefix="stt")
        self.tts_pool = concurrent.futures.ThreadPoolExecutor(1, thread_name_prefix="tts")
        self.sessions: dict[int, GuildSession] = {}
        self.models_ready = asyncio.Event()
        self.model_error: str | None = None

    async def setup_hook(self) -> None:
        await self.add_cog(VoiceCog(self))
        dev_guild = int(self.cfg["bot"].get("dev_guild_id") or 0)
        if dev_guild:
            guild = discord.Object(id=dev_guild)
            self.tree.copy_global_to(guild=guild)
            await self.tree.sync(guild=guild)
        else:
            await self.tree.sync()
        self._load_task = asyncio.create_task(self._load_models())

    async def _load_models(self) -> None:
        loop = asyncio.get_running_loop()
        try:
            await asyncio.gather(
                loop.run_in_executor(self.stt_pool, self.stt.load),
                loop.run_in_executor(self.tts_pool, self.tts.load),
            )
        except Exception as e:
            log.exception("Model loading failed")
            self.model_error = str(e)
            return
        self.models_ready.set()
        log.info("Models loaded, ready to talk")

    async def on_ready(self) -> None:
        log.info("Logged in as %s (%s)", self.user, self.user.id if self.user else "?")

    async def on_voice_state_update(self, member: discord.Member, before, after) -> None:
        session = self.sessions.get(member.guild.id)
        if session is None:
            return
        if self.user and member.id == self.user.id and after.channel is None:
            # Kicked or disconnected from outside.
            self.sessions.pop(member.guild.id, None)
            await session.stop(disconnect=False)
            return
        if before.channel == session.vc.channel and after.channel != session.vc.channel:
            session.forget_user(member.id)
            humans = [m for m in session.vc.channel.members if not m.bot]
            if not humans:
                self.sessions.pop(member.guild.id, None)
                await session.stop()

    async def close(self) -> None:
        for session in list(self.sessions.values()):
            await session.stop()
        await self.brain.close()
        await super().close()


# ---- helpers ------------------------------------------------------------------


def is_admin(interaction: discord.Interaction) -> bool:
    perms = getattr(interaction.user, "guild_permissions", None)
    return bool(perms and perms.manage_guild)


async def deny_unless_admin(interaction: discord.Interaction) -> bool:
    if is_admin(interaction):
        return False
    await interaction.response.send_message("You need the Manage Server permission for that.", ephemeral=True)
    return True


async def reply(interaction: discord.Interaction, text: str, ephemeral: bool = True) -> None:
    if interaction.response.is_done():
        await interaction.followup.send(text, ephemeral=ephemeral)
    else:
        await interaction.response.send_message(text, ephemeral=ephemeral)


class VoiceCog(commands.Cog):
    voice = app_commands.Group(name="voice", description="Pick, add and preview cloned voices", guild_only=True)
    tune = app_commands.Group(name="tune", description="Adjust how the voice sounds", guild_only=True)
    persona = app_commands.Group(name="persona", description="Change the bot's personality", guild_only=True)

    def __init__(self, bot: VoiceBot):
        self.bot = bot

    def session(self, interaction: discord.Interaction) -> GuildSession | None:
        return self.bot.sessions.get(interaction.guild_id or 0)

    async def cog_app_command_error(self, interaction: discord.Interaction, error: Exception) -> None:
        log.exception("Command failed", exc_info=error)
        await reply(interaction, f"Something went wrong: {getattr(error, 'original', error)}")

    # ---- joining ----------------------------------------------------------

    @app_commands.command(description="Join your voice channel and start listening")
    @app_commands.guild_only()
    async def join(self, interaction: discord.Interaction) -> None:
        state = getattr(interaction.user, "voice", None)
        if not state or not state.channel:
            return await reply(interaction, "Join a voice channel first.")
        if self.bot.model_error:
            return await reply(interaction, f"Model loading failed: {self.bot.model_error}")
        if not self.bot.models_ready.is_set():
            return await reply(interaction, "Still loading the speech models, try again in a minute.")
        await interaction.response.defer()
        old = self.bot.sessions.pop(interaction.guild_id, None)
        if old:
            await old.stop()
        vc = await state.channel.connect(cls=voice_recv.VoiceRecvClient, self_deaf=False)
        session = GuildSession(self.bot, vc, interaction.channel)
        self.bot.sessions[interaction.guild_id] = session
        session.start()

        cfg = self.bot.cfg["bot"]
        settings = self.bot.settings.get(interaction.guild_id)
        how = (
            f"say **{cfg['wake_words'][0]}** in a sentence to talk to me"
            if settings["listen_mode"] == "wake" and cfg["wake_words"]
            else "I answer everything I hear"
        )
        consent = (
            "\nI only listen to people who run `/optin`. Everyone else is ignored."
            if cfg["require_opt_in"]
            else "\nI am listening to everyone in this channel."
        )
        await interaction.followup.send(f"Joined **{state.channel.name}**. {how}.{consent}")

    @app_commands.command(description="Leave the voice channel")
    @app_commands.guild_only()
    async def leave(self, interaction: discord.Interaction) -> None:
        session = self.bot.sessions.pop(interaction.guild_id, None)
        if not session:
            return await reply(interaction, "I'm not in a voice channel.")
        await session.stop()
        await reply(interaction, "Bye!", ephemeral=False)

    @app_commands.command(description="Let the bot listen to and transcribe your voice")
    @app_commands.guild_only()
    async def optin(self, interaction: discord.Interaction) -> None:
        self.bot.settings.set_opt_in(interaction.guild_id, interaction.user.id, True)
        await reply(interaction, "Got it, I'll listen to you in voice. `/optout` stops that any time.")

    @app_commands.command(description="Stop the bot from listening to your voice")
    @app_commands.guild_only()
    async def optout(self, interaction: discord.Interaction) -> None:
        self.bot.settings.set_opt_in(interaction.guild_id, interaction.user.id, False)
        if session := self.session(interaction):
            session.forget_user(interaction.user.id)
        await reply(interaction, "Done, I no longer listen to you.")

    @app_commands.command(description="Make the bot say something")
    @app_commands.describe(text="What to say")
    @app_commands.guild_only()
    async def say(self, interaction: discord.Interaction, text: app_commands.Range[str, 1, 1000]) -> None:
        session = self.session(interaction)
        if not session:
            return await reply(interaction, "Use `/join` first.")
        await reply(interaction, "Speaking...")
        await session.speak(text)

    @app_commands.command(description="Clear the conversation memory")
    @app_commands.guild_only()
    async def forget(self, interaction: discord.Interaction) -> None:
        if session := self.session(interaction):
            session.history.clear()
            session.followups.clear()
        await reply(interaction, "Conversation memory cleared.", ephemeral=False)

    @app_commands.command(description="Answer only when called by name, or answer everything")
    @app_commands.choices(mode=[
        app_commands.Choice(name="wake word: only when addressed", value="wake"),
        app_commands.Choice(name="always: answer everything", value="always"),
    ])
    @app_commands.guild_only()
    async def mode(self, interaction: discord.Interaction, mode: app_commands.Choice[str]) -> None:
        if await deny_unless_admin(interaction):
            return
        self.bot.settings.set(interaction.guild_id, "listen_mode", mode.value)
        await reply(interaction, f"Listen mode set to **{mode.value}**.", ephemeral=False)

    # ---- voices -----------------------------------------------------------

    async def voice_autocomplete(self, interaction: discord.Interaction, current: str):
        names = ["default", *self.bot.tts.list_voices()]
        return [app_commands.Choice(name=n, value=n) for n in names if current.lower() in n][:25]

    @voice.command(name="list", description="Show available voices")
    async def voice_list(self, interaction: discord.Interaction) -> None:
        current = self.bot.settings.get(interaction.guild_id)["voice"] or "default"
        names = self.bot.tts.list_voices()
        lines = [f"{'> ' if n == current else ''}{n}" for n in ["default", *names]]
        await reply(interaction, "Voices (current marked with >):\n```\n" + "\n".join(lines) + "\n```")

    @voice.command(name="use", description="Switch to a voice")
    @app_commands.autocomplete(name=voice_autocomplete)
    async def voice_use(self, interaction: discord.Interaction, name: str) -> None:
        if await deny_unless_admin(interaction):
            return
        if name != "default" and name not in self.bot.tts.list_voices():
            return await reply(interaction, f"No voice called `{name}`. See `/voice list`.")
        self.bot.settings.set(interaction.guild_id, "voice", "" if name == "default" else name)
        await reply(interaction, f"Now using voice **{name}**.", ephemeral=False)

    @voice.command(name="add", description="Clone a new voice from an audio clip (10 to 30 s of clean speech)")
    @app_commands.describe(name="Short name, lowercase letters, numbers, - and _", sample="Audio file: wav, mp3, ogg, m4a...")
    async def voice_add(self, interaction: discord.Interaction, name: str, sample: discord.Attachment) -> None:
        if await deny_unless_admin(interaction):
            return
        name = name.lower().strip()
        if not VOICE_NAME.match(name) or name == "default":
            return await reply(interaction, "Use 1 to 32 lowercase letters, numbers, `-` or `_` (and not `default`).")
        if sample.size > MAX_UPLOAD_BYTES:
            return await reply(interaction, "That file is too big, keep it under 25 MB.")
        await interaction.response.defer(ephemeral=True)
        dest = self.bot.voices_dir / f"{name}.wav"
        with tempfile.TemporaryDirectory() as tmp:
            src = Path(tmp) / f"upload{Path(sample.filename).suffix or '.bin'}"
            await sample.save(src)
            loop = asyncio.get_running_loop()
            try:
                seconds = await loop.run_in_executor(None, import_voice_sample, src, dest)
            except RuntimeError as e:
                return await reply(interaction, f"Could not read that audio: {e}")
        needed = MIN_SAMPLE_S.get(self.bot.tts.variant, 3.0)
        if seconds < needed:
            dest.unlink(missing_ok=True)
            return await reply(interaction, f"The clip is {seconds:.1f} s, this model needs at least {needed:.0f} s.")
        await reply(
            interaction,
            f"Added voice **{name}** ({seconds:.0f} s). Switch with `/voice use {name}`.\n"
            "Only clone voices you have permission to use.",
        )

    @voice.command(name="remove", description="Delete a cloned voice")
    @app_commands.autocomplete(name=voice_autocomplete)
    async def voice_remove(self, interaction: discord.Interaction, name: str) -> None:
        if await deny_unless_admin(interaction):
            return
        path = self.bot.voices_dir / f"{name}.wav"
        if name == "default" or not path.exists():
            return await reply(interaction, f"No custom voice called `{name}`.")
        path.unlink()
        await reply(interaction, f"Removed **{name}**.")

    @voice.command(name="preview", description="Hear the current voice and settings")
    async def voice_preview(self, interaction: discord.Interaction, text: str | None = None) -> None:
        session = self.session(interaction)
        if not session:
            return await reply(interaction, "Use `/join` first.")
        await reply(interaction, "Previewing...")
        await session.speak(text or f"Hi, I'm {self.bot.cfg['bot']['name']}. This is how I sound right now.")

    # ---- tuning -----------------------------------------------------------

    @tune.command(name="show", description="Show the current voice settings")
    async def tune_show(self, interaction: discord.Interaction) -> None:
        s = self.bot.settings.get(interaction.guild_id)
        lines = [f"{k:<13} {s[k]:<5g} {lo:g} to {hi:g}  {desc}" for k, (lo, hi, desc) in TUNABLES.items()]
        note = ""
        if self.bot.tts.variant in ("turbo", "nano"):
            note = f"\nThe {self.bot.tts.variant} model ignores exaggeration and cfg_weight."
        await reply(interaction, "```\n" + "\n".join(lines) + "\n```" + note)

    @tune.command(name="set", description="Change a voice setting")
    @app_commands.choices(setting=[app_commands.Choice(name=f"{k}: {v[2]}"[:100], value=k) for k, v in TUNABLES.items()])
    async def tune_set(self, interaction: discord.Interaction, setting: app_commands.Choice[str], value: float) -> None:
        if await deny_unless_admin(interaction):
            return
        lo, hi, _ = TUNABLES[setting.value]
        if not lo <= value <= hi:
            return await reply(interaction, f"{setting.value} must be between {lo:g} and {hi:g}.")
        self.bot.settings.set(interaction.guild_id, setting.value, float(value))
        await reply(interaction, f"Set **{setting.value}** to **{value:g}**. Try `/voice preview`.", ephemeral=False)

    @tune.command(name="reset", description="Reset all voice settings to the defaults")
    async def tune_reset(self, interaction: discord.Interaction) -> None:
        if await deny_unless_admin(interaction):
            return
        self.bot.settings.reset(interaction.guild_id, list(TUNABLES))
        await reply(interaction, "Voice settings reset.", ephemeral=False)

    # ---- persona ----------------------------------------------------------

    @persona.command(name="show", description="Show the current personality prompt")
    async def persona_show(self, interaction: discord.Interaction) -> None:
        await reply(interaction, "```\n" + self.bot.settings.get(interaction.guild_id)["persona"][:1900] + "\n```")

    @persona.command(name="set", description="Describe who the bot is and how it talks ({name} = bot name)")
    async def persona_set(self, interaction: discord.Interaction, text: app_commands.Range[str, 10, 1800]) -> None:
        if await deny_unless_admin(interaction):
            return
        self.bot.settings.set(interaction.guild_id, "persona", text)
        if session := self.session(interaction):
            session.history.clear()
        await reply(interaction, "Personality updated and conversation memory cleared.", ephemeral=False)

    @persona.command(name="reset", description="Go back to the default personality")
    async def persona_reset(self, interaction: discord.Interaction) -> None:
        if await deny_unless_admin(interaction):
            return
        self.bot.settings.reset(interaction.guild_id, ["persona"])
        await reply(interaction, "Personality reset.", ephemeral=False)
