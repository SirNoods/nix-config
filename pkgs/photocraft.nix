{ appimageTools, fetchurl }:

let
  pname = "photocraft";
  version = "0.7.0";

  src = fetchurl {
    url = "https://github.com/storytold/photocraft/releases/download/v${version}/photocraft-${version}-linux-x86_64.AppImage";
    sha256 = "87ebce36bcdf6b31d16a9ca22ce29f9ad8db68185e4d98118800d1c2de78ac42";
  };

  contents = appimageTools.extractType2 { inherit pname version src; };
in
appimageTools.wrapType2 {
  inherit pname version src;

  # Renders through Vulkan on Linux
  extraPkgs = pkgs: [ pkgs.vulkan-loader ];

  # Pull the .desktop file and icons out of the AppImage so it appears in launchers
  extraInstallCommands = ''
    for f in ${contents}/*.desktop; do
      install -Dm644 "$f" -t $out/share/applications
    done
    sed -i 's|^Exec=[^ ]*|Exec=${pname}|' $out/share/applications/*.desktop

    if [ -d ${contents}/usr/share/icons ]; then
      cp -r ${contents}/usr/share/icons $out/share/
    fi
  '';
}