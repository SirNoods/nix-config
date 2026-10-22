# NixOS module for the Discord voice AI bot.
#
# The bot's Python dependencies (torch, Chatterbox, faster-whisper, discord.py with DAVE)
# are not all in nixpkgs, so the service keeps a virtualenv in its state directory and
# rebuilds it automatically whenever requirements.txt changes. Everything else
# (source, config, user, secrets, system libraries) is declarative.
{ config, lib, pkgs, ... }:

let
  cfg = config.services.discord-voice-ai;
  stateDir = "/var/lib/discord-voice-ai";
  src = lib.cleanSource ../.;
  python = pkgs.python312;
  reqHash = builtins.hashFile "sha256" ../requirements.txt;

  # The prebuilt wheels expect these system libraries. /run/opengl-driver/lib is
  # where NixOS puts the GPU driver (harmless if there is no GPU).
  runtimeLibs = with pkgs; [ stdenv.cc.cc.lib zlib libopus libsndfile ];

  settingsFormat = pkgs.formats.toml { };
  configFile = settingsFormat.generate "discord-voice-ai.toml" (lib.recursiveUpdate {
    bot = {
      data_dir = "${stateDir}/data";
      voices_dir = "${stateDir}/voices";
    };
  } cfg.settings);

  envSetup = ''
    export OPUS_LIB=${pkgs.libopus}/lib/libopus.so.0
    export LD_LIBRARY_PATH=${lib.makeLibraryPath runtimeLibs}:/run/opengl-driver/lib
    for d in ${stateDir}/venv/lib/python3.*/site-packages/nvidia/*/lib; do
      [ -d "$d" ] && export LD_LIBRARY_PATH="$d:$LD_LIBRARY_PATH"
    done
  '';

  prepare = pkgs.writeShellScript "discord-voice-ai-prepare" ''
    set -eu
    cd ${stateDir}
    mkdir -p data voices
    if [ "$(cat venv/.requirements-hash 2>/dev/null || true)" != "${reqHash}" ]; then
      echo "Dependencies changed, (re)building the virtualenv. The first time downloads several GB."
      rm -rf venv
      ${pkgs.uv}/bin/uv venv --python ${python}/bin/python venv
      ${pkgs.uv}/bin/uv pip install --python venv/bin/python -r ${src}/requirements.txt
      echo "${reqHash}" > venv/.requirements-hash
    fi
  '';

  start = pkgs.writeShellScript "discord-voice-ai-start" ''
    ${envSetup}
    export PYTHONPATH=${src}
    cd ${stateDir}
    exec ${stateDir}/venv/bin/python -m voicebot ${configFile}
  '';
in
{
  options.services.discord-voice-ai = {
    enable = lib.mkEnableOption "the Discord voice AI bot";

    settings = lib.mkOption {
      type = settingsFormat.type;
      default = { };
      description = ''
        Bot configuration, same structure as config.example.toml.
        data_dir and voices_dir default to the service's state directory.
      '';
      example = lib.literalExpression ''
        {
          bot.name = "Echo";
          llm = { backend = "openai"; base_url = "http://127.0.0.1:11434/v1"; model = "llama3.2:3b"; };
          tts.model = "nano";
          stt.model = "base";
        }
      '';
    };

    environmentFile = lib.mkOption {
      type = lib.types.path;
      description = "File containing DISCORD_TOKEN=... (and ANTHROPIC_API_KEY=... if used). Use a sops secret.";
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.discord-voice-ai = {
      isSystemUser = true;
      group = "discord-voice-ai";
      home = stateDir;
      extraGroups = [ "video" "render" ]; # GPU access, if there is one
    };
    users.groups.discord-voice-ai = { };

    systemd.services.discord-voice-ai = {
      description = "Discord voice AI bot";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      path = [ pkgs.ffmpeg pkgs.git ];
      environment = {
        HOME = stateDir;
        HF_HOME = "${stateDir}/huggingface";
        UV_CACHE_DIR = "${stateDir}/uv-cache";
      };
      serviceConfig = {
        User = "discord-voice-ai";
        Group = "discord-voice-ai";
        StateDirectory = "discord-voice-ai";
        EnvironmentFile = cfg.environmentFile;
        ExecStartPre = prepare;
        ExecStart = start;
        TimeoutStartSec = "45min"; # first start downloads torch and friends
        Restart = "on-failure";
        RestartSec = 15;

        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [ stateDir ];
      };
    };
  };
}
