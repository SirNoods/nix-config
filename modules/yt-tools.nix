{ config, lib, pkgs, ... }:

let
  cfg = config.programs.yt-tools;
in
{
  options.programs.yt-tools = {
    enable = lib.mkEnableOption "yt-dlp helper commands";

    audioDir = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/3_Resources/Audio/fx";
      description = "Directory for downloaded audio files.";
    };

    clipsDir = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/3_Resources/Videos/clips";
      description = "Directory for downloaded video clips.";
    };

    audioFormat = lib.mkOption {
      type = lib.types.str;
      default = "mp3";
      description = "Audio format for ytmp3.";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [
      pkgs.yt-dlp
      pkgs.ffmpeg

      (pkgs.writeShellScriptBin "ytmp3" ''
        #!${pkgs.bash}/bin/bash
        set -euo pipefail

        URL="''${1:-}"

        if [ -z "$URL" ]; then
          echo "Usage: ytmp3 <url>"
          exit 1
        fi

        OUT_DIR="${cfg.audioDir}"
        ${pkgs.coreutils}/bin/mkdir -p "$OUT_DIR"

        ${pkgs.yt-dlp}/bin/yt-dlp \
          -x \
          --audio-format "${cfg.audioFormat}" \
          -o "$OUT_DIR/%(title).150B.%(ext)s" \
          "$URL"
      '')

      (pkgs.writeShellScriptBin "ytclip" ''
        #!${pkgs.bash}/bin/bash
        set -euo pipefail

        URL="''${1:-}"
        START="''${2:-}"
        END="''${3:-}"

        if [ -z "$URL" ]; then
          echo "Usage:"
          echo "  ytclip <url>"
          echo "  ytclip <url> <start> <end>"
          echo ""
          echo "Examples:"
          echo "  ytclip https://youtu.be/example"
          echo "  ytclip https://youtu.be/example 00:01:10 00:01:25"
          exit 1
        fi

        OUT_DIR="${cfg.clipsDir}"
        ${pkgs.coreutils}/bin/mkdir -p "$OUT_DIR"

        if [ -n "$START" ] && [ -n "$END" ]; then
          ${pkgs.yt-dlp}/bin/yt-dlp \
            -f "bv*+ba/b" \
            --download-sections "*$START-$END" \
            --force-keyframes-at-cuts \
            -o "$OUT_DIR/%(title).150B.%(ext)s" \
            "$URL"
        else
          ${pkgs.yt-dlp}/bin/yt-dlp \
            -f "bv*+ba/b" \
            -o "$OUT_DIR/%(title).150B.%(ext)s" \
            "$URL"
        fi
      '')
    ];
  };
}