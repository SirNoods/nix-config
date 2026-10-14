{ pkgs, ... }:
let
  discord-key = pkgs.writeShellApplication {
    name = "discord-key";
    runtimeInputs = with pkgs; [ niri jq wtype ];
    text = ''
      key="$1"   # m = mute, d = deafen
      app_id="''${2:-vesktop}"

      prev=$(niri msg --json focused-window | jq -r '.id // empty')
      target=$(niri msg --json windows \
        | jq -r --arg a "$app_id" '[.[] | select(.app_id == $a)][0].id // empty')

      [ -z "$target" ] && exit 1

      niri msg action focus-window --id "$target"
      sleep 0.05
      wtype -M ctrl -M shift -k "$key" -m shift -m ctrl
      sleep 0.05

      [ -n "$prev" ] && niri msg action focus-window --id "$prev"
    '';
  };
in {
  home.packages = [ discord-key ];
}