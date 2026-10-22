{ config, lib, pkgs, ... }:

let
  cfg = config.programs.obs-split;

  ffmpeg = "${pkgs.ffmpeg}/bin/ffmpeg";
  ffprobe = "${pkgs.ffmpeg}/bin/ffprobe";

  trackType = lib.types.submodule {
    options = {
      track = lib.mkOption {
        type = lib.types.ints.positive;
        description = "OBS track number, 1-based, exactly as OBS numbers it.";
      };

      name = lib.mkOption {
        type = lib.types.strMatching "[A-Za-z0-9_-]+";
        description = "Base name for the extracted WAV file.";
      };

      normalize = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Run ffmpeg loudnorm on this track.";
      };
    };
  };

  # Every file prefix any layout can produce. Used to find the next sequence
  # number, so numbering stays consistent even if layouts are mixed in a project.
  allPrefixes = lib.unique (
    [ cfg.videoName ]
    ++ lib.concatMap (tracks: map (t: t.name) tracks) (lib.attrValues cfg.layouts)
  );

  # One bash case branch per layout.
  # Each entry is "<ffmpeg audio index>:<name>:<normalize 0|1>".
  layoutCases = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (layout: tracks: ''
      ${lib.escapeShellArg layout})
        TRACKS=(${
          lib.concatMapStringsSep " " (
            t:
            lib.escapeShellArg "${toString (t.track - 1)}:${t.name}:${if t.normalize then "1" else "0"}"
          ) tracks
        })
        ;;
    '') cfg.layouts
  );

  layoutList = lib.concatStringsSep ", " (lib.attrNames cfg.layouts);
in
{
  options.programs.obs-split = {
    enable = lib.mkEnableOption "OBS track splitting helper for Blender/DaVinci workflows";

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
      type = lib.types.strMatching "[A-Za-z0-9_-]+";
      default = "video";
      description = "Base name for the copied/transcoded video file.";
    };

    layouts = lib.mkOption {
      type = lib.types.attrsOf (lib.types.listOf trackType);
      default = {
        classic = [
          { track = 2; name = "mic"; normalize = true; }
          { track = 3; name = "game"; }
        ];
      };
      description = ''
        Named OBS audio track layouts. Setting this replaces the default set
        entirely, so redefine "classic" if you still want it.
      '';
    };

    defaultLayout = lib.mkOption {
      type = lib.types.str;
      default = "classic";
      description = "Layout used when --layout is not given.";
    };

    davinciProfile = lib.mkOption {
      type = lib.types.str;
      default = "dnxhr_sq";
      description = "DNxHR profile used for DaVinci Resolve intermediate video.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions =
      [
        {
          assertion = lib.hasAttr cfg.defaultLayout cfg.layouts;
          message = "programs.obs-split.defaultLayout \"${cfg.defaultLayout}\" is not defined in programs.obs-split.layouts.";
        }
      ]
      ++ lib.mapAttrsToList (layout: tracks: {
        assertion = tracks != [ ];
        message = "programs.obs-split.layouts.${layout} has no tracks.";
      }) cfg.layouts
      ++ lib.mapAttrsToList (
        layout: tracks:
        let
          names = map (t: t.name) tracks;
        in
        {
          assertion = lib.length (lib.unique names) == lib.length names;
          message = "programs.obs-split.layouts.${layout} uses the same name twice.";
        }
      ) cfg.layouts;

    home.packages = [
      (pkgs.writeShellScriptBin "obs-split" ''
        set -euo pipefail

        RAW_DIR=${lib.escapeShellArg cfg.rawDir}
        PROJECTS_DIR=${lib.escapeShellArg cfg.projectsDir}
        VIDEO_NAME=${lib.escapeShellArg cfg.videoName}
        PREFIXES=(${lib.concatMapStringsSep " " lib.escapeShellArg allPrefixes})
        # loudnorm upsamples to 192 kHz internally, so resample back afterwards.
        LOUDNORM="loudnorm=I=-16:TP=-1.5:LRA=11,aresample=48000"

        usage() {
          echo "Usage:"
          echo "  obs-split <project> [options] [input_file]"
          echo ""
          echo "With no input file, the newest recording in the raw dir is used."
          echo ""
          echo "Options:"
          echo "  --last <count>    Process the newest <count> recordings (default 5)"
          echo "  --layout <name>   Track layout to use (default: ${cfg.defaultLayout})"
          echo "  --davinci         Transcode video to DNxHR for DaVinci Resolve"
          echo "  -h, --help        Show this help"
          echo ""
          echo "Layouts: ${layoutList}"
        }

        PROJECT="''${1:-}"

        if [ -z "$PROJECT" ] || [[ "$PROJECT" == -* ]]; then
          usage
          exit 1
        fi

        shift

        DAVINCI=false
        LAYOUT=${lib.escapeShellArg cfg.defaultLayout}
        LAST=""
        INPUT=""

        while [ "$#" -gt 0 ]; do
          case "$1" in
            --davinci)
              DAVINCI=true
              shift
              ;;

            --last)
              if [[ "''${2:-}" =~ ^[0-9]+$ ]]; then
                LAST="$2"
                shift 2
              else
                LAST=5
                shift
              fi
              ;;

            --layout)
              if [ -z "''${2:-}" ]; then
                echo "--layout needs a name. Available: ${layoutList}"
                exit 1
              fi

              LAYOUT="$2"
              shift 2
              ;;

            -h|--help)
              usage
              exit 0
              ;;

            -*)
              echo "Unknown option: $1"
              exit 1
              ;;

            *)
              if [ -n "$INPUT" ]; then
                echo "Unexpected argument: $1"
                exit 1
              fi

              INPUT="$1"
              shift
              ;;
          esac
        done

        if [ -n "$LAST" ] && [ -n "$INPUT" ]; then
          echo "Use either --last or an input file, not both."
          exit 1
        fi

        if [ -n "$LAST" ] && [ "$LAST" -lt 1 ]; then
          echo "Invalid count: $LAST"
          exit 1
        fi

        case "$LAYOUT" in
        ${layoutCases}
          *)
            echo "Unknown layout: $LAYOUT"
            echo "Available: ${layoutList}"
            exit 1
            ;;
        esac

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
          local prefix
          local file
          local filename
          local number

          shopt -s nullglob

          for prefix in "''${PREFIXES[@]}"; do
            for file in "$OUT_DIR/''${prefix}_"*; do
              filename="''${file##*/}"

              if [[ "$filename" =~ _([0-9]+)\.[^.]+$ ]]; then
                number=$((10#''${BASH_REMATCH[1]}))

                if (( number > highest )); then
                  highest="$number"
                fi
              fi
            done
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
          local audio_count
          local entry
          local idx
          local name
          local norm
          local out
          local -a video_args
          local -a audio_args
          local -a outputs

          if [ -z "''${input:-}" ] || [ ! -f "$input" ]; then
            echo "Input file not found: $input"
            exit 1
          fi

          audio_count="$(
            ${ffprobe} -v error \
              -select_streams a \
              -show_entries stream=index \
              -of csv=p=0 \
              "$input" \
              | ${pkgs.coreutils}/bin/wc -l
          )"

          suffix="_$(${pkgs.coreutils}/bin/printf '%02d' "$index")"
          ext="''${input##*.}"

          if [ "$DAVINCI" = true ]; then
            video_out="$OUT_DIR/$VIDEO_NAME$suffix.mov"
            video_args=(
              -c:v dnxhd
              -profile:v ${lib.escapeShellArg cfg.davinciProfile}
              -pix_fmt yuv422p
            )
          else
            video_out="$OUT_DIR/$VIDEO_NAME$suffix.$ext"
            video_args=(-c:v copy)
          fi

          audio_args=()
          outputs=("$video_out")

          for entry in "''${TRACKS[@]}"; do
            IFS=: read -r idx name norm <<< "$entry"

            if (( idx >= audio_count )); then
              echo "Layout '$LAYOUT' wants OBS track $((idx + 1)),"
              echo "but $input only has $audio_count audio tracks."
              exit 1
            fi

            out="$OUT_DIR/$name$suffix.wav"

            audio_args+=(-map "0:a:$idx")

            if [ "$norm" = 1 ]; then
              audio_args+=(-af "$LOUDNORM")
            fi

            # -rf64 auto switches to RF64 only if the file would pass the
            # 4 GB WAV limit, so normal-length recordings stay plain WAV.
            audio_args+=(-c:a pcm_s16le -rf64 auto "$out")
            outputs+=("$out")
          done

          echo "Processing: $input"
          echo "Sequence:   $index"
          echo "Layout:     $LAYOUT ($audio_count audio tracks in file)"

          if [ "$DAVINCI" = true ]; then
            echo "Mode:       DaVinci Resolve (DNxHR)"
          else
            echo "Mode:       Standard"
          fi

          ${ffmpeg} \
            -n \
            -i "$input" \
            -map 0:v:0 \
            "''${video_args[@]}" \
            "$video_out" \
            "''${audio_args[@]}"

          echo "Done:"
          ${pkgs.coreutils}/bin/printf '  %s\n' "''${outputs[@]}"
        }

        echo "Output: $OUT_DIR"

        NEXT_INDEX="$(get_next_index)"

        if [ -n "$LAST" ]; then
          mapfile -t INPUTS < <(get_latest_files "$LAST")

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
          if [ -z "$INPUT" ]; then
            INPUT="$(get_latest_files 1)"

            if [ -z "$INPUT" ]; then
              echo "No .mkv files found in $RAW_DIR"
              exit 1
            fi
          elif [ ! -f "$INPUT" ] && [[ "$INPUT" != /* ]]; then
            # Not a path relative to the current directory, so treat it
            # as a file name inside the raw recordings directory.
            INPUT="$RAW_DIR/$INPUT"
          fi

          process_file "$INPUT" "$NEXT_INDEX"
        fi
      '')
    ];
  };
}
