# modules/services/caitha-site.nix
{ pkgs, ... }:
{
  environment.systemPackages = [ pkgs.nodejs ];

  systemd.services.caitha-site-build = {
    description = "Rebuild caitha wiki static site";
    serviceConfig = {
      Type = "oneshot";
      User = "goshva";
      WorkingDirectory = "/home/goshva/caitha-site";
      ExecStart = "${pkgs.bash}/bin/bash -c 'git pull && npm run build'";
    };
  };

  # optional: rebuild on a schedule instead of by hand
  systemd.timers.caitha-site-build = {
    wantedBy = [ "timers.target" ];
    timerConfig.OnCalendar = "daily";
  };
}