{ pkgs, inputs, ... }:

let
  resolvePkgs = import inputs.nixpkgs-resolve {
    system = pkgs.stdenv.hostPlatform.system;
    config.allowUnfree = true;
  };

  davinciWrapped = pkgs.writeShellScriptBin "davinci-resolve" ''
    exec ${pkgs.xwayland-run}/bin/xwayland-run -- \
      ${resolvePkgs.davinci-resolve}/bin/davinci-resolve "$@"
  '';
in
{
  environment.systemPackages = with pkgs; [
    blender
    audacity
    yt-dlp
    ffmpeg
    blockbench
    imagemagick

    davinciWrapped

    clinfo
    xwayland-run
  ];

  hardware.amdgpu.opencl.enable = true;
}