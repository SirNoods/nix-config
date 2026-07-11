{
  inputs,
  pkgs,
  ...
}:

let
  system = pkgs.stdenv.hostPlatform.system;
  stablePkgs = inputs.nixpkgs-stable.legacyPackages.${system};
in
{
  environment.systemPackages = with pkgs; [
    wine
    stablePkgs.bottles
    flatpak
  ];
}
