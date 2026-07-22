{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.archive;
in
{
  options.programs.archive = {
    enable = lib.mkEnableOption "Simple archive helper with date prefix";

    archiveDirectory = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/hdd/4_ARCHIVE";
      description = "Destination used by archive -m.";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [
      (pkgs.writeShellScriptBin "archive" ''
        #!${pkgs.bash}/bin/bash
        set -euo pipefail

        ARCHIVE_DIR=${lib.escapeShellArg cfg.archiveDirectory}
        STATE_DIR="''${XDG_STATE_HOME:-$HOME/.local/state}/archive"

        usage() {
          cat <<EOF
Usage:
  archive <target>
      Create a dated archive in the current directory.

  archive -m <target>
  archive --move <target>
      Create the archive in the background and place it in:
      $ARCHIVE_DIR
EOF
        }

        make_archive() {
          local target="$1"
          local output_dir="$2"
          local background_mode="$3"

          local date
          local name
          local parent
          local output
          local temporary

          date="$(${pkgs.coreutils}/bin/date +%y%m%d)"
          name="$(${pkgs.coreutils}/bin/basename "$target")"
          parent="$(${pkgs.coreutils}/bin/dirname "$target")"

          output="$output_dir/''${date}_''${name}.tar.gz"
          temporary="''${output}.part"

          if [ -e "$output" ] || [ -e "$temporary" ]; then
            echo "Archive already exists or is already being created:"
            echo "  $output"
            exit 1
          fi

          ${pkgs.coreutils}/bin/mkdir -p "$output_dir"

          echo "Creating archive:"
          echo "  Source:      $target"
          echo "  Destination: $output"

          # Create under a temporary name so incomplete archives are obvious.
          ${pkgs.gnutar}/bin/tar \
            -czf "$temporary" \
            -C "$parent" \
            "$name"

          ${pkgs.coreutils}/bin/mv "$temporary" "$output"

          echo "Archive complete:"
          echo "  $output"

          if [ "$background_mode" = "true" ]; then
            echo "Finished at $(${pkgs.coreutils}/bin/date)"
          fi
        }

        run_background() {
          local target="$1"
          local date
          local safe_name
          local log_file

          if [ ! -d "$ARCHIVE_DIR" ]; then
            echo "Archive destination is not available:"
            echo "  $ARCHIVE_DIR"
            echo
            echo "Is /mnt/hdd mounted?"
            exit 1
          fi

          if [ ! -w "$ARCHIVE_DIR" ]; then
            echo "Archive destination is not writable:"
            echo "  $ARCHIVE_DIR"
            exit 1
          fi

          ${pkgs.coreutils}/bin/mkdir -p "$STATE_DIR"

          date="$(${pkgs.coreutils}/bin/date +%Y%m%d-%H%M%S)"
          safe_name="$(
            ${pkgs.coreutils}/bin/basename "$target" |
              ${pkgs.gnused}/bin/sed 's/[^A-Za-z0-9._-]/_/g'
          )"
          log_file="$STATE_DIR/''${date}-''${safe_name}.log"

          ${pkgs.coreutils}/bin/nohup \
            "$0" \
            --background-worker \
            "$target" \
            >"$log_file" 2>&1 &

          local pid=$!

          echo "Archive started in the background."
          echo "  PID: $pid"
          echo "  Log: $log_file"
          echo
          echo "Follow its progress with:"
          echo "  tail -f \"$log_file\""
        }

        mode="local"

        case "''${1:-}" in
          -m|--move)
            mode="move"
            shift
            ;;
          --background-worker)
            shift

            target="''${1:-}"

            if [ -z "$target" ]; then
              echo "Internal error: no target supplied to background worker."
              exit 1
            fi

            make_archive "$target" "$ARCHIVE_DIR" true
            exit 0
            ;;
          -h|--help)
            usage
            exit 0
            ;;
        esac

        target="''${1:-}"

        if [ -z "$target" ]; then
          usage
          exit 1
        fi

        if [ ! -e "$target" ]; then
          echo "Target does not exist:"
          echo "  $target"
          exit 1
        fi

        # Resolve it before launching a background process so relative paths
        # remain valid after the calling terminal moves elsewhere or closes.
        target="$(${pkgs.coreutils}/bin/realpath "$target")"

        case "$mode" in
          local)
            make_archive "$target" "$PWD" false
            ;;
          move)
            run_background "$target"
            ;;
        esac
      '')
    ];
  };
}