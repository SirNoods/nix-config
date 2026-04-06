{
  description = "A very basic flake";
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
  outputs = { self, nixpkgs, home-manager, ... }: {
    nixosConfigurations.gasket = nixpkgs.lib.nixosSystem {
      modules = [
      ./configuration.nix
      home-manager.nixosModules.home-manager
      {
        home-manager = {
          useGlobalPkgs = true;
          useUserPackages = true;
          users.goshva = import ./home.nix;
          backupFileExtension = "backup";
        };
      }
      ];
    };
  };
}
