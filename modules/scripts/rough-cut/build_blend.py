# Builds an epcut rough cut into a project .blend (Blender Video Sequencer).
#
# Run by `epcut build`, not by hand:
#   blender -b -t 1 --factory-startup project.blend \
#     --python-exit-code 1 --python build_blend.py -- work/build_job.json
#
# What it does:
#   - If no scene in the file has any strips (a fresh obs-split template), the
#     rough cut goes into the active scene and the project .blend is saved in
#     place. Otherwise the active scene is cleared in memory only and the
#     result is saved as <project>_roughcut.blend, so an edited project file
#     is never touched.
#   - Each plan segment becomes a video strip on the "Video" channel plus
#     sound strips on the "Mic", "Game" and "Discord" channels, all cut to the
#     same range. Channels are found by name, so the template's layout decides
#     where things go. Mic strips are plain sound strips, so normalize-mics
#     picks them up.
#   - Chapter and segment markers go on the timeline; montage segments get a
#     colour tag and a "MONTAGE" name prefix.
#
# Prints "EPCUT: ..." lines for the CLI and one "EPCUT_RESULT {json}" line.

import json
import os
import sys

import bpy

SCRATCH_CHANNEL = 127
MONTAGE_COLOR = "COLOR_05"


def say(msg):
    print(f"EPCUT: {msg}", flush=True)


def strips_of(se):
    return se.strips if hasattr(se, "strips") else se.sequences


def all_strips_of(se):
    return se.strips_all if hasattr(se, "strips_all") else se.sequences_all


def channel_lookup(se):
    channels = se.channels
    # Strips use channels 1..128; the collection may or may not include channel 0.
    offset = 0 if len(channels) > 128 else -1
    return lambda number: channels[number + offset]


def set_range(strip, left, right):
    """Trim a strip to [left, right) in timeline frames without moving its content."""
    if hasattr(strip, "left_handle"):
        strip.left_handle = left
        strip.right_handle = right
    else:
        strip.frame_final_start = left
        strip.frame_final_end = right


def get_range(strip):
    if hasattr(strip, "left_handle"):
        return strip.left_handle, strip.right_handle
    return strip.frame_final_start, strip.frame_final_end


def main():
    job = json.load(open(sys.argv[sys.argv.index("--") + 1]))
    notes = []

    used = [s.name for s in bpy.data.scenes
            if s.sequence_editor is not None and len(all_strips_of(s.sequence_editor)) > 0]
    scene = bpy.context.scene
    if used:
        mode, out = "new", job["roughcut"]
        if os.path.exists(out) and not job["force"]:
            raise RuntimeError(f"{out} exists")
    else:
        mode, out = "inplace", job["blend"]

    se = scene.sequence_editor or scene.sequence_editor_create()
    strips = strips_of(se)
    if mode == "new":
        for strip in list(strips):
            strips.remove(strip)
        scene.timeline_markers.clear()
    channel = channel_lookup(se)

    fps = scene.render.fps / scene.render.fps_base
    for name, rec in job["recordings"].items():
        if abs(rec["fps"] - fps) > 0.01:
            raise RuntimeError(f"{name} is {rec['fps']} fps but the scene is {fps:g} fps; "
                               "retiming is not supported, re-record or change the scene frame rate")

    # Find channels by name (case-insensitive prefix), first match wins.
    names = {n: channel(n).name for n in range(1, 129)}
    targets = {}
    for role, wanted in job["channels"].items():
        hit = next((n for n in range(1, 129) if names[n].lower() == wanted.lower()), None)
        if hit is None:
            hit = next((n for n in range(1, 129) if names[n].lower().startswith(wanted.lower())), None)
        targets[role] = hit
    # Roles without a channel get the lowest free, unnamed channel above all named ones.
    named = [n for n in range(1, 129) if not names[n].startswith("Channel")]
    free = max(named, default=0) + 1
    for role in job["channels"]:
        if targets[role] is None:
            if free >= SCRATCH_CHANNEL:
                raise RuntimeError(f"no free channel for {role}")
            targets[role] = free
            channel(free).name = job["channels"][role]
            notes.append(f"no '{job['channels'][role]}' channel in the template, made channel {free}")
            free += 1
    say("channels: " + ", ".join(f"{r} -> {n} '{channel(n).name}'" for r, n in targets.items()))

    def place(strip, at, src_frames, length, target):
        strip.frame_start = at - src_frames
        set_range(strip, at, at + length)
        strip.channel = target
        left, right = get_range(strip)
        if strip.channel != target or abs(left - at) > 0 or abs(right - (at + length)) > 0:
            raise RuntimeError(f"strip '{strip.name}' landed on channel {strip.channel} "
                               f"frames {left}-{right}, wanted {target} {at}-{at + length}")

    cursor = scene.frame_start
    gap = round(job.get("chapter_gap", 0) * fps)
    chapter = None
    placed = 0
    for i, seg in enumerate(job["segments"], 1):
        rec = job["recordings"][seg["recording"]]
        if seg["chapter"] != chapter:
            if chapter is not None:
                cursor += gap
            chapter = seg["chapter"]
            title = job["chapters"][chapter]["title"]
            scene.timeline_markers.new(title[:60], frame=cursor)

        src = round(seg["start"] * fps)
        length = round(seg["end"] * fps) - src
        if length <= 0:
            continue
        montage = seg["kind"] == "montage"
        label = f"{i:02d} {'MONTAGE ' if montage else ''}{seg['title']}"[:60]

        video = strips.new_movie(label, rec["file"], SCRATCH_CHANNEL, 1)
        place(video, cursor, src, length, targets["video"])
        if rec["proxy_sizes"]:
            try:
                video.use_proxy = True
                for size in rec["proxy_sizes"]:
                    setattr(video.proxy, f"build_{size}", True)
            except AttributeError as e:
                notes.append(f"couldn't switch on proxies: {e}")
        made = [video]

        for role, path in rec["audio"].items():
            if role not in targets or not os.path.exists(path):
                continue
            sound = strips.new_sound(f"{label} {role}"[:60], path, SCRATCH_CHANNEL, 1)
            place(sound, cursor, src, length, targets[role])
            sound.volume = job["volumes"].get(role, 1.0)
            made.append(sound)

        if montage:
            for strip in made:
                try:
                    strip.color_tag = MONTAGE_COLOR
                except (AttributeError, TypeError):
                    pass
        scene.timeline_markers.new(f"{i:02d}", frame=cursor)
        cursor += length
        placed += 1

    scene.frame_end = cursor - 1
    say(f"placed {placed} segments, {(cursor - scene.frame_start) / fps / 60:.1f} min")

    result = bpy.ops.wm.save_as_mainfile(filepath=out)
    if "FINISHED" not in result:
        raise RuntimeError(f"saving {out} failed: {result}")
    print("EPCUT_RESULT " + json.dumps({
        "mode": mode, "out": out, "scene": scene.name, "segments": placed,
        "seconds": (cursor - scene.frame_start) / fps, "notes": notes,
    }), flush=True)


try:
    main()
except Exception as e:  # noqa: BLE001
    import traceback
    traceback.print_exc()
    print(f"EPCUT: ERROR: {e}", flush=True)
    sys.exit(1)
