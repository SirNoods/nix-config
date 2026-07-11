{ ... }:

{
  imports = [
    # Hardware
    ./hardware-configuration.nix
    # ../../modules/hardware/zram.nix

    # Base
    ../../modules/base.nix

    # Desktop & DisplayManager
    # ../../modules/desktop
    # ../../modules/greeter/sddm.nix

    # Profiles
    # ../../modules/profiles/workstation.nix
    # ../../modules/profiles/editing.nix
    # ../../modules/profiles/gaming.nix
    # ../../modules/profiles/streaming.nix
    # ../../modules/profiles/windows-apps.nix

    # Services
    # ../../modules/services/netbird.nix
    # ../../modules/services/ssh.nix

    # Tools
    # ../../modules/rgs.nix
  ];

  networking.hostName = "replace-me";

  # Bootloader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Keep this at the release used for the machine's original installation.
  system.stateVersion = "replace-me";
}