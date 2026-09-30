{ config, ... }:

{
  imports = [
    ../scripts/wallpaper.nix
  ];

  programs.dank-material-shell.enable = false;

  programs.wallpaper.enable = true;

  programs.waybar = {
    enable = true;
    systemd.enable = true;

    settings.mainBar = {
      layer = "top";
      position = "top";
      height = 30;
      spacing = 4;

      # Floating bar that lines up with niri's 16px gaps.
      margin-top = 8;
      margin-left = 16;
      margin-right = 16;

      modules-left = [ "niri/workspaces" ];
      modules-center = [ "niri/window" ];
      modules-right = [
        "pulseaudio"
        "network"
        "battery"
        "clock"
        "tray"
      ];

      "niri/window" = {
        max-length = 60;
      };

      clock = {
        format = "{:%H:%M}";
        format-alt = "{:%a %d.%m.%Y}";
      };

      pulseaudio = {
        format = "vol {volume}%";
        format-muted = "vol muted";
        on-click = "wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle";
      };

      network = {
        format-wifi = "{essid}";
        format-ethernet = "wired";
        format-disconnected = "offline";
        tooltip-format = "{ipaddr}";
      };

      battery = {
        format = "bat {capacity}%";
        format-charging = "chg {capacity}%";
        states = {
          warning = 25;
          critical = 10;
        };
      };

      tray = {
        spacing = 8;
      };
    };

    style = ''
      @import url("file://${config.xdg.configHome}/waybar/colors.css");

      * {
        font-family: "JetBrainsMono Nerd Font";
        font-size: 12px;
        border: none;
        min-height: 0;
      }

      window#waybar {
        background: alpha(@surface, 0.85);
        color: @on_surface;
        border-radius: 12px;
      }

      #workspaces button {
        padding: 0 8px;
        margin: 4px 2px;
        color: @on_surface_variant;
        background: transparent;
        border-radius: 8px;
      }

      #workspaces button.active,
      #workspaces button.focused {
        color: @on_primary;
        background: @primary;
      }

      #window {
        color: @on_surface_variant;
      }

      #clock,
      #pulseaudio,
      #network,
      #battery,
      #tray {
        padding: 0 10px;
      }

      #clock {
        color: @primary;
      }

      #pulseaudio.muted {
        color: @outline;
      }

      #battery.warning {
        color: @tertiary;
      }

      #battery.critical {
        color: @error;
      }
    '';
  };
}