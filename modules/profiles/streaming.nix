{ pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    obs-cmd
    mpv
  ];

  programs.obs-studio = {
    enable = true;
    enableVirtualCamera = true;

    plugins = with pkgs.obs-studio-plugins; [
      wlrobs
      obs-multi-rtmp
      obs-pipewire-audio-capture
    ];
  };
  # Workaround: v4l2loopback 0.15.4 ships depmod output files (modules.*),
  # which collide with the kernel's when NixOS merges module trees.
  # NixOS regenerates these itself. Remove once fixed upstream (2026-10-21).
  boot.kernelPackages = pkgs.linuxPackages.extend (kfinal: kprev: {
    v4l2loopback = kprev.v4l2loopback.overrideAttrs (old: {
      postInstall = (old.postInstall or "") + ''
        rm -f $out/lib/modules/*/modules.*
      '';
    });
  });

  programs.streamdeck-ui.enable = true;
}
