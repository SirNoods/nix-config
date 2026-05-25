{ config, lib, pkgs, ... }:

let
  cfg = config.goshva.micReverbToggle;
in
{
  options.goshva.micReverbToggle = {
    enable = lib.mkEnableOption "EasyEffects microphone reverb toggle";

    cleanPreset = lib.mkOption {
      type = lib.types.str;
      default = "headsetmic";
      description = "EasyEffects input preset used for the normal microphone sound.";
    };

    reverbPreset = lib.mkOption {
      type = lib.types.str;
      default = "wizardsuperreverb";
      description = "EasyEffects input preset used for wizard reverb.";
    };

    commandName = lib.mkOption {
      type = lib.types.str;
      default = "toggle-mic-reverb";
      description = "Name of the generated toggle command.";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [
      (pkgs.writeShellScriptBin cfg.commandName ''
        set -euo pipefail

        STATE_FILE="$HOME/.cache/mic-reverb-state"

        CLEAN_PRESET="${cfg.cleanPreset}"
        REVERB_PRESET="${cfg.reverbPreset}"

        mkdir -p "$HOME/.cache"

        if [[ -f "$STATE_FILE" ]] && grep -q "reverb" "$STATE_FILE"; then
          ${pkgs.easyeffects}/bin/easyeffects --load-preset "$CLEAN_PRESET"
          echo "clean" > "$STATE_FILE"
          ${pkgs.libnotify}/bin/notify-send "Mic FX" "Reverb off back to $CLEAN_PRESET"
        else
          ${pkgs.easyeffects}/bin/easyeffects --load-preset "$REVERB_PRESET"
          echo "reverb" > "$STATE_FILE"
          ${pkgs.libnotify}/bin/notify-send "Mic FX" "SUPER WIZARD REVERB ON"
        fi
      '')
    ];
  };
}