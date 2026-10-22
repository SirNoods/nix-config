{ config, ... }:
{
  imports = [ ../../apps/discord-voice-ai/nix/module.nix ];

  sops.secrets."discord-voice-ai-env" = {
    owner = "discord-voice-ai";
    restartUnits = [ "discord-voice-ai.service" ];
  };

  services.discord-voice-ai = {
    enable = true;
    environmentFile = config.sops.secrets."discord-voice-ai-env".path;
    settings = {
      bot = {
        name = "Echo";
        wake_words = [ "echo" ];
        dev_guild_id = 0; # your server ID
      };
      llm = {
        backend = "openai";
        base_url = "http://127.0.0.1:11434/v1";
        model = "llama3.2:3b";
      };
      stt.model = "base";
      tts.model = "nano";
    };
  };

  services.ollama = {
    enable = true;
    loadModels = [ "llama3.2:3b" ];
  };
}