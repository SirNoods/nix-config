{ lib, appimageTools, fetchurl }:

let
  mkArtcraftApp =
    { pname, version, hash, extraPkgs ? (pkgs: [ ]) }:
    let
      src = fetchurl {
        url = "https://github.com/storytold/${pname}/releases/download/v${version}/${pname}-${version}-linux-x86_64.AppImage";
        inherit hash;
      };
      contents = appimageTools.extractType2 { inherit pname version src; };
    in
    appimageTools.wrapType2 {
      inherit pname version src;

      # All ArtCraft apps render through Vulkan on Linux
      extraPkgs = pkgs: [ pkgs.vulkan-loader ] ++ extraPkgs pkgs;

      extraInstallCommands = ''
        for f in ${contents}/*.desktop; do
          install -Dm644 "$f" -t $out/share/applications
        done
        sed -i 's|^Exec=[^ ]*|Exec=${pname}|' $out/share/applications/*.desktop

        if [ -d ${contents}/usr/share/icons ]; then
          cp -r ${contents}/usr/share/icons $out/share/
        fi
      '';
    };
in
{
  photocraft = mkArtcraftApp {
    pname = "photocraft";
    version = "0.16.0";
    hash = "sha256-/GcBOQkeZh6Uim3h/yIZpt0EIy5qyGFjSe4jinpJ1U4=";
  };

  soundcraft = mkArtcraftApp {
    pname = "soundcraft";
    version = "0.13.1";
    hash = "sha256-YH9KE/kptfI33mHpBAvkv8hqBmRL8qEDxz97nITTvxk=";
  };
}