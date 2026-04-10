{ pkgs, ... }:
# experiment, do not use, it is shit
{
  services.greetd = {
    enable = true;
    settings = {
      default_session = {
        command = ''
          ${pkgs.cage}/bin/cage -s -- ${pkgs.regreet}/bin/regreet
        '';
        user = "greeter";
      };
    };
  };
  programs.regreet = {
    enable = true;
    theme = {
      package = pkgs.adw-gtk3;
      name = "adw-gtk3-dark";
    };
    iconTheme = {
      package = pkgs.papirus-icon-theme;
      name = "Papirus-Dark";
    };
    cursorTheme = {
      package = pkgs.adwaita-icon-theme;
      name = "Adwaita";
    };
    font = {
      package = pkgs.nerd-fonts.jetbrains-mono;
      name = "JetBrainsMono Nerd Font";
      size = 11;
    };
  };
  environment.systemPackages = with pkgs; [
    cage
  ];
}