{ pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    blender
    audacity
    yt-dlp
    ffmpeg
    blockbench
    imagemagick
  ];
}
