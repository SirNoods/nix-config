# Home-manager module: the `epcut` command and the `rough-cut` Claude Code skill.
#
# Put this folder (rough-cut.nix, epcut.py, build_blend.py, SKILL.md) next to
# obs-split.nix, import it, and enable it:
#
#   imports = [ ./rough-cut/rough-cut.nix ];
#   programs.rough-cut.enable = true;
#
# Then in an episode folder, ask Claude Code for a rough cut. Per-project
# overrides go in <project>/epcut.json, e.g. { "vad": { "threshold_db": -50 } }.
{ config, lib, pkgs, ... }:

let
  cfg = config.programs.rough-cut;

  src = pkgs.runCommand "epcut-src" { } ''
    mkdir -p $out
    cp ${./epcut.py} $out/epcut.py
    cp ${./build_blend.py} $out/build_blend.py
  '';

  settings = lib.recursiveUpdate {
    blender = "${cfg.blender}/bin/blender";
    whisper = {
      binary = "whisper-cli";
      model = toString cfg.whisperModel;
    };
  } cfg.settings;

  settingsFile = pkgs.writeText "epcut-defaults.json" (builtins.toJSON settings);

  epcut = pkgs.writeShellApplication {
    name = "epcut";
    runtimeInputs = [
      pkgs.python3
      pkgs.ffmpeg
      cfg.whisperPackage
    ];
    text = ''
      export EPCUT_DEFAULTS=${settingsFile}
      exec python3 ${src}/epcut.py "$@"
    '';
  };
in
{
  options.programs.rough-cut = {
    enable = lib.mkEnableOption "epcut, transcript-driven rough cuts into Blender, plus its Claude Code skill";

    blender = lib.mkOption {
      type = lib.types.package;
      default = config.programs.obs-split.blender or pkgs.blender;
      defaultText = lib.literalExpression "config.programs.obs-split.blender";
      description = "Blender that builds the rough cut. Use the same one you edit with.";
    };

    whisperPackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.whisper-cpp;
      defaultText = lib.literalExpression "pkgs.whisper-cpp";
      description = "whisper.cpp build providing whisper-cli.";
    };

    whisperModel = lib.mkOption {
      type = lib.types.either lib.types.str lib.types.path;
      default = "${config.home.homeDirectory}/.cache/whisper-models/ggml-large-v3-turbo.bin";
      description = ''
        ggml whisper model. To pin it in the store instead:
          pkgs.fetchurl {
            url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin";
            hash = "...";
          }
      '';
    };

    settings = lib.mkOption {
      type = (pkgs.formats.json { }).type;
      default = { };
      example = lib.literalExpression ''
        {
          tracks = { mic = 4; game = 3; discord = 2; };
          channels.discord = "Discord";
          target_minutes = 30;
        }
      '';
      description = "Overrides for epcut's defaults (see DEFAULTS at the top of epcut.py).";
    };

    installSkill = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Install the rough-cut skill to ~/.claude/skills for Claude Code.";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ epcut ];

    home.file.".claude/skills/rough-cut/SKILL.md" = lib.mkIf cfg.installSkill {
      source = ./SKILL.md;
    };
  };
}
