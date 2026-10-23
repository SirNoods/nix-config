# Builds the starting .blend for a video project.
#
# Run by Nix at build time:
#   blender --background --factory-startup -noaudio \
#     --python-exit-code 1 --python video-template.py -- <config.json> <out.blend>
#
# The config comes from programs.obs-split.blenderTemplate in home.nix.
# Anything that is "nice to have" only warns on failure, so an API change in a
# future Blender release degrades the template instead of breaking the rebuild.

import json
import sys

import bpy


def warn(message):
    print(f"video-template: WARNING: {message}", file=sys.stderr)


def info(message):
    print(f"video-template: {message}")


argv = sys.argv[sys.argv.index("--") + 1 :]
config_path, out_path = argv
with open(config_path) as f:
    cfg = json.load(f)

info(f"Blender {bpy.app.version_string}")

# Start from Blender's own Video Editing template, so the workspaces
# (sequencer, preview, file browser, properties) are the familiar ones.
try:
    bpy.ops.wm.read_homefile(app_template="Video_Editing")
    info("loaded Video_Editing app template")
except Exception as e:
    warn(f"could not load the Video_Editing app template, using defaults: {e}")
    bpy.ops.wm.read_homefile()

scene = bpy.data.scenes[0]

# --- Render / output settings ------------------------------------------------

render = scene.render
render.resolution_x = cfg["width"]
render.resolution_y = cfg["height"]
render.resolution_percentage = 100
render.fps = cfg["fps"]
render.fps_base = 1.0
render.use_sequencer = True
render.filepath = "//render/"

try:
    # Blender 5.x splits image and video output via media_type.
    if hasattr(render.image_settings, "media_type"):
        render.image_settings.media_type = "VIDEO"
    render.image_settings.file_format = "FFMPEG"

    ffmpeg = render.ffmpeg
    ffmpeg.format = "MPEG4"
    ffmpeg.codec = "H264"
    ffmpeg.constant_rate_factor = "HIGH"
    ffmpeg.audio_codec = "AAC"
    ffmpeg.audio_channels = "STEREO"
    ffmpeg.audio_mixrate = 48000
    info("output set to MP4 / H.264 / AAC 48 kHz")
except Exception as e:
    warn(f"could not set video output settings: {e}")

try:
    # Keep the preview in sync with the audio when playback can't keep up.
    scene.sync_mode = "AUDIO_SYNC"
except Exception as e:
    warn(f"could not set playback sync mode: {e}")

# --- Named sequencer channels -----------------------------------------------

editor = scene.sequence_editor or scene.sequence_editor_create()
channels = editor.channels

# Strips use channels 1..128. Depending on the version the collection either
# includes an unused channel 0 or starts at channel 1; handle both.
offset = 0 if len(channels) > 128 else -1

for number, spec in enumerate(cfg["channels"], start=1):
    channel = channels[number + offset]
    channel.name = spec["name"]
    channel.mute = spec["mute"]

info(
    "channels (bottom to top): "
    + ", ".join(
        f"{n}={s['name']}{' (muted)' if s['mute'] else ''}"
        for n, s in enumerate(cfg["channels"], start=1)
    )
)

# --- Save ----------------------------------------------------------------------

bpy.ops.wm.save_as_mainfile(filepath=out_path, compress=True)
info(f"saved {out_path}")
