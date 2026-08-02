{ pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    blender
    audacity
    yt-dlp
    ffmpeg
    blockbench
    imagemagick
    #davinci-resolve heavy build, commenting out until I wanna commit the time lol
  ];
}
