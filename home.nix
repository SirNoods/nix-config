{ config, pkgs, inputs, osConfig, ...}:

{
    imports = [
        inputs.vicinae.homeManagerModules.default
        ];

    home.username = "goshva";
    home.homeDirectory = "/home/goshva";
    programs.git = {
        enable = true;
        userName = "goshva";
        userEmail = "goshva@goshva.cool";
        };
    home.stateVersion = "25.11";

    # Install Noctalia (only use if the programs.noctalia is commented out)
    home.packages = [
        inputs.noctalia.packages.${pkgs.system}.default
        pkgs.nautilus
    ];

    home.file.".config/niri/config.kdl".source =
        config.lib.file.mkOutOfStoreSymlink "/home/goshva/nix-config/niri/${osConfig.networking.hostName}.kdl";

    home.file.".config/ghostty/config.ghostty".source =
        config.lib.file.mkOutOfStoreSymlink "/home/goshva/nix-config/ghostty/config.ghostty";

    #programs.noctalia-shell = {
    #    enable = true;
    #    settings = {
    #        bar = {
    #            density = "compact";
    #            position = "top";
    #            showCapsule = true;
    #        };
    #        colorSchemes.predefinedScheme = "Gruvbox";
    #        location = {
    #            monthBeforeDay = false;
    #            name = "Leipzig, Germany";
    #        };

    #    };
    #};

    # Paraing up my xdg user directories
    xdg.userDirs = {
        enable = true;
        createDirectories = true;

        desktop = null;
        documents = "${config.home.homeDirectory}/3_Resources/Documents";
        download = "${config.home.homeDirectory}/Downloads";
        music = "${config.home.homeDirectory}/3_Resources/Audio";
        pictures = "${config.home.homeDirectory}/3_Resources/Pictures";
        videos = "${config.home.homeDirectory}/3_Resources/Videos";
        publicShare = null;
        templates = null;
    };

    # Vicinae, Hoorae
    services.vicinae = {
        enable = true;
        systemd = {
            enable = true;
            autoStart = true;
            environment = {
                USE_LAYER_SHELL = 1;
            };
        };
    };

    #Bish Bash Bosh
    programs.bash = {
        enable = true;
        enableCompletion = true;
        shellAliases = {
            btw = "echo 'fix nixes this bitch'";
	    nrs = "sudo nixos-rebuild switch --flake . && notify-send 'NixOS' 'Rebuild done'";
        };
    };

}
