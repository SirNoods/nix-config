{ pkgs, lib, inputs, ... }:

let
  resolvePkgs = import inputs.nixpkgs-resolve {
    system = pkgs.stdenv.hostPlatform.system;
    config.allowUnfree = true;
  };

  davinciWrapped = pkgs.writeShellScriptBin "davinci-resolve" ''
    exec ${pkgs.xwayland-run}/bin/xwayland-run -- \
      ${resolvePkgs.davinci-resolve}/bin/davinci-resolve "$@"
  '';

  mcschematic = pkgs.python313Packages.buildPythonPackage rec {
    pname = "mcschematic";
    version = "11.4.2";
    format = "setuptools";
    src = pkgs.fetchPypi {
      inherit pname version;
      hash = "sha256-yHQNYV/XmuTTPTzb/AX3wRi0D8+rmti4EzaSCqfTsb0=";
    };
    doCheck = false;
  };
in

{
  environment.systemPackages = with pkgs; [
    (blender.withPackages (ps: [
      ps.pillow
      mcschematic
    ]))
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