{ pkgs, ... }:

{
  imports = [
    ../steam.nix
  ];

  environment.systemPackages = with pkgs; [
    prismlauncher
    modrinth-app
    heroic
    deadlock-mod-manager
    r2modman
    gamescope
  ];
}
