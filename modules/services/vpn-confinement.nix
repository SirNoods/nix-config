{ config, ... }:
{
  vpnNamespaces.protonvpn = {
    enable = true;
    wireguardConfigFile = config.sops.secrets.protonvpn-wg.path; # see secrets note below
    accessibleFrom = [ "127.0.0.1" "100.111.0.0/16" "fd7a:115c:a1e0::/48" ];
    portMappings = [
      { from = 8090; to = 8090; } # qbittorrent webui
      { from = 8100; to = 8100; } # sabnzbd webui
      { from = 6881; to = 6881; protocol = "both"; } # torrent port
    ];
  };
}