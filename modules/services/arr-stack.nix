{ pkgs, ... }:
{
  services.jellyfin.enable = true;
  users.users.jellyfin.extraGroups = [ "video" "render" ];

  services.sonarr.enable = true;
  services.radarr.enable = true;
  services.bazarr.enable = true;
  services.prowlarr.enable = true;
  services.jellyseerr.enable = true;
  services.audiobookshelf.enable = true;

  services.sabnzbd.enable = true;
  services.qbittorrent = {
    enable = true;
    webuiPort = 8090;
  };

  systemd.services.sabnzbd.vpnConfinement = {
    enable = true;
    vpnNamespace = "protonvpn";
  };
  systemd.services.qbittorrent.vpnConfinement = {
    enable = true;
    vpnNamespace = "protonvpn";
  };

  virtualisation.oci-containers.containers = {
    flaresolverr = {
      image = "ghcr.io/flaresolverr/flaresolverr:latest";
      ports = [ "8191:8191" ];
      environment.TZ = "Europe/Berlin";
    };
    homer = {
      image = "b4bz/homer";
      ports = [ "8080:8080" ];
      volumes = [ "/opt/homer:/www/assets" ];
      environment.INIT_ASSETS = "1";
    };
  };
}