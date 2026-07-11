{ pkgs, ... }:

{
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
