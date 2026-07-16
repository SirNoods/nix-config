{
  config,
  pkgs,
  inputs,
  osConfig,
  ...
}:

{
  imports = [
    inputs.vicinae.homeManagerModules.default
    inputs.dms.homeModules.dank-material-shell
    ./modules/scripts/obs-split.nix
    ./modules/scripts/yt-tools.nix
    ./modules/scripts/archive.nix
    ./modules/scripts/mic-reverb-toggle.nix
  ];

  home.username = "goshva";
  home.homeDirectory = "/home/goshva";
  home.stateVersion = "25.11";

  home.packages = [
    pkgs.nautilus
  ];

  home.file.".config/niri/config.kdl".source =
    config.lib.file.mkOutOfStoreSymlink "/home/goshva/nix-config/niri/${osConfig.networking.hostName}.kdl";

  home.file.".config/ghostty/config.ghostty".source =
    config.lib.file.mkOutOfStoreSymlink "/home/goshva/nix-config/ghostty/config.ghostty";

  services.easyeffects = {
    enable = true;
    preset = "headsetmic";
  };
  goshva.micReverbToggle.enable = true;

  programs.obs-split = {
    enable = true;
    rawDir = "/home/goshva/3_Resources/Recordings/raw";
    projectsDir = "/home/goshva/1_Projects";
  };

  programs.yt-tools.enable = true;

  programs.archive.enable = true;

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
    enable = true;
    gtk.enable = true;
    x11.enable = true;
    package = pkgs.adwaita-icon-theme;
    name = "Adwaita";
    size = 12;
  };

  # Time for DMS
  programs.dank-material-shell.enable = true;

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

  programs.zsh = {
    enable = true;
    enableCompletion = true;
    autosuggestion = {
      enable = true;
      highlight = "fg=8";
    };

    syntaxHighlighting = {
      enable = true;

      styles = {
        command = "fg=green,bold";
        builtin = "fg=cyan";
        alias = "fg=cyan";
        function = "fg=blue";
        path = "fg=magenta";
        path_prefix = "fg=magenta";
        globbing = "fg=yellow";
        single-hyphen-option = "fg=yellow";
        double-hyphen-option = "fg=yellow";
        single-quoted-argument = "fg=cyan";
        double-quoted-argument = "fg=cyan";
        unknown-token = "fg=red,bold";
        reserved-word = "fg=yellow";
        comment = "fg=8";
      };
    };

    history = {
      size = 10000;
      save = 10000;
      path = "${config.xdg.dataHome}/zsh/history";

      ignoreDups = true;
      ignoreSpace = true;
      share = true;
      extended = true;
    };

    autocd = true;

    initContent = ''
    PROMPT='%B%n@%m%b:%~ > '
    '';

    shellAliases = {
      btw = "echo 'fix nixes this bitch'";
      nrs = "sudo nixos-rebuild switch --flake . && notify-send 'NixOS' 'Rebuild done'";
      # RGRECEIVER
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
      # in case it shits itself
      rgs-safe = ''
        xhost +local:
        podman run -ti --rm \
          -e DISPLAY \
          -e LIBGL_ALWAYS_SOFTWARE=1 \
          -e QT_XCB_GL_INTEGRATION=none \
          -e QT_OPENGL=software \
          -e MESA_LOADER_DRIVER_OVERRIDE=llvmpipe \
          -e GALLIUM_DRIVER=llvmpipe \
          --net=host \
          localhost/rgreceiver
      '';
      # and if the display state is shite, then after do rgs
      rgs-reset = ''
        mv "$HOME/.local/share/rgreceiver" "$HOME/.local/share/rgreceiver.bak.$(date +%Y%m%d-%H%M%S)"
        mkdir -p "$HOME/.local/share/rgreceiver"
      '';
    };
  };

  #Bish Bash Bosh
  programs.bash = {
    enable = true;
    enableCompletion = true;
    shellAliases = {
      btw = "echo 'fix nixes this bitch'";
      nrs = "sudo nixos-rebuild switch --flake . && notify-send 'NixOS' 'Rebuild done'";
      # RGRECEIVER
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
      # in case it shits itself
      rgs-safe = ''
        xhost +local:
        podman run -ti --rm \
          -e DISPLAY \
          -e LIBGL_ALWAYS_SOFTWARE=1 \
          -e QT_XCB_GL_INTEGRATION=none \
          -e QT_OPENGL=software \
          -e MESA_LOADER_DRIVER_OVERRIDE=llvmpipe \
          -e GALLIUM_DRIVER=llvmpipe \
          --net=host \
          localhost/rgreceiver
      '';
      # and if the display state is shite, then after do rgs
      rgs-reset = ''
        mv "$HOME/.local/share/rgreceiver" "$HOME/.local/share/rgreceiver.bak.$(date +%Y%m%d-%H%M%S)"
        mkdir -p "$HOME/.local/share/rgreceiver"
      '';
    };
  };

}
