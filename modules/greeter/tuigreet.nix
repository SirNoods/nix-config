{ pkgs, ... }:

{
  services.greetd = {
    enable = true;
    settings = {
      default_session = {
        command = ''
          ${pkgs.tuigreet}/bin/tuigreet \
            --time \
            --user-menu \
            --width 60 \
            --window-padding 2 \
            --container-padding 2 \
            --theme 'border=white;text=white;prompt=white;time=white;action=blue;button=white;container=black' \
            --asterisks \
            --remember \
            --cmd niri-session
        '';
        user = "greeter";
      };
    };
  };
}
