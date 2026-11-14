{ inputs, pkgs, lib, ... }:

let
  comfyui = inputs.nixified-ai.packages.${pkgs.stdenv.hostPlatform.system}.comfyui-nvidia;
  dataDir = "/home/goshva/ComfyUI";
in
{
  # Binary cache, so PyTorch and friends aren't built locally
  nix.settings = {
    extra-substituters = [ "https://ai.cachix.org" ];
    extra-trusted-public-keys = [
      "ai.cachix.org-1:N9dzRK+alWwoKXQlnn0H6aUx0lU/mspIoz8hMvGvbbc="
    ];
  };

  systemd.tmpfiles.rules = [
    "d ${dataDir}        0755 goshva users -"
    "d ${dataDir}/input  0755 goshva users -"
    "d ${dataDir}/output 0755 goshva users -"
    "d ${dataDir}/user   0755 goshva users -"
  ];

  systemd.services.comfyui = {
    description = "ComfyUI (local only, no network)";
    after = [ "network.target" ];
    # Not started at boot; run `sudo systemctl start comfyui` when you want it
    wantedBy = [ ];

    serviceConfig = {
      User = "goshva";
      Group = "users";
      WorkingDirectory = dataDir;
      ExecStart = lib.concatStringsSep " " [
        (lib.getExe comfyui)
        "--listen 127.0.0.1"
        "--port 8188"
        "--input-directory ${dataDir}/input"
        "--output-directory ${dataDir}/output"
        "--user-directory ${dataDir}/user"
      ];

      # The privacy lockdown: localhost only, every other connection is refused
      IPAddressDeny = "any";
      IPAddressAllow = "localhost";

      Restart = "on-failure";
    };
  };
}