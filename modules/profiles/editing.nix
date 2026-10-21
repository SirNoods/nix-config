{ pkgs, lib, inputs, ... }:

let
  blenderPkgs = inputs.nixpkgs-blender.legacyPackages.${pkgs.stdenv.hostPlatform.system};

  resolvePkgs = import inputs.nixpkgs-resolve {
    system = pkgs.stdenv.hostPlatform.system;
    config.allowUnfree = true;
  };

  davinciWrapped = pkgs.writeShellScriptBin "davinci-resolve" ''
    exec ${pkgs.xwayland-run}/bin/xwayland-run -- \
      ${resolvePkgs.davinci-resolve}/bin/davinci-resolve "$@"
  '';

  # Built from whatever Python package set it's given, so it always matches
  # the Python inside the pinned Blender.
  mkMcschematic = ps: ps.buildPythonPackage rec {
    pname = "mcschematic";
    version = "11.4.2";
    format = "setuptools";
    src = ps.fetchPypi {
      inherit pname version;
      hash = "sha256-yHQNYV/XmuTTPTzb/AX3wRi0D8+rmti4EzaSCqfTsb0=";
    };
    doCheck = false;
  };

  blenderPinned = blenderPkgs.blender.withPackages (ps: [
    ps.pillow
    (mkMcschematic ps)
  ]);
in

{
  environment.systemPackages = with pkgs; [
    blenderPinned
    audacity
    yt-dlp
    ffmpeg
    blockbench
    imagemagick
    (pkgs.callPackage ../../pkgs/photocraft.nix { })
    davinciWrapped

    clinfo
    xwayland-run
  ];

  hardware.amdgpu.opencl.enable = true;
}