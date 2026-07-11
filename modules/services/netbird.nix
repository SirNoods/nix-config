{ pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    netbird
  ];

  services.netbird.enable = true;
}
