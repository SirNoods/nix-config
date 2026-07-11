{ ... }:

{
  imports = [
    # Hardware
    ./hardware-configuration.nix

    # Base
    ../../modules/base.nix

    # Desktop & DisplayManager
    ../../modules/desktop
    ../../modules/greeter/sddm.nix

    # Profiles
    ../../modules/profiles/workstation.nix

    # Services
    ../../modules/services/netbird.nix
    ../../modules/services/ssh.nix

  ];

  networking.hostName = "bedivere";

  # Bootloader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Keep this at the release used for the machine's original installation.
  system.stateVersion = "25.11";
}