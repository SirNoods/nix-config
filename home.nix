{ config, pkgs, inputs, osConfig, ...}:

{
    imports = [
        inputs.vicinae.homeManagerModules.default
        ];

    home.username = "goshva";
    home.homeDirectory = "/home/goshva";
    home.stateVersion = "25.11";

    # Install Noctalia (only use if the programs.noctalia is commented out)
    home.packages = [
        inputs.noctalia.packages.${pkgs.stdenv.hostPlatform.system}.default
        pkgs.nautilus
    ];

    home.file.".config/niri/config.kdl".source =
        config.lib.file.mkOutOfStoreSymlink "/home/goshva/nix-config/niri/${osConfig.networking.hostName}.kdl";

    home.file.".config/ghostty/config.ghostty".source =
        config.lib.file.mkOutOfStoreSymlink "/home/goshva/nix-config/ghostty/config.ghostty";

    # Paraing up my xdg user directories
    xdg.userDirs = {
        enable = true;
        createDirectories = true;
        setSessionVariables = true;

        desktop = null;
        documents = "${config.home.homeDirectory}/3_Resources/Documents";
        download = "${config.home.homeDirectory}/Downloads";
        music = "${config.home.homeDirectory}/3_Resources/Audio";
        pictures = "${config.home.homeDirectory}/3_Resources/Pictures";
        videos = "${config.home.homeDirectory}/3_Resources/Videos";
        publicShare = null;
        templates = null;
    };

    home.pointerCursor = {
        gtk.enable = true;
        x11.enable = true;
        package = pkgs.adwaita-icon-theme;
        name = "Adwaita";
        size = 12;
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

    # git git git
    programs.git = {
    enable = true;
    settings.user.name = "goshva";
    settings.user.email = "goshva@goshva.cool";
    };

    #Bish Bash Bosh
    programs.bash = {
        enable = true;
        enableCompletion = true;
        shellAliases = {
            btw = "echo 'fix nixes this bitch'";
            nrs = "sudo nixos-rebuild switch --flake . && notify-send 'NixOS' 'Rebuild done'";
            rgs = ''
                xhost +local: >/dev/null 2>&1; podman run --rm -it \
                --userns=keep-id \
                --group-add keep-groups \
                --net=host \
                --security-opt label=disable \
                -e DISPLAY="$DISPLAY" \
                -v /tmp/.X11-unix:/tmp/.X11-unix:rw \
                -v "$HOME/.local/share/rgreceiver:/root" \
                --device /dev/dri \
                localhost/rgreceiver
            '';
        };
    };

}
