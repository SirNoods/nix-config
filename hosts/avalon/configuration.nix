{ ... }:

{
  imports = [
    ./hardware-configuration.nix
    ../../modules/base.nix
    ../../modules/services/netbird.nix
    ../../modules/services/ssh.nix
    ../../modules/services/caddy.nix
    ../../modules/services/vpn-confinement.nix
    ../../modules/services/arr-stack.nix
    ../../modules/services/foundry.nix
    ../../modules/services/caitha-site.nix
  ];

  networking.hostName = "avalon";
  networking.firewall.allowedTCPPorts = [ 80 443 ];

  fileSystems."/mnt/storage" = {
    device = "/dev/disk/by-uuid/bc65f616-3756-4504-a382-d821ef9a50ab";
    fsType = "ext4";
  };

  environment.shellAliases = {
    nrs = "sudo nixos-rebuild switch --flake . && echo 'Rebuild done'";
  };

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  system.stateVersion = "25.11"; # match your actual install version
}