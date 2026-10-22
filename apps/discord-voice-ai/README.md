# Discord Voice AI

A Discord bot you talk to in a voice channel. It listens, understands what you said, thinks of an answer, and replies out loud in a cloned voice. Speech recognition and the voice run on your own machine; the language model can be local too (Ollama and friends) or the Claude API.

```
you speak ─► Discord (DAVE encrypted) ─► faster-whisper ─► LLM ─► Chatterbox (your cloned voice) ─► voice channel
```

## Features

- **Natural voice conversation.** Talks back sentence by sentence, so it starts speaking before the whole answer is rendered.
- **Wake word or open mic.** By default it answers when you say its name, then keeps listening to you for a short follow-up window. `/mode always` makes it answer everything.
- **Interruptible.** Talk over it and it stops.
- **Custom voices.** Upload a 10 to 30 second clip with `/voice add` and it speaks in that voice.
- **Tunable sound.** Speed, pitch, volume, emotional exaggeration, pacing and randomness, per server, live.
- **Custom personality.** `/persona set` changes who it is and how it talks.
- **Consent first.** It only listens to people who ran `/optin` (configurable).
- **Works with Discord's 2026 voice encryption (DAVE).**

## Requirements

- Linux (NixOS flake included) with Python 3.12, ffmpeg and libopus
- For the voice: an NVIDIA GPU is strongly recommended. Without one, use the `nano` voice model and the `small` or `base` Whisper model; expect a couple of seconds of delay.
- Roughly 6 GB of disk for models, downloaded automatically on first start
- A language model: [Ollama](https://ollama.com) running locally, any other OpenAI-compatible server, or a Claude API key

## 1. Create the Discord bot

1. Go to the [Discord Developer Portal](https://discord.com/developers/applications), click **New Application**, give it a name.
2. Open **Bot**, click **Reset Token**, copy the token. Keep it secret.
3. On the same page, turn on **Server Members Intent**.
4. Open **OAuth2 → URL Generator**. Tick the scopes `bot` and `applications.commands`, then the permissions **View Channels**, **Send Messages**, **Connect**, **Speak** and **Use Voice Activity**.
5. Open the generated URL and add the bot to your server.

## 2. Install

### NixOS / Nix

```sh
cd discord-voice-ai
cp config.example.toml config.toml   # then set llm.model at least
cp .env.example .env                 # then paste your token
nix develop                          # first run creates .venv and installs everything
python -m voicebot
```

### Anything else

```sh
python3.12 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
cp config.example.toml config.toml && cp .env.example .env   # edit both
set -a && source .env && set +a
python -m voicebot
```

If the bot says libopus is missing, set `OPUS_LIB` to the full path of `libopus.so.0`.

### Pick a language model

Local with Ollama (private, free):

```sh
ollama pull <model>          # any chat model your hardware handles
```

then in `config.toml` set `model = "<model>"` under `[llm]`. Smaller models answer faster, and speed matters more in voice than in text.

With the Claude API instead: set `backend = "anthropic"`, `model = "claude-haiku-5-5"` (fast) and put `ANTHROPIC_API_KEY=...` in `.env`.

### First start

The first start downloads the Whisper and Chatterbox models, which takes a few minutes. The bot comes online right away but `/join` waits until the log says `Models loaded, ready to talk`.

Slash commands can take a while to appear the first time. Put your server ID in `dev_guild_id` to make them show up instantly.

## 3. Use it

1. Join a voice channel and run `/join` in a text channel.
2. Everyone who wants to talk to it runs `/optin`.
3. Say something with its name in it: "Echo, what's the weirdest animal you know?"
4. Keep chatting. For 20 seconds after it answers you, you don't need to say the name again.

### Commands

| Command | What it does |
| --- | --- |
| `/join`, `/leave` | Join your voice channel, or leave |
| `/optin`, `/optout` | Allow or stop the bot listening to you |
| `/say <text>` | Make it say something |
| `/forget` | Clear its conversation memory |
| `/mode` | Wake word or answer everything * |
| `/voice list` | Show voices |
| `/voice use <name>` | Switch voice * |
| `/voice add <name> <file>` | Clone a voice from an audio clip * |
| `/voice remove <name>` | Delete a voice * |
| `/voice preview [text]` | Hear the current voice and settings |
| `/tune show` | Show the voice settings |
| `/tune set <setting> <value>` | Change one * |
| `/tune reset` | Back to defaults * |
| `/persona show`, `/persona set`, `/persona reset` | View or change the personality * |

\* needs the **Manage Server** permission

### Voice settings

| Setting | Range | Effect |
| --- | --- | --- |
| speed | 0.5 to 2.0 | Speaking rate without changing pitch |
| pitch | 0.5 to 2.0 | Higher or deeper, without changing speed |
| volume | 0.0 to 2.0 | Loudness |
| exaggeration | 0.0 to 2.0 | Emotional intensity. 0.5 is neutral, 0.7 and up gets dramatic |
| cfg_weight | 0.0 to 1.0 | Pacing. Lower is slower and more deliberate; try 0.3 with high exaggeration |
| temperature | 0.1 to 1.5 | How varied the delivery is between lines |

`exaggeration` and `cfg_weight` only work with the `standard` and `multilingual` voice models. `turbo` and `nano` are faster but skip them; in exchange they understand tags like `[laugh]` or `[sigh]` if your persona tells the LLM to use them.

### Making a good custom voice

- 10 to 30 seconds of one person speaking naturally, no music, no background noise, no reverb. Turbo and nano need at least 5 seconds.
- Any format works (wav, mp3, ogg, m4a, a Discord voice message download).
- The tone of the sample carries over: a calm sample makes a calm voice, an energetic one an energetic voice.
- Only clone voices you have permission to use, like your own.

Voices are stored in `voices/` as plain WAV files, so you can also drop files in there directly.

### Choosing the voice model

| `tts.model` | Languages | Hardware | Notes |
| --- | --- | --- | --- |
| `nano` | English | CPU is fine | Default. Fastest, a little less natural |
| `turbo` | English | GPU | Best balance of speed and quality for conversation |
| `standard` | English | GPU | Slower, supports exaggeration and cfg_weight |
| `multilingual` | 23 incl. German | GPU | Set `tts.language`, e.g. `"de"` |

Chatterbox adds an inaudible watermark to everything it generates, which marks the audio as AI-made.

## Running it as a NixOS service

`nix/module.nix` runs the bot as its own system user with state in `/var/lib/discord-voice-ai`. It builds the Python environment on first start (and again whenever `requirements.txt` changes), so there is nothing to set up by hand.

```nix
imports = [ ./path/to/discord-voice-ai/nix/module.nix ];   # or inputs.discord-voice-ai.nixosModules.default

services.discord-voice-ai = {
  enable = true;
  environmentFile = "/run/secrets/discord-voice-ai-env";   # DISCORD_TOKEN=...
  settings = {
    llm = { base_url = "http://127.0.0.1:11434/v1"; model = "llama3.2:3b"; };
    tts.model = "nano";
  };
};
```

`settings` takes the same structure as `config.example.toml`.

## Tuning tips

- **It cuts you off mid-sentence:** raise `audio.silence_timeout_s` to 1.2.
- **It reacts to background noise or keyboard:** raise `audio.energy_threshold` (try 600), or use push to talk in Discord.
- **It misses quiet speakers:** lower `audio.energy_threshold`.
- **Too slow to answer:** use a smaller LLM, `stt.model = "base"`, and `tts.model = "turbo"` on a GPU.
- **It gets interrupted by laughter:** raise `audio.barge_in_s`, or set it to 0.
- **Whisper mishears its name:** add the misheard spellings to `wake_words`.
- **Set `LOG_LEVEL=DEBUG`** to see everything it hears, including what it ignored.

## How it is put together

| File | Role |
| --- | --- |
| `voicebot/bot.py` | Slash commands, model loading |
| `voicebot/session.py` | One conversation: listen, transcribe, think, speak, interrupt |
| `voicebot/vad.py` | Splits incoming audio into sentences per speaker |
| `voicebot/stt.py` | faster-whisper speech to text |
| `voicebot/llm.py` | OpenAI-compatible and Claude API clients |
| `voicebot/tts.py` | Chatterbox voice cloning and speed/pitch/volume shaping |
| `voicebot/playback.py` | Streams sentences into Discord as they are ready |
| `voicebot/settings.py` | Per-server settings saved in `data/` |

Run the tests with `python -m unittest discover tests` inside the venv.

## Known limits

- Voice receiving relies on a community fork of `discord-ext-voice-recv` that adds DAVE decryption, pinned to a tested commit in `requirements.txt`. If Discord changes its voice protocol again, that fork is the part to update.
- One voice channel per server at a time.
- Several people talking at once works, but each sentence is answered in turn.
