{ pkgs, ... }:

{
  imports = [
    ./audio.nix
    ./niri.nix
    ./portals.nix
  ];

  networking.networkmanager = {
    enable = true;

    plugins = with pkgs; [
      networkmanager-openvpn
    ];
  };

  hardware.bluetooth.enable = true;

  services.power-profiles-daemon.enable = true;
  services.upower.enable = true;
  services.gvfs.enable = true;
  services.printing.enable = true;

  #programs.nm-applet.enable = true;
  programs.firefox.enable = true;
}
