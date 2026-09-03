{ ... }:
let
  netbirdOnly = port: ''
    @netbird remote_ip 100.111.0.0/16 fd7a:115c:a1e0::/48
    handle @netbird {
      reverse_proxy 127.0.0.1:${toString port}
    }
    respond "Forbidden" 403
  '';
in
{
  services.caddy = {
    enable = true;
    email = "joshua@ka1schmidt.de";

    virtualHosts = {
      "foundry.joshs.tech".extraConfig = ''
        reverse_proxy 127.0.0.1:30000
      '';
      "caithawiki.joshs.tech".extraConfig = ''
        root * /home/goshva/caitha-site/dist
        file_server
      '';
      "audiobookshelf.joshs.tech".extraConfig = netbirdOnly 13378;
      "homer.joshs.tech".extraConfig = netbirdOnly 8080;
      "jellyfin.joshs.tech".extraConfig = netbirdOnly 8096;
      "jellyseerr.joshs.tech".extraConfig = netbirdOnly 5055;
      "qbittorrent.joshs.tech".extraConfig = netbirdOnly 8090;
      "radarr.joshs.tech".extraConfig = netbirdOnly 7878;
      "sonarr.joshs.tech".extraConfig = netbirdOnly 8989;
      "sabnzbd.joshs.tech".extraConfig = netbirdOnly 8100;
      "prowlarr.joshs.tech".extraConfig = netbirdOnly 9696;
    };
  };
}