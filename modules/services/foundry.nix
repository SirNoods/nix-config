# modules/services/foundry.nix
{ pkgs, ... }:
{
  systemd.services.foundry = {
    description = "Foundry VTT";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart = ''
        ${pkgs.nodejs}/bin/node /home/goshva/foundry/resources/app/main.js \
          --dataPath=/home/goshva/foundrydata/FoundryVTT \
          --host=0.0.0.0 --port=30000
      '';
      User = "goshva";
      Restart = "on-failure";
    };
  };
}