# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{
  pkgs,
  inputs,
  ...
}:
let
  mesa25Pkgs = inputs.nixpkgs-mesa25.legacyPackages.${pkgs.stdenv.hostPlatform.system};
in
{
  imports = [
    # Hardware
    ./hardware-configuration.nix
    ../../modules/hardware/zram.nix

    ../../modules/base.nix

    ../../modules/desktop

    ../../modules/greeter/sddm.nix

    # Profiles
    ../../modules/profiles/editing.nix
    ../../modules/profiles/gaming.nix
    ../../modules/profiles/streaming.nix
    ../../modules/profiles/workstation.nix
    ../../modules/profiles/windows-apps.nix

    # Services
    ../../modules/services/netbird.nix
    ../../modules/services/ssh.nix

    # Tools
    ../../modules/rgs.nix
  ];

  # Bootloader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = "galahad";

  swapDevices = [
    {
      device = "/swapfile";
      size = 16 * 1024; # 16 GB
    }
  ];

  hardware.graphics = {
    enable = true;
    enable32Bit = true;

    package = mesa25Pkgs.mesa;
    package32 = mesa25Pkgs.pkgsi686Linux.mesa;
  };

  networking.extraHosts = ''
    192.168.178.32 goblin
    192.168.178.32 caithawiki.joshs.tech
    192.168.178.32 foundry.joshs.tech
  '';

  fileSystems."/mnt/hdd" = {
    device = "/dev/disk/by-uuid/6109c55d-cf54-47b1-bca9-4ee175dffbd8";
    fsType = "ext4";
  };

  system.stateVersion = "25.11";

}
