{ pkgs, ... }:

{
  programs.dank-material-shell.enable = false;

  programs.waybar = {
    enable = true;
    systemd.enable = true;
  };

  services.mako.enable = true;

  home.packages = with pkgs; [
    matugen
    swww
  ];
}