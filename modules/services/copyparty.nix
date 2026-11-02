{ config, inputs, ... }:

# copyparty on avalon
#
# Bound to localhost only and published through Caddy, gated to Netbird
# ranges like the other services.

let
  port = 3923;
  domain = "files.joshs.tech";
in
{
  imports = [ inputs.copyparty.nixosModules.default ];

  nixpkgs.overlays = [ inputs.copyparty.overlays.default ];

  sops.secrets."copyparty/goshva_password" = {
    owner = "goshva";
  };

  services.copyparty = {
    enable = true;

    user = "goshva";
    group = "users";

    settings = {
      i = "127.0.0.1"; # only reachable through Caddy
      p = [ port ];
      no-reload = true; # config comes from nix, not the web UI

      # Trust Caddy's X-Forwarded-For so logs and bans see real client IPs
      xff-hdr = "x-forwarded-for";
      xff-src = "127.0.0.1";
      rproxy = 1;

      # Thumbnails and media tags in the browser
      e2t = true;
    };

    accounts = {
      goshva.passwordFile = config.sops.secrets."copyparty/goshva_password".path;
    };

    volumes = {
      # Whole storage disk, full access
      "/" = {
        path = "/mnt/storage";
        access = {
          rwmd = [ "goshva" ]; # read, write, move, delete
        };
        flags = {
          e2d = true; # file index for search
          scan = 900; # rescan every 15 min for new files
          fk = 8; # filekeys, so shared links can't be guessed
          # Don't hash big media; indexing 1.8T of video would take forever
          nohash = "\\.(mkv|mp4|avi|m4v|webm|m4b|iso|img)$";
        };
      };
    };
  };

  services.caddy.virtualHosts.${domain}.extraConfig = ''
    @netbird remote_ip 100.111.0.0/16 fd7a:115c:a1e0::/48
    handle @netbird {
      reverse_proxy 127.0.0.1:${toString port}
    }
    respond 403
  '';
}
