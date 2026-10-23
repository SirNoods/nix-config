{ config, lib, pkgs, ... }:

let
  cfg = config.programs.obs-split;

  ffmpeg = "${pkgs.ffmpeg}/bin/ffmpeg";
  ffprobe = "${pkgs.ffmpeg}/bin/ffprobe";
  coreutils = "${pkgs.coreutils}/bin";

  safeName = lib.types.strMatching "[A-Za-z0-9_-]+";

  trackType = lib.types.submodule {
    options = {
      track = lib.mkOption {
        type = lib.types.ints.positive;
        description = "OBS track number, 1-based, exactly as OBS numbers it.";
      };

      name = lib.mkOption {
        type = safeName;
        description = "Base name for the extracted WAV file.";
      };

      normalize = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Run ffmpeg loudnorm on this track.";
      };

      mute = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Start this track's channel muted in the Blender template (for reference tracks like a full mix).";
      };
    };
  };

  # ---------------------------------------------------------------------------
  # Blender project template
  # ---------------------------------------------------------------------------
  tcfg = cfg.blenderTemplate;

  capitalize = s: lib.toUpper (builtins.substring 0 1 s) + builtins.substring 1 (builtins.stringLength s) s;

  # Bottom to top: music, SFX, muted reference tracks, live tracks, then video
  # and everything that sits on top of it.
  defaultChannels =
    let
      tracks = cfg.layouts.${cfg.defaultLayout} or [ ];
      asChannel = t: { name = capitalize t.name; inherit (t) mute; };
    in
    map (i: { name = "Music ${toString i}"; mute = false; }) (lib.range 1 tcfg.musicChannels)
    ++ [ { name = "SFX"; mute = false; } ]
    ++ map asChannel (lib.filter (t: t.mute) tracks)
    ++ map asChannel (lib.filter (t: !t.mute) tracks)
    ++ map (name: { inherit name; mute = false; }) [
      "Video"
      "Overlays"
      "Titles"
      "Credits"
    ];

  templateConfig = pkgs.writeText "video-template.json" (
    builtins.toJSON {
      inherit (tcfg)
        width
        height
        fps
        channels
        ;
    }
  );

  videoTemplate = pkgs.runCommand "video-template.blend" { nativeBuildInputs = [ tcfg.package ]; } ''
    export HOME="$TMPDIR"

    blender \
      --background \
      --factory-startup \
      -noaudio \
      --python-exit-code 1 \
      --python ${./video-template.py} \
      -- ${templateConfig} "$out"

    test -s "$out"
  '';

  # Adds the asset folders to Blender's file browser sidebar. Blender rewrites
  # bookmarks.txt itself (recent folders), so it can't be a read-only
  # home-manager symlink; instead each path is inserted once if missing.
  bookmarkAssets = pkgs.writeShellScript "blender-bookmark-video-assets" ''
    set -euo pipefail

    config_dir="$HOME/.config/blender/${lib.versions.majorMinor tcfg.package.version}/config"
    file="$config_dir/bookmarks.txt"

    ${coreutils}/mkdir -p "$config_dir"

    if [ ! -f "$file" ] || ! ${pkgs.gnugrep}/bin/grep -qxF '[Bookmarks]' "$file"; then
      { echo '[Bookmarks]'; [ -f "$file" ] && ${coreutils}/cat "$file"; } > "$file.tmp"
      ${coreutils}/mv "$file.tmp" "$file"
    fi

    # Each path is inserted directly under the header, so go back to front
    # to end up in the configured order.
    for path in ${
      lib.concatMapStringsSep " " (d: lib.escapeShellArg "${cfg.assetsDir}/${d}/") (lib.reverseList cfg.assetFolders)
    }; do
      # Only look inside the [Bookmarks] section, not [Recent].
      if ${pkgs.gawk}/bin/awk -v p="$path" '
        /^\[/ { section = $0; next }
        section == "[Bookmarks]" && $0 == p { found = 1 }
        END { exit !found }
      ' "$file"; then
        continue
      fi

      ${pkgs.gawk}/bin/awk -v p="$path" '
        { print }
        $0 == "[Bookmarks]" { print p }
      ' "$file" > "$file.tmp"
      ${coreutils}/mv "$file.tmp" "$file"
    done
  '';

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

  # ---------------------------------------------------------------------------
  # obs-split: extract per-track WAVs (and optionally the video) from a recording
  # ---------------------------------------------------------------------------
  obsSplit = pkgs.writeShellScriptBin "obs-split" ''
    set -euo pipefail

    RAW_DIR=${lib.escapeShellArg cfg.rawDir}
    RAW_EXT=${lib.escapeShellArg cfg.rawExtension}
    PROJECTS_DIR=${lib.escapeShellArg cfg.projectsDir}
    VIDEO_NAME=${lib.escapeShellArg cfg.videoName}
    PREFIXES=(${lib.concatMapStringsSep " " lib.escapeShellArg allPrefixes})

    # loudnorm upsamples to 192 kHz internally, so each normalized track is
    # resampled back to its own source rate afterwards (see process_file).
    LOUDNORM="loudnorm=I=-16:TP=-1.5:LRA=11"

    usage() {
      echo "Usage:"
      echo "  obs-split <project> [options] [input_file]"
      echo ""
      echo "With no input file, the newest .$RAW_EXT in the raw dir is used."
      echo ""
      echo "Options:"
      echo "  --last <count>    Process the newest <count> recordings (default 5)"
      echo "  --layout <name>   Track layout to use (default: ${cfg.defaultLayout})"
      echo "  --davinci         Transcode video to DNxHR for DaVinci Resolve"
      echo "  --audio-only      Only extract the WAVs, skip the video output"
      echo "  --index <n>       Start numbering at <n> instead of auto-detecting"
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
    AUDIO_ONLY=false
    LAYOUT=${lib.escapeShellArg cfg.defaultLayout}
    LAST=""
    INPUT=""
    START_INDEX=""

    while [ "$#" -gt 0 ]; do
      case "$1" in
        --davinci)
          DAVINCI=true
          shift
          ;;

        --audio-only)
          AUDIO_ONLY=true
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

        --index)
          if ! [[ "''${2:-}" =~ ^[0-9]+$ ]] || [ "$2" -lt 1 ]; then
            echo "--index needs a positive number."
            exit 1
          fi

          START_INDEX="$2"
          shift 2
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

    if [ "$DAVINCI" = true ] && [ "$AUDIO_ONLY" = true ]; then
      echo "--davinci and --audio-only don't make sense together."
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
    ${coreutils}/mkdir -p "$OUT_DIR"

    get_latest_files() {
      local count="$1"

      # OBS file names start with the recording timestamp, so name order is
      # recording order.
      ${pkgs.findutils}/bin/find "$RAW_DIR" \
        -maxdepth 1 \
        -type f \
        -name "*.$RAW_EXT" \
        -printf '%f\n' \
        | ${coreutils}/sort \
        | ${coreutils}/tail -n "$count" \
        | while IFS= read -r name; do echo "$RAW_DIR/$name"; done
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
      local rate
      local out
      local -a ffmpeg_args
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
          | ${coreutils}/wc -l
      )"

      suffix="_$(${coreutils}/printf '%02d' "$index")"
      ext="''${input##*.}"

      ffmpeg_args=(-n -i "$input")
      outputs=()

      if [ "$AUDIO_ONLY" != true ]; then
        if [ "$DAVINCI" = true ]; then
          video_out="$OUT_DIR/$VIDEO_NAME$suffix.mov"
          ffmpeg_args+=(
            -map 0:v:0
            -c:v dnxhd
            -profile:v ${lib.escapeShellArg cfg.davinciProfile}
            -pix_fmt yuv422p
            "$video_out"
          )
        else
          video_out="$OUT_DIR/$VIDEO_NAME$suffix.$ext"
          ffmpeg_args+=(-map 0:v:0 -c:v copy "$video_out")
        fi

        outputs+=("$video_out")
      fi

      for entry in "''${TRACKS[@]}"; do
        IFS=: read -r idx name norm <<< "$entry"

        if (( idx >= audio_count )); then
          echo "Layout '$LAYOUT' wants OBS track $((idx + 1)),"
          echo "but $input only has $audio_count audio tracks."
          exit 1
        fi

        out="$OUT_DIR/$name$suffix.wav"

        ffmpeg_args+=(-map "0:a:$idx")

        if [ "$norm" = 1 ]; then
          rate="$(
            ${ffprobe} -v error \
              -select_streams "a:$idx" \
              -show_entries stream=sample_rate \
              -of csv=p=0 \
              "$input"
          )"

          ffmpeg_args+=(-af "$LOUDNORM,aresample=''${rate:-48000}")
        fi

        # -rf64 auto switches to RF64 only if the file would pass the
        # 4 GB WAV limit, so normal-length recordings stay plain WAV.
        ffmpeg_args+=(-c:a pcm_s16le -rf64 auto "$out")
        outputs+=("$out")
      done

      echo "Processing: $input"
      echo "Sequence:   $index"
      echo "Layout:     $LAYOUT ($audio_count audio tracks in file)"

      if [ "$AUDIO_ONLY" = true ]; then
        echo "Mode:       Audio only"
      elif [ "$DAVINCI" = true ]; then
        echo "Mode:       DaVinci Resolve (DNxHR)"
      else
        echo "Mode:       Standard"
      fi

      ${ffmpeg} "''${ffmpeg_args[@]}"

      echo "Done:"
      ${coreutils}/printf '  %s\n' "''${outputs[@]}"
    }

    echo "Output: $OUT_DIR"

    if [ -n "$START_INDEX" ]; then
      NEXT_INDEX="$START_INDEX"
    else
      NEXT_INDEX="$(get_next_index)"
    fi

    if [ -n "$LAST" ]; then
      mapfile -t INPUTS < <(get_latest_files "$LAST")

      if [ "''${#INPUTS[@]}" -eq 0 ]; then
        echo "No .$RAW_EXT files found in $RAW_DIR"
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
          echo "No .$RAW_EXT files found in $RAW_DIR"
          exit 1
        fi
      elif [ ! -f "$INPUT" ] && [[ "$INPUT" != /* ]]; then
        # Not a path relative to the current directory, so treat it
        # as a file name inside the raw recordings directory.
        INPUT="$RAW_DIR/$INPUT"
      fi

      process_file "$INPUT" "$NEXT_INDEX"
    fi
  '';

  # ---------------------------------------------------------------------------
  # obs-pull: move recordings out of raw/ into a project, numbered in order
  # ---------------------------------------------------------------------------
  obsPull = pkgs.writeShellScriptBin "obs-pull" ''
    set -euo pipefail

    RAW_DIR=${lib.escapeShellArg cfg.rawDir}
    RAW_EXT=${lib.escapeShellArg cfg.rawExtension}
    PROJECTS_DIR=${lib.escapeShellArg cfg.projectsDir}
    FOOTAGE_SUBDIR=${lib.escapeShellArg cfg.footageDir}
    PREFIX=${lib.escapeShellArg cfg.footagePrefix}
    TEMPLATE=${lib.escapeShellArg (if tcfg.enable then "${videoTemplate}" else "")}

    usage() {
      echo "Usage:"
      echo "  obs-pull <project> [options]"
      echo ""
      echo "Moves recordings from the raw dir into <project>/$FOOTAGE_SUBDIR,"
      echo "numbered in recording order ($PREFIX""_01.$RAW_EXT, $PREFIX""_02.$RAW_EXT, ...)."
      echo "Numbering continues from whatever the project already has."
      echo ""
      echo "With no --last, an interactive picker opens (Tab selects, Enter confirms)."
      echo ""
      echo "Options:"
      echo "  --last <count>    Pull the newest <count> recordings, no picker"
      echo "  --split           Also run obs-split on each pulled recording"
      echo "  --layout <name>   Track layout for --split (default: ${cfg.defaultLayout})"
      echo "  --davinci         With --split, also write a DNxHR video for DaVinci"
      echo "  --init            Only set up the project folder (and .blend), pull nothing"
      echo "  -h, --help        Show this help"
    }

    # Copies the Blender template in as <project>.blend, unless one exists.
    ensure_blend() {
      local blend="$PROJECTS_DIR/$PROJECT/$PROJECT.blend"

      if [ -z "$TEMPLATE" ] || [ -e "$blend" ]; then
        return
      fi

      ${coreutils}/mkdir -p "$PROJECTS_DIR/$PROJECT"
      ${coreutils}/install -m 644 "$TEMPLATE" "$blend"
      echo "Created $blend from the video template."
    }

    PROJECT="''${1:-}"

    if [ -z "$PROJECT" ] || [[ "$PROJECT" == -* ]]; then
      usage
      exit 1
    fi

    shift

    LAST=""
    SPLIT=false
    DAVINCI=false
    INIT=false
    SPLIT_ARGS=()

    while [ "$#" -gt 0 ]; do
      case "$1" in
        --last)
          if ! [[ "''${2:-}" =~ ^[0-9]+$ ]] || [ "$2" -lt 1 ]; then
            echo "--last needs a positive number."
            exit 1
          fi

          LAST="$2"
          shift 2
          ;;

        --split)
          SPLIT=true
          shift
          ;;

        --layout)
          if [ -z "''${2:-}" ]; then
            echo "--layout needs a name."
            exit 1
          fi

          SPLIT_ARGS+=(--layout "$2")
          shift 2
          ;;

        --davinci)
          DAVINCI=true
          shift
          ;;

        --init)
          INIT=true
          shift
          ;;

        -h|--help)
          usage
          exit 0
          ;;

        *)
          echo "Unknown argument: $1"
          exit 1
          ;;
      esac
    done

    if [ "$SPLIT" != true ] && { [ "$DAVINCI" = true ] || [ "''${#SPLIT_ARGS[@]}" -gt 0 ]; }; then
      echo "--layout and --davinci only apply together with --split."
      exit 1
    fi

    FOOTAGE_DIR="$PROJECTS_DIR/$PROJECT/$FOOTAGE_SUBDIR"
    MANIFEST="$FOOTAGE_DIR/manifest.tsv"

    if [ "$INIT" = true ]; then
      if [ -n "$LAST" ] || [ "$SPLIT" = true ]; then
        echo "--init only sets up the project; it can't be combined with --last or --split."
        exit 1
      fi

      ${coreutils}/mkdir -p "$FOOTAGE_DIR"
      ensure_blend
      echo "Project ready: $PROJECTS_DIR/$PROJECT"
      exit 0
    fi

    # OBS file names start with the recording timestamp, so sorting by name
    # gives recording order. File mtimes can't be trusted after a remux.
    mapfile -t ALL < <(
      ${pkgs.findutils}/bin/find "$RAW_DIR" \
        -maxdepth 1 \
        -type f \
        -name "*.$RAW_EXT" \
        -printf '%f\n' \
        | ${coreutils}/sort
    )

    if [ "''${#ALL[@]}" -eq 0 ]; then
      echo "No .$RAW_EXT recordings in $RAW_DIR"
      exit 0
    fi

    describe() {
      local file="$1"
      local duration
      local size

      duration="$(
        ${ffprobe} -v error \
          -show_entries format=duration \
          -of default=nw=1:nk=1 \
          "$RAW_DIR/$file" \
          | ${pkgs.gawk}/bin/awk '{ s = int($1); printf "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60 }'
      )" || duration="?"

      size="$(${coreutils}/du -h "$RAW_DIR/$file" | ${coreutils}/cut -f1)"

      ${coreutils}/printf '%s\t%s\t%s\n' "$file" "''${duration:-?}" "$size"
    }

    if [ -n "$LAST" ]; then
      mapfile -t PICKED < <(${coreutils}/printf '%s\n' "''${ALL[@]}" | ${coreutils}/tail -n "$LAST")
    else
      mapfile -t PICKED < <(
        for file in "''${ALL[@]}"; do
          describe "$file"
        done \
          | ${pkgs.fzf}/bin/fzf \
              --multi \
              --tac \
              --delimiter '\t' \
              --header "Tab: select   Enter: pull into $PROJECT   Esc: cancel" \
          | ${coreutils}/cut -f1 \
          | ${coreutils}/sort
      )
    fi

    if [ "''${#PICKED[@]}" -eq 0 ]; then
      echo "Nothing selected."
      exit 0
    fi

    ${coreutils}/mkdir -p "$FOOTAGE_DIR"

    if [ ! -f "$MANIFEST" ]; then
      ${coreutils}/printf 'file\toriginal\n' > "$MANIFEST"
    fi

    next_index() {
      local highest=0
      local file
      local filename
      local number
      local re="^''${PREFIX}_([0-9]+)\."

      shopt -s nullglob

      for file in "$FOOTAGE_DIR/''${PREFIX}_"*; do
        filename="''${file##*/}"

        if [[ "$filename" =~ $re ]]; then
          number=$((10#''${BASH_REMATCH[1]}))

          if (( number > highest )); then
            highest="$number"
          fi
        fi
      done

      shopt -u nullglob

      echo $((highest + 1))
    }

    index="$(next_index)"
    PULLED_PATHS=()
    PULLED_INDEXES=()

    echo "Pulling into $FOOTAGE_DIR:"

    for file in "''${PICKED[@]}"; do
      dest_name="''${PREFIX}_$(${coreutils}/printf '%02d' "$index").$RAW_EXT"
      dest="$FOOTAGE_DIR/$dest_name"

      if [ -e "$dest" ]; then
        echo "Refusing to overwrite existing $dest"
        exit 1
      fi

      ${coreutils}/mv -n "$RAW_DIR/$file" "$dest"
      ${coreutils}/printf '%s\t%s\n' "$dest_name" "$file" >> "$MANIFEST"

      echo "  $file -> $dest_name"

      PULLED_PATHS+=("$dest")
      PULLED_INDEXES+=("$index")
      index=$((index + 1))
    done

    ensure_blend

    if [ "$SPLIT" = true ]; then
      for i in "''${!PULLED_PATHS[@]}"; do
        args=(--index "''${PULLED_INDEXES[$i]}")

        if [ "$DAVINCI" = true ]; then
          args+=(--davinci)
        else
          # The pulled file already is the video, so don't copy it again.
          args+=(--audio-only)
        fi

        echo ""
        ${obsSplit}/bin/obs-split "$PROJECT" "''${args[@]}" "''${SPLIT_ARGS[@]}" "''${PULLED_PATHS[$i]}"
      done
    fi
  '';
in
{
  options.programs.obs-split = {
    enable = lib.mkEnableOption "OBS recording helpers (obs-pull and obs-split) for Blender/DaVinci workflows";

    rawDir = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/3_Resources/Recordings/raw";
      description = "Directory containing raw OBS recordings.";
    };

    rawExtension = lib.mkOption {
      type = lib.types.strMatching "[A-Za-z0-9]+";
      default = "mp4";
      description = "Extension of recordings to pick up from rawDir (mp4 for OBS auto-remux, mkv otherwise).";
    };

    projectsDir = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/1_Projects";
      description = "Base directory for project output folders.";
    };

    footageDir = lib.mkOption {
      type = safeName;
      default = "footage";
      description = "Subfolder of a project that obs-pull moves recordings into.";
    };

    footagePrefix = lib.mkOption {
      type = safeName;
      default = "rec";
      description = "File name prefix for pulled recordings (rec_01.mp4, rec_02.mp4, ...).";
    };

    videoName = lib.mkOption {
      type = safeName;
      default = "video";
      description = "Base name for the copied/transcoded video file written by obs-split.";
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

    assetsDir = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/3_Resources/VideoAssets";
      description = "Folder for reusable video assets (sound effects, music, overlays, transitions).";
    };

    assetFolders = lib.mkOption {
      type = lib.types.listOf safeName;
      default = [
        "sfx"
        "music"
        "overlays"
        "transitions"
      ];
      description = "Subfolders created in assetsDir; each becomes a bookmark in Blender's file browser when the template is enabled.";
    };

    blenderTemplate = {
      enable = lib.mkEnableOption "a generated Blender video template that obs-pull copies into new projects";

      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.blender;
        defaultText = lib.literalExpression "pkgs.blender";
        description = "Blender used to build the template. Should match the Blender you edit with.";
      };

      width = lib.mkOption {
        type = lib.types.ints.positive;
        default = 1920;
        description = "Output width in pixels.";
      };

      height = lib.mkOption {
        type = lib.types.ints.positive;
        default = 1080;
        description = "Output height in pixels.";
      };

      fps = lib.mkOption {
        type = lib.types.ints.positive;
        default = 60;
        description = "Project frame rate. Match your OBS recording frame rate.";
      };

      musicChannels = lib.mkOption {
        type = lib.types.ints.positive;
        default = 4;
        description = "Number of music channels kept free at the bottom of the timeline.";
      };

      channels = lib.mkOption {
        type = lib.types.listOf (
          lib.types.submodule {
            options = {
              name = lib.mkOption { type = lib.types.str; };
              mute = lib.mkOption {
                type = lib.types.bool;
                default = false;
              };
            };
          }
        );
        default = defaultChannels;
        defaultText = lib.literalMD ''
          Music channels, SFX, the default layout's audio tracks (muted ones
          first), then Video, Overlays, Titles and Credits.
        '';
        description = "Sequencer channels from the bottom (channel 1) upwards. Overrides the generated layout entirely.";
      };
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
      ) cfg.layouts
      ++ [
        {
          assertion = lib.length tcfg.channels <= 128;
          message = "programs.obs-split.blenderTemplate.channels has more than Blender's 128 channels.";
        }
      ];

    home.packages = [
      obsSplit
      obsPull
    ];

    home.activation.obsSplitVideoAssets = lib.hm.dag.entryAfter [ "writeBoundary" ] (
      ''
        run ${coreutils}/mkdir -p ${
          lib.concatMapStringsSep " " (d: lib.escapeShellArg "${cfg.assetsDir}/${d}") cfg.assetFolders
        }
      ''
      + lib.optionalString tcfg.enable ''
        run ${bookmarkAssets}
      ''
    );
  };
}
