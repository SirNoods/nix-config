{ pkgs, ... }:

{
  programs.steam = {
    enable = true;
    # extraCompatPackages = with pkgs; [ proton-ge-bin ];
  };

  hardware.steam-hardware.enable = true;
  programs.gamemode.enable = true;

  environment.systemPackages = with pkgs; [
    protonup-qt
    mangohud
  ];
}