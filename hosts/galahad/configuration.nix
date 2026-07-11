# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{
  config,
  pkgs,
  inputs,
  ...
}:
let
  system = pkgs.stdenv.hostPlatform.system;

  mesa25Pkgs = inputs.nixpkgs-mesa25.legacyPackages.${pkgs.stdenv.hostPlatform.system};
in
{
  imports = [
    ./hardware-configuration.nix

    ../../modules/base.nix

    ../../modules/desktop

    ../../modules/greeter/sddm.nix

    # Profiles
    ../../modules/profiles/editing.nix
    ../../modules/profiles/gaming.nix
    ../../modules/profiles/streaming.nix
    ../../modules/profiles/workstation.nix
    ../../modules/profiles/windows-apps.nix

    ../../modules/rgs.nix
  ];

  # Bootloader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = "galahad";

  # Enable Flakes
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  nix.settings.trusted-users = [
    "root"
    "goshva"
  ];

  # Set your time zone.
  time.timeZone = "Europe/Berlin";

  # Select internationalisation properties.
  i18n.defaultLocale = "en_GB.UTF-8";

  i18n.extraLocaleSettings = {
    LC_ADDRESS = "de_DE.UTF-8";
    LC_IDENTIFICATION = "de_DE.UTF-8";
    LC_MEASUREMENT = "de_DE.UTF-8";
    LC_MONETARY = "de_DE.UTF-8";
    LC_NAME = "de_DE.UTF-8";
    LC_NUMERIC = "de_DE.UTF-8";
    LC_PAPER = "de_DE.UTF-8";
    LC_TELEPHONE = "de_DE.UTF-8";
    LC_TIME = "de_DE.UTF-8";
  };

  # Configure keymap in X11
  services.xserver.xkb = {
    layout = "de";
    variant = "";
  };

  # Configure console keymap
  console.keyMap = "de";

  # Enable touchpad support (enabled default in most desktopManager).
  # services.xserver.libinput.enable = true;

  # Define a user account. Don't forget to set a password with ‘passwd’.
  users.users.goshva = {
    isNormalUser = true;
    description = "goshva";
    extraGroups = [
      "networkmanager"
      "wheel"
    ];
    packages = with pkgs; [
      kdePackages.kate
    ];
  };

  # Allow unfree packages
  #nixpkgs.config.allowUnfree = true;
  nixpkgs.config = {
    allowUnfree = true;

    permittedInsecurePackages = [
      "electron-39.8.10"
    ];
  };

  # List packages installed in system profile. To search, run:
  # $ nix search wget
  environment.systemPackages = with pkgs; [
    netbird
  ];

  # Memory / swap
  zramSwap = {
    enable = true;
    memoryPercent = 50;
  };

  swapDevices = [
    {
      device = "/swapfile";
      size = 16 * 1024; # 16 GB
    }
  ];

  boot.kernel.sysctl = {
    "vm.swappiness" = 10;
  };

  fonts.packages = with pkgs; [
    nerd-fonts.jetbrains-mono
  ];

  services.netbird.enable = true;

  hardware.graphics = {
    enable = true;
    enable32Bit = true;

    package = mesa25Pkgs.mesa;
    package32 = mesa25Pkgs.pkgsi686Linux.mesa;
  };

  # Some programs need SUID wrappers, can be configured further or are
  # started in user sessions.
  # programs.mtr.enable = true;
  # programs.gnupg.agent = {
  #   enable = true;
  #   enableSSHSupport = true;
  # };

  # List services that you want to enable:

  # Enable the OpenSSH daemon.
  services.openssh.enable = true;
  # programs.ssh.startAgent = true;

  # Open ports in the firewall.
  # networking.firewall.allowedTCPPorts = [ ... ];
  # networking.firewall.allowedUDPPorts = [ ... ];
  # Or disable the firewall altogether.
  # networking.firewall.enable = false;

  networking.extraHosts = ''
    192.168.178.32 goblin
    192.168.178.32 caithawiki.joshs.tech
    192.168.178.32 foundry.joshs.tech
  '';

  #mounting the hdd
  # 6109c55d-cf54-47b1-bca9-4ee175dffbd8
  fileSystems."/mnt/hdd" = {
    device = "/dev/disk/by-uuid/6109c55d-cf54-47b1-bca9-4ee175dffbd8";
    fsType = "ext4";
  };

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "25.11"; # Did you read the comment?

}
