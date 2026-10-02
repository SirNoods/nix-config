{ pkgs, ... }:
{
  services.jellyfin.enable = true;

  services.sonarr.enable = true;
  services.radarr.enable = true;
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
    vpnNamespace = "proton";
  };
  systemd.services.qbittorrent.vpnConfinement = {
    enable = true;
    vpnNamespace = "proton";
  };

  users.groups.arr-shared = {};
  users.users.sonarr.extraGroups = [ "arr-shared" ];
  users.users.radarr.extraGroups = [ "arr-shared" ];
  users.users.sabnzbd.extraGroups = [ "arr-shared" ];
  users.users.qbittorrent.extraGroups = [ "arr-shared" ];
  users.users.jellyfin.extraGroups = [ "video" "render" "arr-shared" ];

  virtualisation.oci-containers.containers = {
    flaresolverr = {
      image = "ghcr.io/flaresolverr/flaresolverr:latest";
      ports = [ "8191:8191" ];
      environment.TZ = "Europe/Berlin";
    };
    homer = {
      image = "docker.io/b4bz/homer:latest";
      ports = [ "8080:8080" ];
      volumes = [ "/opt/homer:/www/assets" ];
      environment.INIT_ASSETS = "1";
    };
  };
}
