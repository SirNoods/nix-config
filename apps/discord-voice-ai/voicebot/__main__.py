"""Run with: python -m voicebot [path/to/config.toml]"""

import logging
import os
import sys

from .bot import VoiceBot, load_opus
from .config import load_config


def main() -> None:
    logging.basicConfig(
        level=os.environ.get("LOG_LEVEL", "INFO"),
        format="%(asctime)s %(levelname)-7s %(name)s: %(message)s",
    )
    token = os.environ.get("DISCORD_TOKEN")
    if not token:
        sys.exit("Set DISCORD_TOKEN (see README).")
    cfg = load_config(sys.argv[1] if len(sys.argv) > 1 else os.environ.get("VOICEBOT_CONFIG", "config.toml"))
    if not cfg["llm"]["model"]:
        sys.exit("Set llm.model in config.toml (see config.example.toml).")
    load_opus()
    VoiceBot(cfg).run(token, log_handler=None)


if __name__ == "__main__":
    main()
