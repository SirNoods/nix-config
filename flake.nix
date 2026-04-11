{
  description = "Goshva Goshva Goshva";

  nixConfig = {
  extra-substituters = [ 
    "https://noctalia.cachix.org"
    "https://vicinae.cachix.org"
  ];
  extra-trusted-public-keys = [
    "noctalia.cachix.org-1:pCOR47nnMEo5thcxNDtzWpOxNFQsBRglJzxWPp3dkU4="
    "vicinae.cachix.org-1:1kDrfienkGHPYbkpNj1mWTr7Fm1+zcenzgTizIcI3oc="
  ];
  };

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    noctalia = {
      url = "github:noctalia-dev/noctalia-shell";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    vicinae.url = "github:vicinaehq/vicinae";

    zen-browser = {
      url = "github:youwen5/zen-browser-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };

  };

  outputs = inputs@{ self, nixpkgs, home-manager, ... }: {
    nixosConfigurations.galahad = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = [
      ./hosts/galahad/configuration.nix
      home-manager.nixosModules.home-manager
      {
        home-manager = {
          useGlobalPkgs = true;
          useUserPackages = true;
          users.goshva = import ./home.nix;
          backupFileExtension = "backup";
          extraSpecialArgs = { inherit inputs; };
        };
      }
      ];
    };
    nixosConfigurations.gasket = nixpkgs.lib.nixosSystem {
      modules = [
      ./hosts/gasket/configuration.nix
      home-manager.nixosModules.home-manager
      {
        home-manager = {
          useGlobalPkgs = true;
          useUserPackages = true;
          users.goshva = import ./home.nix;
          backupFileExtension = "backup";
          extraSpecialArgs = { inherit inputs; };
        };
      }
      ];
    };
    nixosConfigurations.glyph = nixpkgs.lib.nixosSystem {
      modules = [
      ./hosts/glyph/configuration.nix
      home-manager.nixosModules.home-manager
      {
        home-manager = {
          useGlobalPkgs = true;
          useUserPackages = true;
          users.goshva = import ./home.nix;
          backupFileExtension = "backup";
          extraSpecialArgs = { inherit inputs; };
        };
      }
      ];
    };
  };
}
