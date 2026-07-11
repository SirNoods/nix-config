{
  inputs,
  pkgs,
  ...
}:

{
  environment.systemPackages = with pkgs; [
    vscodium
    jellyfin-desktop
    discord
    vesktop
    obsidian
    bitwarden-desktop
    chafa
    fastfetch
    spotify
    vlc
    easyeffects
    pywalfox-native
    pywal
    inputs.zen-browser.packages.${pkgs.stdenv.hostPlatform.system}.default
    kdePackages.kate
  ];
}
