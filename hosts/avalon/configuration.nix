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
  networking.firewall.allowedTCPPorts = [
    80
    443
  ];

  fileSystems."/mnt/storage" = {
    device = "/dev/disk/by-uuid/bc65f616-3756-4504-a382-d821ef9a50ab";
    fsType = "ext4";
  };

  sops.defaultSopsFile = ../../secrets/avalon.yaml;
  sops.age.keyFile = "/var/lib/sops-nix/key.txt";
  sops.secrets.protonvpn-wg = { };

  environment.shellAliases = {
    nrs = "sudo nixos-rebuild switch --flake . && echo 'Rebuild done'";
  };

  programs.zsh = {
    enableCompletion = true;
    autosuggestions.enable = true;
    syntaxHighlighting.enable = true;
    histSize = 10000;

    setOptions = [
      "INTERACTIVE_COMMENTS"
      "AUTO_CD"
      "HIST_IGNORE_DUPS"
      "HIST_IGNORE_SPACE"
      "SHARE_HISTORY"
      "EXTENDED_HISTORY"
    ];

    promptInit = ''
      PROMPT='%B%n@%m%b:%~ > '
    '';
  };

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  system.stateVersion = "25.11"; # match your actual install version
}
