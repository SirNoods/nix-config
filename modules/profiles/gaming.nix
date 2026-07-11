{ pkgs, ... }:

{
  imports = [
    ../steam.nix
  ];

  environment.systemPackages = with pkgs; [
    prismlauncher
    heroic
    deadlock-mod-manager
    gamescope
  ];
}
