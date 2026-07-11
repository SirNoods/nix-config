# Host template

This directory is a starting point for new NixOS hosts.

Copy `configuration.nix` into a new directory under `hosts/`, then:

1. Add the machine's generated `hardware-configuration.nix`.
2. Set `networking.hostName`.
3. Set the correct existing `system.stateVersion`.
4. Enable only the modules and profiles the machine needs.
5. Add the new host to `flake.nix`.

The template itself is not included in `nixosConfigurations`.
