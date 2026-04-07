{ config, pkgs, ...}:

{
    home.username = "goshva";
    home.homeDirectory = "/home/goshva";
    programs.git = {
        enable = true;
        userName = "goshva";
	userEmail = "goshva@goshva.cool";
        };
    home.stateVersion = "25.11";
    programs.bash = {
        enable = true;
        enableCompletion = true;
        shellAliases = {
            btw = "echo 'fix nixes this bitch'";
	    nrs = "sudo nixos-rebuild switch --flake .";
        };
    };

}
