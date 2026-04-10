{ pkgs, ... }:

{
  # RGS (HP ZCentral Remote Boost) container support
  #
  # NOTE:
  # This module assumes you already have Xwayland working.
  # For niri, that typically means having:
  #   pkgs.xwayland-satellite
  # installed in your system packages.
  #
  # Without Xwayland, rgreceiver (X11 app) will fail with:
  #   "unable to open display"

  environment.systemPackages = with pkgs; [
    podman
    xhost
  ];

  virtualisation.podman = {
    enable = true;
    dockerCompat = true;
    defaultNetwork.settings.dns_enabled = true;
  };
}