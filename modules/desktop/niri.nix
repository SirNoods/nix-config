{ pkgs, ... }:

{
  programs.niri.enable = true;

  services.xserver.enable = true;
  services.displayManager.defaultSession = "niri";

  environment.systemPackages = with pkgs; [
    ghostty
    alacritty
    libnotify
    xwayland-satellite
    fuzzel
    playerctl

    grim
    slurp
    wl-clipboard
    satty
  ];
}
