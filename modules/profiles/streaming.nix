{ pkgs, ... }:

{
  imports = [
    ../scripts/obs-split.nix
    ../scripts/mic-reverb-toggle.nix
    ../scripts/yt-tools.nix
  ];

  environment.systemPackages = with pkgs; [
    obs-cmd
  ];

  programs.obs-studio = {
    enable = true;

    plugins = with pkgs.obs-studio-plugins; [
      wlrobs
      obs-multi-rtmp
    ];
  };

  programs.streamdeck-ui.enable = true;
}
