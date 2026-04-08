{ config, pkgs, inputs, ...}:

{
    #imports = [
    #    inputs.noctalia.homeModules.default
    #    ];

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
    ];

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

    #Bish Bash Bosh
    programs.bash = {
        enable = true;
        enableCompletion = true;
        shellAliases = {
            btw = "echo 'fix nixes this bitch'";
	    nrs = "sudo nixos-rebuild switch --flake .";
        };
    };

}
