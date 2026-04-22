{ config, lib, pkgs, ... }:

let
  cfg = config.programs.archive;
in
{
  options.programs.archive = {
    enable = lib.mkEnableOption "Simple archive helper with date prefix";
  };

  config = lib.mkIf cfg.enable {
    home.packages = [
      (pkgs.writeShellScriptBin "archive" ''
        #!${pkgs.bash}/bin/bash
        set -euo pipefail

        TARGET="''${1:-}"

        if [ -z "$TARGET" ]; then
          echo "Usage: archive <folder>"
          exit 1
        fi

        if [ ! -e "$TARGET" ]; then
          echo "Target does not exist: $TARGET"
          exit 1
        fi

        DATE="$(${pkgs.coreutils}/bin/date +%y%m%d)"
        NAME="$(basename "$TARGET")"
        PARENT="$(dirname "$TARGET")"

        OUTPUT="''${DATE}_''${NAME}.tar.gz"

        echo "Creating archive: $OUTPUT"

        cd "$PARENT"
        ${pkgs.gnutar}/bin/tar -czvf "$OLDPWD/$OUTPUT" "$NAME"

        echo "Done."
      '')
    ];
  };
}