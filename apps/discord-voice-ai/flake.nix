{
  description = "Discord voice AI bot with local speech recognition and cloned-voice TTS";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAll = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # torch, ctranslate2 and friends come as prebuilt pip wheels, which expect these
      # libraries in the usual places. /run/opengl-driver/lib holds the NVIDIA driver on NixOS.
      runtimeLibs = pkgs: with pkgs; [ stdenv.cc.cc.lib zlib libopus libsndfile ];

      # Adds the CUDA libraries that pip installed with torch, so faster-whisper finds them too.
      envSetup = pkgs: ''
        export OPUS_LIB=${pkgs.libopus}/lib/libopus.so.0
        export LD_LIBRARY_PATH=${pkgs.lib.makeLibraryPath (runtimeLibs pkgs)}:/run/opengl-driver/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
        for d in "$PWD"/.venv/lib/python3.*/site-packages/nvidia/*/lib; do
          [ -d "$d" ] && export LD_LIBRARY_PATH="$d:$LD_LIBRARY_PATH"
        done
      '';
    in
    {
      devShells = forAll (pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [ python312 uv ffmpeg git ];
          shellHook = ''
            ${envSetup pkgs}
            if [ ! -d .venv ]; then
              echo "First run: creating .venv and installing dependencies (torch is big, give it a while)"
              uv venv --python ${pkgs.python312}/bin/python .venv
              uv pip install --python .venv/bin/python -r requirements.txt
              ${envSetup pkgs}
            fi
            source .venv/bin/activate
            [ -f .env ] && set -a && source .env && set +a
            echo "Ready. Start the bot with: python -m voicebot"
          '';
        };
      });

      # Self-contained systemd service, see nix/module.nix.
      nixosModules.default = import ./nix/module.nix;
    };
}
