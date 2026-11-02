{ config, inputs, ... }:

# copyparty on avalon
#
# Bound to localhost only and published through Caddy, gated to Netbird
# ranges like the other services. Needs the copyparty flake input plus
# inputs.copyparty.nixosModules.default in avalon's module list.
#
# Before the first rebuild, add the password to secrets/avalon.yaml:
#   sops secrets/avalon.yaml
#   copyparty:
#     goshva_password: <something long>

let
  port = 3923;
  domain = "files.joshs.tech";
in
{
  nixpkgs.overlays = [ inputs.copyparty.overlays.default ];

  sops.secrets."copyparty/goshva_password" = {
    owner = "copyparty";
    group = "copyparty";
  };

  # Writable area that copyparty owns outright, so it never needs write
  # access to the arr libraries or configs.
  systemd.tmpfiles.rules = [
    "d /mnt/storage/copyparty 0775 copyparty copyparty -"
    "d /mnt/storage/copyparty/inbox 0775 copyparty copyparty -"
  ];

  services.copyparty = {
    enable = true;

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
      # Whole storage disk, read-only
      "/" = {
        path = "/mnt/storage";
        access = {
          r = [ "goshva" ];
        };
        flags = {
          e2d = true; # file index for search
          scan = 900; # rescan every 15 min for new files
          # Don't hash big media; indexing 1.8T of video would take forever
          nohash = "\\.(mkv|mp4|avi|m4v|webm|m4b|iso|img)$";
        };
      };

      # Own space
      "/share" = {
        path = "/mnt/storage/copyparty";
        access = {
          rwmd = [ "goshva" ]; # read, write, move, delete
        };
        flags = {
          e2d = true;
          fk = 8; # filekeys, so shared links can't be guessed
        };
      };

      # Write-only drop box
      "/inbox" = {
        path = "/mnt/storage/copyparty/inbox";
        access = {
          w = [ "goshva" ];
        };
        flags = {
          e2d = true;
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
