{ ... }:

{
  imports = [
    # Replace this with the machine's generated hardware configuration.
    ./hardware-configuration.nix

    # Shared system configuration
    ../../modules/base.nix

    # Add the modules needed by this machine.
    # ../../modules/hardware/zram.nix
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

    # Custom tools
    # ../../modules/rgs.nix
  ];

  networking.hostName = "replace-me";

  # Configure the bootloader per machine.
  # boot.loader.systemd-boot.enable = true;
  # boot.loader.efi.canTouchEfiVariables = true;

  # Keep this at the release used for the machine's original installation.
  system.stateVersion = "replace-me";
}