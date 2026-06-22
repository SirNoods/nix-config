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

    normalizeMic = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Normalize mic audio using ffmpeg loudnorm.";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [
      (pkgs.writeShellScriptBin "obs-split" ''
        set -euo pipefail

        RAW_DIR=${lib.escapeShellArg cfg.rawDir}
        PROJECTS_DIR=${lib.escapeShellArg cfg.projectsDir}

        PROJECT="''${1:-}"
        MODE="''${2:-}"
        VALUE="''${3:-}"

        if [ -z "$PROJECT" ]; then
          echo "Usage:"
          echo "  obs-split <project_name>"
          echo "  obs-split <project_name> <input_file>"
          echo "  obs-split <project_name> --last <count>"
          exit 1
        fi

        OUT_DIR="$PROJECTS_DIR/$PROJECT"
        ${pkgs.coreutils}/bin/mkdir -p "$OUT_DIR"

        get_latest_files() {
          local count="$1"

          ${pkgs.findutils}/bin/find "$RAW_DIR" \
            -maxdepth 1 \
            -type f \
            -name '*.mkv' \
            -printf '%T@ %p\n' \
            | ${pkgs.coreutils}/bin/sort -n \
            | ${pkgs.coreutils}/bin/tail -n "$count" \
            | ${pkgs.gawk}/bin/awk '{ $1=""; sub(/^ /, ""); print }'
        }

        get_next_index() {
          local highest=0
          local file
          local filename
          local number

          shopt -s nullglob

          for file in \
            "$OUT_DIR/${cfg.videoName}_"* \
            "$OUT_DIR/${cfg.micName}_"* \
            "$OUT_DIR/${cfg.gameName}_"*
          do
            filename="''${file##*/}"

            if [[ "$filename" =~ _([0-9]+)\.[^.]+$ ]]; then
              number="''${BASH_REMATCH[1]}"
              number=$((10#$number))

              if (( number > highest )); then
                highest="$number"
              fi
            fi
          done

          shopt -u nullglob

          echo $((highest + 1))
        }

        process_file() {
          local input="$1"
          local index="$2"
          local suffix
          local ext
          local video_out
          local mic_out
          local game_out

          if [ -z "''${input:-}" ] || [ ! -f "$input" ]; then
            echo "Input file not found: $input"
            exit 1
          fi

          suffix="_$(${pkgs.coreutils}/bin/printf '%02d' "$index")"
          ext="''${input##*.}"

          video_out="$OUT_DIR/${cfg.videoName}''${suffix}.''${ext}"
          mic_out="$OUT_DIR/${cfg.micName}''${suffix}.wav"
          game_out="$OUT_DIR/${cfg.gameName}''${suffix}.wav"

          echo "Processing: $input"
          echo "Sequence:   $index"

          ${pkgs.ffmpeg}/bin/ffmpeg \
            -n \
            -i "$input" \
            -map 0:v:0 \
            -c:v copy \
            "$video_out" \
            -map 0:a:1 \
            -af ${
              lib.escapeShellArg (
                if cfg.normalizeMic then
                  "loudnorm=I=-16:TP=-1.5:LRA=11"
                else
                  "anull"
              )
            } \
            -c:a pcm_s16le \
            "$mic_out" \
            -map 0:a:2 \
            -c:a pcm_s16le \
            "$game_out"

          echo "Done:"
          echo "  $video_out"
          echo "  $mic_out"
          echo "  $game_out"
        }

        echo "Output: $OUT_DIR"

        NEXT_INDEX="$(get_next_index)"

        if [ "$MODE" = "--last" ]; then
          COUNT="''${VALUE:-5}"

          if ! [[ "$COUNT" =~ ^[0-9]+$ ]] || [ "$COUNT" -lt 1 ]; then
            echo "Invalid count: $COUNT"
            exit 1
          fi

          mapfile -t INPUTS < <(get_latest_files "$COUNT")

          if [ "''${#INPUTS[@]}" -eq 0 ]; then
            echo "No .mkv files found in $RAW_DIR"
            exit 1
          fi

          index="$NEXT_INDEX"

          for input in "''${INPUTS[@]}"; do
            process_file "$input" "$index"
            index=$((index + 1))
          done
        else
          INPUT="$MODE"

          if [ -z "$INPUT" ]; then
            INPUT="$(get_latest_files 1)"
          elif [[ "$INPUT" != /* ]]; then
            INPUT="$RAW_DIR/$INPUT"
          fi

          process_file "$INPUT" "$NEXT_INDEX"
        fi
      '')
    ];
  };
}