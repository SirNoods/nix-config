{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.wallpaper;
  configHome = config.xdg.configHome;

  # ------------------------------------------------------------------
  # Templates. matugen replaces the {{colors.*}} placeholders.
  # ------------------------------------------------------------------

  waybarTemplate = pkgs.writeText "matugen-waybar.css" ''
    @define-color primary {{colors.primary.default.hex}};
    @define-color on_primary {{colors.on_primary.default.hex}};
    @define-color secondary {{colors.secondary.default.hex}};
    @define-color tertiary {{colors.tertiary.default.hex}};
    @define-color error {{colors.error.default.hex}};
    @define-color surface {{colors.surface.default.hex}};
    @define-color surface_container {{colors.surface_container.default.hex}};
    @define-color on_surface {{colors.on_surface.default.hex}};
    @define-color on_surface_variant {{colors.on_surface_variant.default.hex}};
    @define-color outline {{colors.outline.default.hex}};
  '';

  # Included at the end of the niri config, so it overrides earlier colours.
  niriTemplate = pkgs.writeText "matugen-niri.kdl" ''
    layout {
        focus-ring {
            active-color "{{colors.primary.default.hex}}"
            inactive-color "{{colors.outline.default.hex}}"
        }
        border {
            active-color "{{colors.primary.default.hex}}"
            inactive-color "{{colors.outline_variant.default.hex}}"
            urgent-color "{{colors.error.default.hex}}"
        }
    }
  '';

  # Material You has no ANSI colours, so the 16-colour palette is left
  # at Ghostty's defaults and only the surface colours are themed.
  ghosttyTemplate = pkgs.writeText "matugen-ghostty" ''
    background = {{colors.surface.default.hex}}
    foreground = {{colors.on_surface.default.hex}}
    cursor-color = {{colors.primary.default.hex}}
    selection-background = {{colors.primary_container.default.hex}}
    selection-foreground = {{colors.on_primary_container.default.hex}}
  '';

  makoTemplate = pkgs.writeText "matugen-mako" ''
    font=JetBrainsMono Nerd Font 10
    background-color={{colors.surface_container.default.hex}}
    text-color={{colors.on_surface.default.hex}}
    border-color={{colors.primary.default.hex}}
    progress-color=over {{colors.primary_container.default.hex}}
    border-size=2
    border-radius=12
    padding=10
    default-timeout=5000

    [urgency=high]
    border-color={{colors.error.default.hex}}
    default-timeout=0
  '';

  # ------------------------------------------------------------------
  # matugen config lives in the store and is passed with --config.
  # ------------------------------------------------------------------

  matugenConfig = (pkgs.formats.toml { }).generate "matugen-config.toml" {
    config = { };
    templates = {
      waybar = {
        input_path = "${waybarTemplate}";
        output_path = "${configHome}/waybar/colors.css";
      };
      niri = {
        input_path = "${niriTemplate}";
        output_path = "${configHome}/niri/matugen/colors.kdl";
      };
      ghostty = {
        input_path = "${ghosttyTemplate}";
        output_path = "${configHome}/ghostty/themes/${cfg.ghosttyThemeName}";
      };
      mako = {
        input_path = "${makoTemplate}";
        output_path = "${configHome}/mako/config";
      };
    };
  };

  outputDirs = lib.concatMapStringsSep " " lib.escapeShellArg [
    "${configHome}/waybar"
    "${configHome}/niri/matugen"
    "${configHome}/ghostty/themes"
    "${configHome}/mako"
  ];

  # ------------------------------------------------------------------
  # The command itself.
  # ------------------------------------------------------------------

  wallpaperScript = pkgs.writeShellApplication {
    name = "wallpaper";

    runtimeInputs = with pkgs; [
      swww
      matugen
      mako
      libnotify
      coreutils
      findutils
    ];

    text = ''
      WALLPAPER_DIR=${lib.escapeShellArg cfg.wallpaperDir}
      STATE_DIR="''${XDG_STATE_HOME:-$HOME/.local/state}/wallpaper"

      usage() {
        echo "Usage:"
        echo "  wallpaper <image>   set the wallpaper and regenerate colours"
        echo "  wallpaper -r        pick a random image from $WALLPAPER_DIR"
        echo "  wallpaper -c        print the current wallpaper"
      }

      reload_apps() {
        systemctl --user reload waybar.service 2>/dev/null || true
        makoctl reload 2>/dev/null || true
        # niri picks up the included colors.kdl on its own.
        # Ghostty: new windows get the theme, or press Ctrl+Shift+, to reload.
      }

      set_wallpaper() {
        if [ ! -f "$1" ]; then
          echo "Not a file: $1"
          exit 1
        fi

        local img
        img="$(realpath "$1")"

        mkdir -p "$STATE_DIR" ${outputDirs}

        swww img "$img" \
          --transition-type ${lib.escapeShellArg cfg.transition} \
          --transition-fps 60

        matugen image "$img" --config ${matugenConfig} --mode ${cfg.mode}

        ln -sfn "$img" "$STATE_DIR/current"

        reload_apps
        notify-send "Wallpaper" "$(basename "$img")"
      }

      pick_random() {
        if [ ! -d "$WALLPAPER_DIR" ]; then
          echo "Wallpaper directory not found: $WALLPAPER_DIR" >&2
          exit 1
        fi

        find "$WALLPAPER_DIR" -type f \
          \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \
             -o -iname '*.webp' -o -iname '*.gif' \) \
          | shuf -n 1
      }

      case "''${1:-}" in
        -r|--random)
          img="$(pick_random)"
          if [ -z "$img" ]; then
            echo "No images found in $WALLPAPER_DIR"
            exit 1
          fi
          set_wallpaper "$img"
          ;;
        -c|--current)
          readlink "$STATE_DIR/current" || echo "No wallpaper set yet."
          ;;
        -h|--help)
          usage
          ;;
        "")
          usage
          exit 1
          ;;
        *)
          set_wallpaper "$1"
          ;;
      esac
    '';
  };
in
{
  options.programs.wallpaper = {
    enable = lib.mkEnableOption "wallpaper switching with matugen colour generation";

    wallpaperDir = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/3_Resources/Pictures/Wallpapers";
      description = "Directory used by wallpaper -r.";
    };

    mode = lib.mkOption {
      type = lib.types.enum [
        "dark"
        "light"
      ];
      default = "dark";
      description = "Colour scheme mode passed to matugen.";
    };

    transition = lib.mkOption {
      type = lib.types.str;
      default = "grow";
      description = "swww transition type (simple, fade, wipe, grow, outer, wave, any, random).";
    };

    seedColor = lib.mkOption {
      type = lib.types.str;
      default = "#6750a4";
      description = "Colour used to generate a starting palette before any wallpaper is set.";
    };

    ghosttyThemeName = lib.mkOption {
      type = lib.types.str;
      default = "dankcolors";
      description = ''
        Name of the generated Ghostty theme. Defaults to "dankcolors" so the
        shared ghostty config (theme = dankcolors) works unchanged on hosts
        using this module and on hosts still running DMS.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [
      wallpaperScript
      pkgs.matugen
      pkgs.swww
      pkgs.mako
    ];

    systemd.user.services.swww-daemon = {
      Unit = {
        Description = "swww wallpaper daemon";
        PartOf = [ "graphical-session.target" ];
        After = [ "graphical-session.target" ];
      };
      Service = {
        ExecStart = "${pkgs.swww}/bin/swww-daemon";
        Restart = "on-failure";
      };
      Install.WantedBy = [ "graphical-session.target" ];
    };

    systemd.user.services.mako = {
      Unit = {
        Description = "mako notification daemon";
        PartOf = [ "graphical-session.target" ];
        After = [ "graphical-session.target" ];
      };
      Service = {
        Type = "dbus";
        BusName = "org.freedesktop.Notifications";
        ExecStart = "${pkgs.mako}/bin/mako";
        Restart = "on-failure";
      };
      Install.WantedBy = [ "graphical-session.target" ];
    };

    # niri refuses a config whose include is missing, so make sure the
    # generated files exist before the first wallpaper is ever set.
    home.activation.seedWallpaperColours = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      if [ ! -e ${lib.escapeShellArg "${configHome}/niri/matugen/colors.kdl"} ]; then
        run mkdir -p ${outputDirs}
        if ! run ${pkgs.matugen}/bin/matugen color hex ${lib.escapeShellArg cfg.seedColor} \
          --config ${matugenConfig} --mode ${cfg.mode}; then
          echo "wallpaper: could not generate seed colours, run 'wallpaper <image>' once" >&2
        fi
      fi
    '';
  };
}