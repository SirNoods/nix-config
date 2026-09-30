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