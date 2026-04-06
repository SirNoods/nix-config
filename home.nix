{ config, pkgs, ...}:

{
    home.username = "goshva";
    home.homeDirectory = "/home/goshva";
    programs.git.enable = true;
    home.stateVersion = "25.11";
    programs.bash = {
        enable = true;
        shellAliases = {
            btw = "echo 'fix nixes this'";
        };
    };

}
