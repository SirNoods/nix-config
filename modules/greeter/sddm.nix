{ pkgs, ... }:

let
  whereIsMySddmClassic =
    pkgs.where-is-my-sddm-theme.overrideAttrs
      (old: {
        postInstall = (old.postInstall or "") + ''
          cp \
            "$src/where_is_my_sddm_theme/example_configurations/classic_nocursor.conf" \
            "$out/share/sddm/themes/where_is_my_sddm_theme/theme.conf"
        '';
      });
in
{
  services.displayManager.sddm = {
    enable = true;
    theme = "where_is_my_sddm_theme";

    extraPackages = with pkgs; [
      qt6Packages.qt5compat
    ];
  };

  environment.systemPackages = [
    whereIsMySddmClassic
  ];
}