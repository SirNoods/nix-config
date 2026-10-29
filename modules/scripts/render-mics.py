# Renders every "Mic*" sequencer channel of a .blend to its own WAV.
#
# Run by normalize-mics:
#   blender --background --factory-startup project.blend \
#     --python-exit-code 1 --python render-mics.py -- <options>
#
# Why not Blender's own Mixdown operator: in 5.x it runs as a UI job on a
# worker thread. In background mode nothing ever finishes that job, and on
# exit Blender stops it, which cuts the file short. So Blender only reads the
# timeline here, and ffmpeg renders the audio.
#
# Blender's Python API doesn't expose two things this needs: which audio
# stream of a multi-track file a sound strip plays, and the sub-frame offset
# Blender adds when it syncs imported streams. Both are read from Blender's
# memory with ctypes, and every read is cross-checked against values the API
# does expose, so a layout change in a future Blender stops with an error
# instead of rendering the wrong thing.
#
# The bpy part only lives in collect(); the rest is plain Python so it can be
# tested without Blender.

import argparse
import json
import os
import re
import struct
import subprocess
import sys
import tempfile

MIC_PATTERN = re.compile(r"^mic", re.IGNORECASE)
SAMPLE_RATE = 48000


class LayoutError(RuntimeError):
    pass


def log(message):
    print(f"normalize-mics: {message}", flush=True)


# --- Reading Blender ------------------------------------------------------------

# Offsets in Blender 5.2's DNA structs (see makesdna/DNA_sequence_types.h and
# DNA_sound_types.h). Checked against known values before use.
STRIP_NAME = 16  # char name[64], RNA name skips a 2-char prefix
STRIP_START = 92  # float start
STRIP_CHANNEL = 112  # int channel
STRIP_STREAMINDEX = 132  # short streamindex

# bSound fields relative to the start of its filepath[1024] member.
SOUND_OFFSET_TIME = 1048  # double offset_time
SOUND_SAMPLERATE = 1084  # int samplerate
SOUND_STREAM_INDEX = 1090  # short stream_index


def strip_stream_index(strip):
    import ctypes

    raw = ctypes.string_at(strip.as_pointer(), STRIP_STREAMINDEX + 2)

    name = raw[STRIP_NAME + 2 : STRIP_NAME + 64].split(b"\0", 1)[0].decode("utf-8", "replace")
    (start,) = struct.unpack_from("<f", raw, STRIP_START)
    (channel,) = struct.unpack_from("<i", raw, STRIP_CHANNEL)
    (stream,) = struct.unpack_from("<h", raw, STRIP_STREAMINDEX)

    if name != strip.name or channel != strip.channel or abs(start - strip.frame_start) > 1e-3:
        raise LayoutError(
            f"strip '{strip.name}': Blender's internal strip layout doesn't match "
            f"what this script expects (Blender {__import__('bpy').app.version_string})"
        )

    return stream


def sound_offset_time(sound, expected_stream):
    import ctypes

    ptr = sound.as_pointer()
    path = sound.filepath.encode("utf-8") + b"\0"

    # The filepath member starts somewhere after the ID header; find it. The
    # struct is always larger than 1024 bytes, so this read stays inside it.
    head = ctypes.string_at(ptr, 1024)
    candidates = [i for i in range(0, 1024 - len(path) + 1, 8) if head.startswith(path, i)]

    for start in candidates if sound.filepath else []:
        tail = ctypes.string_at(ptr + start + SOUND_OFFSET_TIME, SOUND_STREAM_INDEX - SOUND_OFFSET_TIME + 2)
        (offset_time,) = struct.unpack_from("<d", tail, 0)
        (samplerate,) = struct.unpack_from("<i", tail, SOUND_SAMPLERATE - SOUND_OFFSET_TIME)
        (stream,) = struct.unpack_from("<h", tail, SOUND_STREAM_INDEX - SOUND_OFFSET_TIME)

        if samplerate == sound.samplerate and stream == expected_stream and abs(offset_time) < 10:
            return offset_time

    raise LayoutError(
        f"sound '{sound.name}': couldn't find its sync offset in Blender's memory "
        f"(Blender {__import__('bpy').app.version_string})"
    )


def channel_lookup(editor):
    channels = editor.channels
    # Strips use channels 1..128; the collection may or may not include channel 0.
    offset = 0 if len(channels) > 128 else -1
    return lambda number: channels[number + offset]


def collect(project_dir):
    """Reads the timeline into plain data. Needs bpy."""
    import bpy

    scene = bpy.context.scene
    editor = scene.sequence_editor
    fps = scene.render.fps / scene.render.fps_base
    warnings = []

    if editor is None:
        return {"fps": fps, "frame_start": scene.frame_start, "frame_end": scene.frame_end, "channels": [], "warnings": []}

    channel = channel_lookup(editor)
    out_dir = os.path.realpath(os.path.join(project_dir, "mics", "out"))

    mic_numbers = [n for n in range(1, 129) if MIC_PATTERN.match(channel(n).name)]
    result = []

    for number in mic_numbers:
        name = channel(number).name
        strips = []
        skipped_normalized = 0

        for strip in editor.strips_all:
            if strip.channel != number:
                continue

            # Strips inside meta strips report the meta's inner channels; only
            # take top-level strips.
            if strip not in editor.strips[:]:
                continue

            if strip.type != "SOUND":
                warnings.append(f"{name}: skipping {strip.type.lower()} strip '{strip.name}' (only sound strips are rendered)")
                continue

            if strip.mute or strip.sound is None:
                continue

            path = os.path.realpath(bpy.path.abspath(strip.sound.filepath, library=strip.sound.library))

            if path.startswith(out_dir + os.sep):
                skipped_normalized += 1
                continue

            if strip.sound.packed_file is not None:
                warnings.append(f"{name}: skipping '{strip.name}', its sound is packed into the .blend")
                continue

            stream = strip_stream_index(strip)

            strips.append(
                {
                    "name": strip.name,
                    "path": path,
                    "stream": stream,
                    "left": strip.frame_final_start,
                    "right": strip.frame_final_end,
                    "frameskip": strip.frame_offset_start + strip.animation_offset_start,
                    "offset_time": sound_offset_time(strip.sound, stream),
                    "sound_offset": strip.sound_offset,
                    "volume": strip.volume,
                    "mono": strip.sound.use_mono,
                }
            )

        if not strips:
            if skipped_normalized:
                log(f"channel {number} '{name}': only holds normalized files, skipping")
            else:
                log(f"channel {number} '{name}': no sound strips, skipping")
            continue

        result.append({"number": number, "name": name, "strips": strips})

    if scene.animation_data is not None:
        warnings.append("the scene has animation data; volume keyframes and fades are not applied to the rendered mics")

    return {
        "fps": fps,
        "frame_start": scene.frame_start,
        "frame_end": scene.frame_end,
        "channels": result,
        "warnings": warnings,
    }


# --- Planning (plain Python) -----------------------------------------------------


def safe_filename(name):
    name = re.sub(r"\s+", "_", name.strip())
    name = re.sub(r"[^A-Za-z0-9_.()+-]", "_", name)
    return name or "Mic"


def output_names(channels, suffix):
    names = {}
    taken = {}

    for ch in channels:
        base = safe_filename(ch["name"])
        taken[base] = taken.get(base, 0) + 1

    for ch in channels:
        base = safe_filename(ch["name"])
        if taken[base] > 1:
            base = f"{base}_ch{ch['number']}"
        names[ch["number"]] = f"{base}{suffix}.wav"

    return names


def timeline_range(data):
    """Seconds from the scene start to the end of the last mic strip (or scene end)."""
    fps = data["fps"]
    start = data["frame_start"] / fps
    end = (data["frame_end"] + 1) / fps

    for ch in data["channels"]:
        for s in ch["strips"]:
            end = max(end, s["right"] / fps)

    return start, end


def plan_channel(channel, fps, range_start, range_end, probe):
    """
    Turns a channel's strips into segments of (file, stream, seek, timeline
    sample position, length in samples, volume). Mirrors Blender's
    BKE_sound_add_scene_sound: file position p plays at
    left/fps + offset + p, where
    offset = sound.offset_time + strip.sound_offset - frameskip/fps,
    clipped to [left/fps, right/fps).
    """
    segments = []
    total = round((range_end - range_start) * SAMPLE_RATE)

    for s in sorted(channel["strips"], key=lambda s: s["left"]):
        a = s["left"] / fps
        b = s["right"] / fps
        offset = s["offset_time"] + s["sound_offset"] - s["frameskip"] / fps

        play_from = a + max(offset, 0.0)  # timeline time where audio starts
        file_pos = max(-offset, 0.0)  # position in the decoded stream there

        # Clip to the rendered range.
        if play_from < range_start:
            file_pos += range_start - play_from
            play_from = range_start

        b = min(b, range_end)

        start_sample = round((play_from - range_start) * SAMPLE_RATE)
        end_sample = round((b - range_start) * SAMPLE_RATE)

        if end_sample <= start_sample:
            continue

        info = probe(s["path"], s["stream"])

        segments.append(
            {
                "name": s["name"],
                "path": s["path"],
                "stream": s["stream"],
                # Blender's position 0 is the stream's own first sample; ffmpeg
                # seeks in container time relative to the file's start.
                "seek": info["stream_start"] - info["format_start"] + file_pos,
                "at": start_sample,
                "length": end_sample - start_sample,
                "volume": s["volume"],
                "mono": s["mono"],
            }
        )

    segments.sort(key=lambda seg: seg["at"])

    for prev, cur in zip(segments, segments[1:]):
        if cur["at"] < prev["at"] + prev["length"]:
            raise ValueError(f"{channel['name']}: strips '{prev['name']}' and '{cur['name']}' overlap")

    return segments, total


def ffmpeg_command(ffmpeg, segments, total, out_path):
    """One ffmpeg run that lays the segments end to end with silence between."""
    args = [ffmpeg, "-hide_banner", "-nostdin", "-loglevel", "error", "-stats", "-y"]
    parts = []
    labels = []
    cursor = 0
    fmt = f"aresample={SAMPLE_RATE},aformat=sample_fmts=fltp:sample_rates={SAMPLE_RATE}:channel_layouts=stereo"

    for i, seg in enumerate(segments):
        args += ["-ss", f"{seg['seek']:.6f}", "-i", seg["path"]]

        gap = seg["at"] - cursor
        if gap > 0:
            parts.append(f"anullsrc=r={SAMPLE_RATE}:cl=stereo,atrim=end_sample={gap},aformat=sample_fmts=fltp[g{i}]")
            labels.append(f"[g{i}]")

        chain = [fmt]
        if seg["mono"]:
            chain.append("pan=stereo|c0=0.5*c0+0.5*c1|c1=0.5*c0+0.5*c1")
        if abs(seg["volume"] - 1.0) > 1e-6:
            chain.append(f"volume={seg['volume']:.6f}")
        # Pad short reads with silence and cut long ones, so every segment is
        # exactly as long as on the timeline and nothing after it drifts.
        chain.append(f"apad=whole_len={seg['length']},atrim=end_sample={seg['length']}")

        parts.append(f"[{i}:a:{seg['stream']}]{','.join(chain)}[s{i}]")
        labels.append(f"[s{i}]")
        cursor = seg["at"] + seg["length"]

    if not labels:
        args += ["-f", "lavfi", "-i", f"anullsrc=r={SAMPLE_RATE}:cl=stereo"]
        graph = f"[0:a]atrim=end_sample={total}[out]"
    else:
        graph = ";".join(parts)
        graph += f";{''.join(labels)}concat=n={len(labels)}:v=0:a=1,apad=whole_len={total},atrim=end_sample={total}[out]"

    args += [
        "-filter_complex",
        graph,
        "-map",
        "[out]",
        "-c:a",
        "pcm_s16le",
        "-rf64",
        "auto",
        "-fflags",
        "+bitexact",
        "-flags:a",
        "+bitexact",
        out_path,
    ]
    return args


def make_probe(ffprobe):
    cache = {}

    def probe(path, stream):
        if path not in cache:
            out = subprocess.run(
                [
                    ffprobe,
                    "-v",
                    "error",
                    "-show_entries",
                    "format=start_time:stream=codec_type,start_time",
                    "-of",
                    "json",
                    path,
                ],
                check=True,
                capture_output=True,
                text=True,
            ).stdout
            cache[path] = json.loads(out)

        info = cache[path]
        audio = [s for s in info.get("streams", []) if s.get("codec_type") == "audio"]

        if stream >= len(audio):
            raise ValueError(f"{path} has no audio stream {stream} (it has {len(audio)})")

        def num(value):
            try:
                return float(value)
            except (TypeError, ValueError):
                return 0.0

        return {
            "format_start": num(info.get("format", {}).get("start_time")),
            "stream_start": num(audio[stream].get("start_time")),
        }

    return probe


def render(data, project_dir, suffix, ffmpeg, ffprobe, list_only):
    for w in data["warnings"]:
        log(f"note: {w}")

    channels = data["channels"]
    if not channels:
        log("no Mic channels with sound strips found, nothing to render")
        return 0

    fps = data["fps"]
    range_start, range_end = timeline_range(data)
    names = output_names(channels, suffix)
    probe = make_probe(ffprobe)
    mics_dir = os.path.join(project_dir, "mics")
    os.makedirs(mics_dir, exist_ok=True)

    log(
        f"range: frame {data['frame_start']} to {round(range_end * fps) - 1} "
        f"({(range_end - range_start) / 60:.1f} min); "
        f"normalized files go back at frame {data['frame_start']}"
    )

    for ch in channels:
        segments, total = plan_channel(ch, fps, range_start, range_end, probe)
        out_path = os.path.join(mics_dir, names[ch["number"]])

        log(f"channel {ch['number']} '{ch['name']}' -> mics/{names[ch['number']]} ({len(segments)} strip(s))")

        if list_only:
            for seg in segments:
                log(
                    f"    {seg['name']}: {os.path.basename(seg['path'])} audio stream {seg['stream']}, "
                    f"from {seg['seek']:.3f}s, at {seg['at'] / SAMPLE_RATE:.3f}s for {seg['length'] / SAMPLE_RATE:.3f}s"
                )
            continue

        # Render to a temp file and only replace the old one if the audio
        # changed, so normalization can skip unchanged mics.
        fd, tmp_path = tempfile.mkstemp(prefix=".render-", suffix=".wav", dir=mics_dir)
        os.close(fd)

        try:
            subprocess.run(ffmpeg_command(ffmpeg, segments, total, tmp_path), check=True)

            if os.path.exists(out_path) and _same_file(out_path, tmp_path):
                log("    unchanged since last render")
                os.remove(tmp_path)
            else:
                os.replace(tmp_path, out_path)
        except BaseException:
            if os.path.exists(tmp_path):
                os.remove(tmp_path)
            raise

    return 0


def _same_file(a, b):
    if os.path.getsize(a) != os.path.getsize(b):
        return False

    with open(a, "rb") as fa, open(b, "rb") as fb:
        while True:
            ca = fa.read(1 << 20)
            cb = fb.read(1 << 20)
            if ca != cb:
                return False
            if not ca:
                return True


def main(argv):
    parser = argparse.ArgumentParser(prog="render-mics.py")
    parser.add_argument("--project", required=True)
    parser.add_argument("--suffix", default="_prenormalized")
    parser.add_argument("--ffmpeg", default="ffmpeg")
    parser.add_argument("--ffprobe", default="ffprobe")
    parser.add_argument("--list", action="store_true")
    args = parser.parse_args(argv)

    try:
        data = collect(args.project)
        return render(data, args.project, args.suffix, args.ffmpeg, args.ffprobe, args.list)
    except (LayoutError, ValueError, subprocess.CalledProcessError) as e:
        log(f"ERROR: {e}")
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []))
