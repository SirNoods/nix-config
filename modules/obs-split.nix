{ config, lib, pkgs, ... }:

let
  cfg = config.programs.obs-split;
in
{
  options.programs.obs-split = {
    enable = lib.mkEnableOption "OBS track splitting helper for Blender workflows";

    rawDir = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/3_Resources/Recordings/raw";
      description = "Directory containing raw OBS recordings.";
    };

    projectsDir = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/1_Projects";
      description = "Base directory for project output folders.";
    };

    videoName = lib.mkOption {
      type = lib.types.str;
      default = "video";
      description = "Base name for the copied video file.";
    };

    micName = lib.mkOption {
      type = lib.types.str;
      default = "mic";
      description = "Base name for the extracted mic WAV file.";
    };

    gameName = lib.mkOption {
      type = lib.types.str;
      default = "game";
      description = "Base name for the extracted game WAV file.";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [
      (pkgs.writeShellScriptBin "obs-split" ''
        #!${pkgs.bash}/bin/bash
        set -euo pipefail

        RAW_DIR="${cfg.rawDir}"
        PROJECTS_DIR="${cfg.projectsDir}"

        PROJECT="''${1:-}"
        INPUT="''${2:-}"

        if [ -z "$PROJECT" ]; then
          echo "Usage: obs-split <project_name> [input_file]"
          exit 1
        fi

        if [ -z "$INPUT" ]; then
          INPUT=$(${pkgs.findutils}/bin/find "$RAW_DIR" -maxdepth 1 -type f -name '*.mkv' -printf '%T@ %p\n' \
            | ${pkgs.coreutils}/bin/sort -nr \
            | ${pkgs.coreutils}/bin/head -n1 \
            | ${pkgs.gawk}/bin/awk '{print $2}')
        elif [[ "$INPUT" != /* ]]; then
          INPUT="$RAW_DIR/$INPUT"
        fi

        if [ -z "''${INPUT:-}" ] || [ ! -f "$INPUT" ]; then
          echo "Input file not found: $INPUT"
          exit 1
        fi

        OUT_DIR="$PROJECTS_DIR/$PROJECT"
        ${pkgs.coreutils}/bin/mkdir -p "$OUT_DIR"

        EXT="''${INPUT##*.}"

        echo "Processing: $INPUT"
        echo "Output: $OUT_DIR"

        ${pkgs.ffmpeg}/bin/ffmpeg -i "$INPUT" \
          -map 0:v:0 -c:v copy "$OUT_DIR/${cfg.videoName}.''${EXT}" \
          -map 0:a:1 -c:a pcm_s16le "$OUT_DIR/${cfg.micName}.wav" \
          -map 0:a:2 -c:a pcm_s16le "$OUT_DIR/${cfg.gameName}.wav"

        echo "Done:"
        echo "  $OUT_DIR/${cfg.videoName}.''${EXT}"
        echo "  $OUT_DIR/${cfg.micName}.wav"
        echo "  $OUT_DIR/${cfg.gameName}.wav"
      '')
    ];
  };
}