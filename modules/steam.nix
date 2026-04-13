{ pkgs, ... }:

{
  programs.steam = {
    enable = true;
    # extraCompatPackages = with pkgs; [ proton-ge-bin ];
  };

  hardware.steam-hardware.enable = true;
  programs.gamemode.enable = true;
  powerManagement.cpuFreqGovernor = "performance";

  environment.systemPackages = with pkgs; [
    protonup-qt
    mangohud
    gamescope
  ];
}
