#!/usr/bin/env python3
"""epcut: transcript-driven rough cuts for solo recording projects.

Works on the project folders obs-pull makes:

    <project>/<project>.blend        made from the obs-split Blender template
    <project>/footage/rec_NN.mp4     OBS recordings, numbered in recording order
    <project>/footage/manifest.tsv   original OBS file names (recording timestamps)

Everything epcut writes goes into <project>/work/. It never modifies footage/,
and it never overwrites a .blend that already has strips in it.

Commands (run inside the project folder, or pass -C <folder>):

    epcut doctor                  check tools, model, project layout
    epcut prep                    probe recordings, extract audio tracks to work/audio/
    epcut transcribe              transcribe the configured tracks (long, resumable)
    epcut status                  what's done and what isn't
    epcut frames rec_03 0:12:30   grab still frames to work/frames/
    epcut sheet rec_03 0:10:00 0:25:00
                                  8 frames across a span, tiled into one image
    epcut plan                    check work/edit_plan.md and print the runtime
    epcut build                   build the rough cut into the .blend

Settings come from built-in defaults, then the JSON file in $EPCUT_DEFAULTS
(written by the home-manager module), then <project>/epcut.json.

Plain Python 3 standard library only; ffmpeg, ffprobe, whisper-cli and
Blender are called as programs.
"""

import argparse
import datetime
import glob
import json
import math
import os
import re
import shutil
import subprocess
import sys
import time
import wave

# --------------------------------------------------------------------------
# Settings
# --------------------------------------------------------------------------

DEFAULTS = {
    # OBS track numbers (1-based, as OBS shows them) for each role. A role
    # whose track is missing from a recording is skipped with a warning.
    "tracks": {"mic": 4, "game": 3, "discord": 2},
    # Which roles get transcribed, and how they're labelled in the transcript.
    "transcribe": ["mic", "discord"],
    "labels": {"mic": "me", "discord": "discord", "game": "game"},
    # Sequencer channel names to look for in the .blend (case-insensitive,
    # prefix match). A role with no matching channel gets a free channel named
    # after it. Leave a role out to keep it off the timeline.
    "channels": {"video": "Video", "mic": "Mic", "game": "Game", "discord": "Discord"},
    "volumes": {"mic": 1.0, "game": 1.0, "discord": 1.0},
    "footage_glob": "rec_*",
    "whisper": {
        "binary": "whisper-cli",
        "model": "~/.cache/whisper-models/ggml-large-v3-turbo.bin",
        "language": "en",
        "threads": 0,  # 0 = all cores
        "batch": 16,  # packs per whisper-cli run
    },
    # Speech detection on each extracted track before whisper sees it.
    "vad": {
        "threshold_db": -45.0,
        "min_silence": 0.6,
        "pad": 0.25,
        "merge_gap": 0.8,
        "min_speech": 0.3,
    },
    "pack_seconds": 28.0,
    "transcript_gap_marker": 45.0,  # seconds of no talking that get a marker line
    "target_minutes": 30,
    "montage_default_seconds": 60,
    "chapter_gap_seconds": 0.0,
    "blender": "blender",
    "blender_threads": 1,
}

SPEECH_FILTER = re.compile(r"^[\s\W]*(you|thank you|thanks for watching|bye|okay)?[\s\W]*$", re.I)
SPECIAL_TOKEN = re.compile(r"^(\[_.*\]|<\|.*\|>)$")
VIDEO_EXTS = {".mp4", ".mkv", ".mov", ".flv", ".m4v"}


def merge(base, extra):
    out = dict(base)
    for key, value in extra.items():
        if isinstance(value, dict) and isinstance(out.get(key), dict):
            out[key] = merge(out[key], value)
        else:
            out[key] = value
    return out


def load_settings(project):
    cfg = DEFAULTS
    env = os.environ.get("EPCUT_DEFAULTS")
    if env and os.path.exists(env):
        cfg = merge(cfg, json.load(open(env)))
    local = os.path.join(project, "epcut.json")
    if os.path.exists(local):
        cfg = merge(cfg, json.load(open(local)))
    cfg["whisper"]["model"] = os.path.expanduser(cfg["whisper"]["model"])
    return cfg


# --------------------------------------------------------------------------
# Small helpers
# --------------------------------------------------------------------------


def log(msg):
    print(msg, flush=True)


def die(msg):
    print(f"epcut: {msg}", file=sys.stderr, flush=True)
    sys.exit(1)


def fmt_time(t, decimals=1):
    sign = "-" if t < 0 else ""
    t = abs(t)
    h = int(t // 3600)
    m = int(t % 3600 // 60)
    s = t % 60
    if decimals:
        return f"{sign}{h}:{m:02d}:{s:0{3 + decimals}.{decimals}f}"
    return f"{sign}{h}:{m:02d}:{int(s):02d}"


def parse_time(text):
    text = text.strip().strip("`")
    parts = text.split(":")
    if not 1 <= len(parts) <= 3:
        raise ValueError(f"bad time: {text}")
    total = 0.0
    for p in parts:
        total = total * 60 + float(p)
    return total


def fmt_dur(seconds):
    seconds = int(round(seconds))
    if seconds >= 3600:
        return f"{seconds // 3600}h{seconds % 3600 // 60:02d}m"
    return f"{seconds // 60}:{seconds % 60:02d}"


def run(cmd, **kw):
    return subprocess.run(cmd, check=True, **kw)


def ffprobe_json(path):
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries",
         "format=duration,start_time:stream=index,codec_type,codec_name,avg_frame_rate,r_frame_rate,"
         "start_time,duration,width,height,channels,sample_rate",
         "-of", "json", path],
        check=True, capture_output=True, text=True).stdout
    return json.loads(out)


def num(value, default=0.0):
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def rate(text):
    if not text or text in ("0/0",):
        return 0.0
    if "/" in text:
        a, b = text.split("/")
        return float(a) / float(b) if float(b) else 0.0
    return float(text)


# --------------------------------------------------------------------------
# Project
# --------------------------------------------------------------------------


class Project:
    def __init__(self, root):
        self.root = os.path.realpath(root)
        self.name = os.path.basename(self.root)
        self.cfg = load_settings(self.root)
        self.footage = os.path.join(self.root, "footage")
        self.work = os.path.join(self.root, "work")

    def path(self, *parts):
        return os.path.join(self.work, *parts)

    def recordings(self):
        files = sorted(glob.glob(os.path.join(self.footage, self.cfg["footage_glob"])))
        files = [f for f in files if os.path.splitext(f)[1].lower() in VIDEO_EXTS]
        return [(os.path.splitext(os.path.basename(f))[0], f) for f in files]

    def blend(self):
        own = os.path.join(self.root, f"{self.name}.blend")
        if os.path.exists(own):
            return own
        blends = [b for b in glob.glob(os.path.join(self.root, "*.blend")) if not b.endswith("_roughcut.blend")]
        if len(blends) == 1:
            return blends[0]
        if not blends:
            die(f"no .blend in {self.root}")
        die("several .blend files here; name one <project>.blend")

    def inventory(self, required=True):
        p = self.path("inventory.json")
        if not os.path.exists(p):
            if required:
                die("no work/inventory.json yet; run `epcut prep` first")
            return None
        return json.load(open(p))

    def manifest(self):
        p = os.path.join(self.footage, "manifest.tsv")
        result = {}
        if os.path.exists(p):
            for line in open(p).read().splitlines()[1:]:
                if "\t" in line:
                    f, orig = line.split("\t", 1)
                    result[os.path.splitext(f)[0]] = orig
        return result


def recorded_at(original):
    m = re.match(r"(\d{4}-\d{2}-\d{2})[_ ](\d{2})-(\d{2})-(\d{2})", original or "")
    if not m:
        return None
    return f"{m.group(1)} {m.group(2)}:{m.group(3)}:{m.group(4)}"


# --------------------------------------------------------------------------
# doctor
# --------------------------------------------------------------------------


def cmd_doctor(proj, args):
    ok = True
    for tool in ("ffmpeg", "ffprobe", proj.cfg["whisper"]["binary"], proj.cfg["blender"]):
        found = shutil.which(tool)
        log(f"{'ok ' if found else 'MISSING'}  {tool}{'  ' + found if found else ''}")
        ok &= bool(found)
    model = proj.cfg["whisper"]["model"]
    exists = os.path.exists(model)
    log(f"{'ok ' if exists else 'MISSING'}  whisper model {model}")
    ok &= exists
    log(f"     DTW preset: {dtw_preset(model) or 'none (segment-level timing only)'}")
    recs = proj.recordings()
    log(f"{'ok ' if recs else 'MISSING'}  {len(recs)} recordings in footage/")
    ok &= bool(recs)
    try:
        log(f"ok   blend: {os.path.basename(proj.blend())}")
    except SystemExit:
        ok = False
    free = shutil.disk_usage(proj.root).free / 1e9
    log(f"     {free:.0f} GB free")
    if os.environ.get("LD_LIBRARY_PATH"):
        log("note: LD_LIBRARY_PATH is set (dev shell?). epcut unsets it for Blender.")
    return 0 if ok else 1


# --------------------------------------------------------------------------
# prep: probe and extract audio
# --------------------------------------------------------------------------


def cmd_prep(proj, args):
    recs = proj.recordings()
    if not recs:
        die("no recordings in footage/")
    os.makedirs(proj.path("audio"), exist_ok=True)
    manifest = proj.manifest()
    tracks = proj.cfg["tracks"]
    old = proj.inventory(required=False) or {"recordings": []}
    old_by_name = {r["name"]: r for r in old["recordings"]}

    total = sum(num(ffprobe_json(f)["format"].get("duration")) for _, f in recs)
    need_gb = total * 48000 * 2 * 2 * len(tracks) * 0.6 / 1e9
    free_gb = shutil.disk_usage(proj.root).free / 1e9
    log(f"{len(recs)} recordings, {fmt_dur(total)} in total; audio needs about {need_gb:.1f} GB, {free_gb:.0f} GB free")
    if free_gb < need_gb * 1.5:
        die("not enough free disk space for the audio tracks")

    inventory = []
    for name, path in recs:
        info = ffprobe_json(path)
        video = [s for s in info["streams"] if s["codec_type"] == "video"]
        audio = [s for s in info["streams"] if s["codec_type"] == "audio"]
        if not video:
            log(f"{name}: no video stream, skipped")
            continue
        v = video[0]
        v_start = num(v.get("start_time"))
        entry = {
            "name": name,
            "file": os.path.relpath(path, proj.root),
            "original": manifest.get(name),
            "recorded_at": recorded_at(manifest.get(name)),
            "duration": num(v.get("duration")) or num(info["format"].get("duration")),
            "fps": round(rate(v.get("avg_frame_rate")) or rate(v.get("r_frame_rate")), 3),
            "width": v.get("width"),
            "height": v.get("height"),
            "audio_tracks": len(audio),
            "audio": {},
        }

        mtime = os.path.getmtime(path)
        outputs = []
        for role, track in tracks.items():
            idx = int(track) - 1
            if idx >= len(audio):
                log(f"{name}: OBS track {track} ({role}) missing, file has {len(audio)} audio tracks")
                continue
            a = audio[idx]
            delta = num(a.get("start_time")) - v_start
            out = proj.path("audio", f"{role}_{name}.flac")
            entry["audio"][role] = {
                "path": os.path.relpath(out, proj.root),
                "stream": idx,
                "offset": round(delta, 6),
                "channels": a.get("channels"),
            }
            if os.path.exists(out) and os.path.getmtime(out) >= mtime and not args.force:
                continue
            # Align so that time 0 in the extracted file is the first video frame.
            if delta > 0.0005:
                af = f"adelay=delays={delta * 1000:.3f}:all=1"
            elif delta < -0.0005:
                af = f"atrim=start={-delta:.6f},asetpts=PTS-STARTPTS"
            else:
                af = "anull"
            outputs.append((out, idx, af))

        if outputs:
            cmd = ["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", path]
            for out, idx, af in outputs:
                cmd += ["-map", f"0:a:{idx}", "-af", af, "-c:a", "flac", "-sample_fmt", "s16",
                        "-f", "flac", out + ".part"]
            log(f"{name}: extracting {', '.join(os.path.basename(o) for o, _, _ in outputs)}")
            run(cmd)
            for out, _, _ in outputs:
                os.replace(out + ".part", out)
        else:
            log(f"{name}: audio up to date")

        if name in old_by_name and "speech" in old_by_name[name]:
            entry["speech"] = old_by_name[name]["speech"]
        inventory.append(entry)

    fps = {r["fps"] for r in inventory}
    data = {"project": proj.name, "fps": sorted(fps), "recordings": inventory}
    json.dump(data, open(proj.path("inventory.json"), "w"), indent=1)
    log(f"wrote work/inventory.json ({len(inventory)} recordings, fps {', '.join(map(str, sorted(fps)))})")
    if len(fps) > 1:
        log("WARNING: recordings have different frame rates; the build needs them to match the .blend")
    return 0


# --------------------------------------------------------------------------
# transcribe
# --------------------------------------------------------------------------


def dtw_preset(model_path):
    stem = os.path.basename(model_path).lower()
    stem = re.sub(r"^ggml-", "", stem)
    stem = re.sub(r"\.bin$", "", stem)
    stem = re.sub(r"-q\d.*$", "", stem)
    preset = stem.replace("-", ".")
    known = {"tiny", "tiny.en", "base", "base.en", "small", "small.en", "medium", "medium.en",
             "large.v1", "large.v2", "large.v3", "large.v3.turbo"}
    return preset if preset in known else None


def speech_regions(wav_path, duration, vad):
    """Speech stretches as (start, end) seconds, from ffmpeg silencedetect."""
    res = subprocess.run(
        ["ffmpeg", "-nostdin", "-hide_banner", "-i", wav_path, "-af",
         f"silencedetect=n={vad['threshold_db']}dB:d={vad['min_silence']}", "-f", "null", "-"],
        capture_output=True, text=True)
    silences = []
    start = None
    for line in res.stderr.splitlines():
        m = re.search(r"silence_start: (-?[\d.]+)", line)
        if m:
            start = max(0.0, float(m.group(1)))
        m = re.search(r"silence_end: (-?[\d.]+)", line)
        if m and start is not None:
            silences.append((start, float(m.group(1))))
            start = None
    if start is not None:
        silences.append((start, duration))

    speech = []
    cursor = 0.0
    for a, b in silences:
        if a > cursor:
            speech.append((cursor, a))
        cursor = max(cursor, b)
    if cursor < duration:
        speech.append((cursor, duration))

    padded = [(max(0.0, a - vad["pad"]), min(duration, b + vad["pad"])) for a, b in speech]
    merged = []
    for a, b in padded:
        if merged and a - merged[-1][1] <= vad["merge_gap"]:
            merged[-1] = (merged[-1][0], max(merged[-1][1], b))
        else:
            merged.append((a, b))
    return [(a, b) for a, b in merged if b - a >= vad["min_speech"]]


def make_packs(regions, pack_seconds, gap=0.4, lead=0.2):
    """Groups speech regions into windows whisper can take in one go.

    Returns a list of packs; each pack is a list of pieces (src_start, src_end)
    laid out back to back with `gap` seconds of silence between them.
    """
    max_piece = pack_seconds - lead - 1.0
    pieces = []
    for a, b in regions:
        while b - a > max_piece:
            pieces.append((a, a + max_piece - 3.0))
            a = a + max_piece - 3.0
        pieces.append((a, b))

    packs = []
    current = []
    used = lead
    for a, b in pieces:
        length = b - a
        extra = length + (gap if current else 0.0)
        if current and used + extra > pack_seconds:
            packs.append(current)
            current, used = [], lead
            extra = length
        current.append((a, b))
        used += extra
    if current:
        packs.append(current)
    return packs


def pack_layout(pack, gap=0.4, lead=0.2):
    """Where each piece of a pack sits inside the pack file: (pack_t0, pack_t1, src_t0)."""
    layout = []
    t = lead
    for a, b in pack:
        layout.append((t, t + (b - a), a))
        t += (b - a) + gap
    return layout


def write_pack(src_wav, pack, out_path, gap=0.4, lead=0.2):
    with wave.open(src_wav, "rb") as src:
        sr = src.getframerate()
        width = src.getsampwidth() * src.getnchannels()
        with wave.open(out_path, "wb") as dst:
            dst.setparams(src.getparams())
            dst.writeframes(b"\0" * int(lead * sr) * width)
            for i, (a, b) in enumerate(pack):
                if i:
                    dst.writeframes(b"\0" * int(round(gap * sr)) * width)
                start = int(round(a * sr))
                count = int(round(b * sr)) - start
                src.setpos(start)
                dst.writeframes(src.readframes(count))


def unpack_tokens(result, layout):
    """Turns whisper-cli -ojf output for one pack into lines in source time."""

    def owner(t):
        best, dist = 0, float("inf")
        for i, (p0, p1, _) in enumerate(layout):
            if p0 <= t <= p1:
                return i
            d = min(abs(t - p0), abs(t - p1))
            if d < dist:
                best, dist = i, d
        return best

    def to_source(i, t):
        p0, p1, s0 = layout[i]
        return s0 + min(max(t - p0, 0.0), p1 - p0)

    lines = []
    for seg in result.get("transcription", []):
        cur = None
        for tok in seg.get("tokens", []):
            text = tok.get("text", "")
            if not text.strip() or SPECIAL_TOKEN.match(text.strip()):
                continue
            t_dtw = tok.get("t_dtw", -1)
            if t_dtw is not None and t_dtw >= 0:
                t = t_dtw / 100.0
            else:
                off = tok.get("offsets", {})
                t = (off.get("from", 0) + off.get("to", 0)) / 2000.0
            i = owner(t)
            src = to_source(i, t)
            if cur is not None and cur["piece"] == i:
                cur["text"] += text
                cur["end"] = max(cur["end"], src)
            else:
                if cur is not None:
                    lines.append(cur)
                cur = {"piece": i, "start": src, "end": src, "text": text}
        if cur is not None:
            lines.append(cur)

    out = []
    for line in lines:
        text = re.sub(r"\s+", " ", line["text"]).strip()
        if not text or SPEECH_FILTER.match(text):
            continue
        p0, p1, s0 = layout[line["piece"]]
        piece_end = s0 + (p1 - p0)
        out.append({"start": round(line["start"], 2),
                    "end": round(min(line["end"] + 0.4, piece_end), 2),
                    "text": text})
    return out


def run_whisper(cfg, files, dtw):
    w = cfg["whisper"]
    threads = int(w["threads"]) or os.cpu_count() or 4
    cmd = [w["binary"], "-m", w["model"], "-l", w["language"], "-t", str(threads),
           "-ojf", "-np", "-sns"]
    if dtw:
        cmd += ["-nfa", "-dtw", dtw]
    for f in files:
        cmd += ["-f", f]
    env = dict(os.environ)
    # One whisper process at a time, with its BLAS threads pinned to the same
    # count. Several processes at once fight over the CPU and run far slower.
    for var in ("OPENBLAS_NUM_THREADS", "OMP_NUM_THREADS", "MKL_NUM_THREADS"):
        env[var] = str(threads)
    res = subprocess.run(cmd, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    return res.returncode, res.stderr[-2000:]


def transcribe_one(proj, rec, role):
    cfg = proj.cfg
    audio = rec["audio"].get(role)
    if not audio:
        log(f"{rec['name']} {role}: no extracted track, skipped")
        return None
    out_path = proj.path("transcripts", f"{role}_{rec['name']}.json")
    if os.path.exists(out_path):
        return json.load(open(out_path))

    tmp = proj.path("tmp", f"{role}_{rec['name']}")
    os.makedirs(tmp, exist_ok=True)
    full = os.path.join(tmp, "full.wav")
    if not os.path.exists(full):
        run(["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
             "-i", os.path.join(proj.root, audio["path"]),
             "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", full + ".part.wav"])
        os.replace(full + ".part.wav", full)
    with wave.open(full, "rb") as wf:
        duration = wf.getnframes() / wf.getframerate()

    regions = speech_regions(full, duration, cfg["vad"])
    speech = sum(b - a for a, b in regions)
    packs = make_packs(regions, cfg["pack_seconds"])
    log(f"{rec['name']} {role}: {fmt_dur(speech)} of speech in {len(regions)} stretches, {len(packs)} packs")

    model = cfg["whisper"]["model"]
    dtw = dtw_preset(model)
    files = []
    for k, pack in enumerate(packs):
        p = os.path.join(tmp, f"p{k:05d}.wav")
        if not os.path.exists(p + ".json"):
            write_pack(full, pack, p)
        files.append(p)

    todo = [f for f in files if not os.path.exists(f + ".json")]
    batch = max(1, int(cfg["whisper"]["batch"]))
    done = len(files) - len(todo)
    started = time.time()
    for i in range(0, len(todo), batch):
        chunk = todo[i:i + batch]
        code, err = run_whisper(cfg, chunk, dtw)
        if code != 0:
            # DTW alignment aborts whisper.cpp on some packs. Redo this batch
            # one pack at a time, falling back to no DTW for the ones that crash.
            for f in chunk:
                if os.path.exists(f + ".json"):
                    continue
                code, err = run_whisper(cfg, [f], dtw)
                if code != 0 and dtw:
                    log(f"  {os.path.basename(f)}: whisper failed with DTW, retrying without (timing less exact)")
                    code, err = run_whisper(cfg, [f], None)
                if code != 0:
                    log(f"  {os.path.basename(f)}: whisper failed, pack left out\n{err}")
                    json.dump({"transcription": [], "failed": True}, open(f + ".json", "w"))
        done += len(chunk)
        rate_s = (time.time() - started) / max(1, done - (len(files) - len(todo)))
        left = (len(files) - done) * rate_s
        log(f"  {rec['name']} {role}: {done}/{len(files)} packs, about {fmt_dur(left)} left for this track")

    lines = []
    for k, pack in enumerate(packs):
        result = json.load(open(files[k] + ".json"))
        lines += unpack_tokens(result, pack_layout(pack))
    lines.sort(key=lambda l: l["start"])

    data = {"recording": rec["name"], "role": role, "duration": round(duration, 2),
            "speech_seconds": round(speech, 1), "dtw": dtw, "lines": lines}
    os.makedirs(proj.path("transcripts"), exist_ok=True)
    json.dump(data, open(out_path + ".part", "w"), indent=0)
    os.replace(out_path + ".part", out_path)
    shutil.rmtree(tmp, ignore_errors=True)
    log(f"{rec['name']} {role}: {len(lines)} lines -> work/transcripts/{os.path.basename(out_path)}")
    return data


def write_transcript_text(proj, inv):
    """One readable file for Claude: every line with recording and time, plus
    markers where nobody talks for a while."""
    cfg = proj.cfg
    labels = cfg["labels"]
    gap_marker = cfg["transcript_gap_marker"]
    out = [f"# Transcript: {proj.name}",
           "# Format: <recording> <time in that recording> [speaker] text",
           "# '~~' lines mark stretches with no talking (often building or flying).", ""]
    for rec in inv["recordings"]:
        lines = []
        for role in cfg["transcribe"]:
            p = proj.path("transcripts", f"{role}_{rec['name']}.json")
            if os.path.exists(p):
                for l in json.load(open(p))["lines"]:
                    lines.append((l["start"], l["end"], labels.get(role, role), l["text"]))
        lines.sort()
        when = f", recorded {rec['recorded_at']}" if rec.get("recorded_at") else ""
        out.append(f"## {rec['name']} ({fmt_dur(rec['duration'])} long{when})")
        cursor = 0.0
        for a, b, who, text in lines:
            if a - cursor >= gap_marker:
                out.append(f"{rec['name']} {fmt_time(cursor, 0)} ~~ {fmt_dur(a - cursor)} no talking ~~")
            out.append(f"{rec['name']} {fmt_time(a)} [{who}] {text}")
            cursor = max(cursor, b)
        if rec["duration"] - cursor >= gap_marker:
            out.append(f"{rec['name']} {fmt_time(cursor, 0)} ~~ {fmt_dur(rec['duration'] - cursor)} no talking until the end ~~")
        out.append("")
    path = proj.path("transcript.txt")
    open(path, "w").write("\n".join(out))
    return path, sum(1 for l in out if "] " in l)


def cmd_transcribe(proj, args):
    inv = proj.inventory()
    model = proj.cfg["whisper"]["model"]
    if not os.path.exists(model):
        die(f"whisper model not found: {model}")
    if not shutil.which(proj.cfg["whisper"]["binary"]):
        die(f"{proj.cfg['whisper']['binary']} not found")
    roles = args.roles or proj.cfg["transcribe"]
    recs = [r for r in inv["recordings"] if not args.recordings or r["name"] in args.recordings]
    if args.force:
        for rec in recs:
            for role in roles:
                p = proj.path("transcripts", f"{role}_{rec['name']}.json")
                if os.path.exists(p):
                    os.remove(p)
    for rec in recs:
        for role in roles:
            data = transcribe_one(proj, rec, role)
            if data is not None:
                rec.setdefault("speech", {})[role] = data["speech_seconds"]
    json.dump(inv, open(proj.path("inventory.json"), "w"), indent=1)
    path, count = write_transcript_text(proj, inv)
    log(f"done: {count} lines in {os.path.relpath(path, proj.root)}")
    return 0


# --------------------------------------------------------------------------
# status
# --------------------------------------------------------------------------


def cmd_status(proj, args):
    inv = proj.inventory(required=False)
    recs = proj.recordings()
    log(f"project {proj.name}: {len(recs)} recordings")
    if not inv:
        log("prep: not run yet")
        return 0
    for rec in inv["recordings"]:
        parts = []
        for role in proj.cfg["transcribe"]:
            done = os.path.exists(proj.path("transcripts", f"{role}_{rec['name']}.json"))
            tmp = proj.path("tmp", f"{role}_{rec['name']}")
            if done:
                parts.append(f"{role} done")
            elif os.path.isdir(tmp):
                total = len(glob.glob(os.path.join(tmp, "p*.wav")))
                fin = len(glob.glob(os.path.join(tmp, "p*.wav.json")))
                parts.append(f"{role} {fin}/{total} packs")
            else:
                parts.append(f"{role} -")
        log(f"  {rec['name']}  {fmt_dur(rec['duration']):>6}  {', '.join(parts)}")
    if os.path.exists(proj.path("transcript.txt")):
        log("transcript: work/transcript.txt")
    if os.path.exists(proj.path("edit_plan.md")):
        try:
            plan = parse_plan(proj, open(proj.path("edit_plan.md")).read(), inv)
            log(f"plan: {len(plan['segments'])} segments, {fmt_dur(plan['estimate'])} estimated")
        except ValueError as e:
            log(f"plan: has problems ({e})")
    return 0


# --------------------------------------------------------------------------
# frames and sheets
# --------------------------------------------------------------------------


def rec_lookup(proj, name):
    inv = proj.inventory()
    if re.fullmatch(r"\d+", name):
        name = f"rec_{int(name):02d}"
    for rec in inv["recordings"]:
        if rec["name"] == name:
            return rec
    die(f"no recording {name}")


def grab(path, t, out, width):
    run(["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-ss", f"{t:.3f}",
         "-i", path, "-frames:v", "1", "-vf", f"scale={width}:-2", "-q:v", "4", out])


def cmd_frames(proj, args):
    rec = rec_lookup(proj, args.recording)
    os.makedirs(proj.path("frames"), exist_ok=True)
    for t in args.times:
        s = parse_time(t)
        out = proj.path("frames", f"{rec['name']}_{fmt_time(s, 0).replace(':', '-')}.jpg")
        grab(os.path.join(proj.root, rec["file"]), s, out, args.width)
        log(out)
    return 0


def cmd_sheet(proj, args):
    rec = rec_lookup(proj, args.recording)
    a, b = parse_time(args.start), parse_time(args.end)
    n = args.n
    os.makedirs(proj.path("frames"), exist_ok=True)
    tmp = proj.path("tmp", "sheet")
    os.makedirs(tmp, exist_ok=True)
    times = [a + (b - a) * (i + 0.5) / n for i in range(n)]
    for i, t in enumerate(times):
        grab(os.path.join(proj.root, rec["file"]), t, os.path.join(tmp, f"f{i:02d}.jpg"), 480)
    cols = 4
    rows = math.ceil(n / cols)
    out = proj.path("frames", f"sheet_{rec['name']}_{fmt_time(a, 0).replace(':', '-')}_{fmt_time(b, 0).replace(':', '-')}.jpg")
    run(["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", os.path.join(tmp, "f%02d.jpg"),
         "-vf", f"tile={cols}x{rows}:padding=4", "-frames:v", "1", "-q:v", "4", out])
    shutil.rmtree(tmp, ignore_errors=True)
    log(out)
    log("frames, left to right, top to bottom: " + ", ".join(fmt_time(t, 0) for t in times))
    return 0


# --------------------------------------------------------------------------
# plan
# --------------------------------------------------------------------------

PLAN_FORMAT = """\
# <Episode title>

## Chapter 1: <chapter title>

### 01. <segment title>
- **Source:** `rec_03` `0:12:30.0` to `0:14:02.5`
- **Kind:** talk
- **What:** what happens, with a quote or two
- **Why:** why it's in

### 02. <montage segment title>
- **Source:** `rec_03` `0:14:02.5` to `0:31:40.0`
- **Kind:** montage ~45s
- **What:** building the hangar, no talking
- **Why:** shows the build; cut down on music
"""

SOURCE_RE = re.compile(r"\*\*Source:\*\*\s*`?(rec_\d+|\d+)`?\s+`?([\d:.]+)`?\s+(?:to|-)\s+`?([\d:.]+)`?")
KIND_RE = re.compile(r"\*\*Kind:\*\*\s*(talk|montage)(?:\s*~?\s*(\d+)\s*s)?", re.I)


def parse_plan(proj, text, inv):
    recs = {r["name"]: r for r in inv["recordings"]}
    chapters = []
    segments = []
    errors = []
    cur = None
    chapter = None
    for n, line in enumerate(text.splitlines(), 1):
        m = re.match(r"^##\s+(?!#)(.*)", line)
        if m:
            chapter = {"title": m.group(1).strip(), "segments": []}
            chapters.append(chapter)
            continue
        m = re.match(r"^###\s+(.*)", line)
        if m:
            if chapter is None:
                chapter = {"title": "Chapter 1", "segments": []}
                chapters.append(chapter)
            title = re.sub(r"^\d+[.)]?\s*", "", m.group(1).strip()) or m.group(1).strip()
            cur = {"title": title, "line": n, "kind": "talk", "chapter": len(chapters) - 1}
            segments.append(cur)
            chapter["segments"].append(cur)
            continue
        if cur is None:
            continue
        m = SOURCE_RE.search(line)
        if m:
            name = m.group(1)
            if re.fullmatch(r"\d+", name):
                name = f"rec_{int(name):02d}"
            cur["recording"] = name
            try:
                cur["start"], cur["end"] = parse_time(m.group(2)), parse_time(m.group(3))
            except ValueError as e:
                errors.append(f"line {n}: {e}")
            continue
        m = KIND_RE.search(line)
        if m:
            cur["kind"] = m.group(1).lower()
            if m.group(2):
                cur["montage_seconds"] = int(m.group(2))

    for s in segments:
        where = f"line {s['line']} ({s['title']})"
        if "recording" not in s or "start" not in s:
            errors.append(f"{where}: no Source line")
            continue
        rec = recs.get(s["recording"])
        if not rec:
            errors.append(f"{where}: unknown recording {s['recording']}")
            continue
        if s["end"] <= s["start"]:
            errors.append(f"{where}: ends before it starts")
        if s["end"] > rec["duration"] + 0.05:
            errors.append(f"{where}: ends at {fmt_time(s['end'])}, but {s['recording']} is only {fmt_time(rec['duration'])} long")
        s["end"] = min(s["end"], rec["duration"])
        s["length"] = s["end"] - s["start"]
    if errors:
        raise ValueError("; ".join(errors))
    if not segments:
        raise ValueError("no segments found (### headings with a Source line)")

    default_montage = proj.cfg["montage_default_seconds"]
    talk = sum(s["length"] for s in segments if s["kind"] == "talk")
    montage_raw = sum(s["length"] for s in segments if s["kind"] == "montage")
    montage_est = sum(min(s["length"], s.get("montage_seconds", default_montage))
                      for s in segments if s["kind"] == "montage")
    return {"chapters": [{"title": c["title"]} for c in chapters],
            "segments": segments, "talk": talk, "montage_raw": montage_raw,
            "montage_estimate": montage_est, "estimate": talk + montage_est}


def cmd_plan(proj, args):
    inv = proj.inventory()
    path = proj.path("edit_plan.md")
    if args.format:
        print(PLAN_FORMAT)
        return 0
    if not os.path.exists(path):
        die("no work/edit_plan.md yet (epcut plan --format shows the format)")
    try:
        plan = parse_plan(proj, open(path).read(), inv)
    except ValueError as e:
        die(f"edit_plan.md: {e}")
    for ci, ch in enumerate(plan["chapters"]):
        segs = [s for s in plan["segments"] if s["chapter"] == ci]
        if not segs:
            continue
        length = sum(s["length"] if s["kind"] == "talk" else min(s["length"], s.get("montage_seconds", proj.cfg["montage_default_seconds"])) for s in segs)
        log(f"{ch['title']}  ({fmt_dur(length)})")
        for s in segs:
            kind = "" if s["kind"] == "talk" else f"  MONTAGE, {fmt_dur(s['length'])} raw"
            log(f"   {s['recording']} {fmt_time(s['start'])} to {fmt_time(s['end'])}  {fmt_dur(s['length']):>6}  {s['title']}{kind}")
    log("")
    log(f"talk {fmt_dur(plan['talk'])} + montages ~{fmt_dur(plan['montage_estimate'])} "
        f"(from {fmt_dur(plan['montage_raw'])} raw) = about {fmt_dur(plan['estimate'])} "
        f"(target {proj.cfg['target_minutes']} min)")
    json.dump(plan, open(proj.path("plan.json"), "w"), indent=1)
    return 0


# --------------------------------------------------------------------------
# build
# --------------------------------------------------------------------------


def proxy_sizes(proj, rec):
    folder = os.path.join(os.path.dirname(os.path.join(proj.root, rec["file"])), "BL_proxy",
                          os.path.basename(rec["file"]))
    sizes = []
    for size in (25, 50, 75, 100):
        if glob.glob(os.path.join(folder, f"proxy_{size}.*")):
            sizes.append(size)
    return sizes


def cmd_build(proj, args):
    inv = proj.inventory()
    path = proj.path("edit_plan.md")
    if not os.path.exists(path):
        die("no work/edit_plan.md")
    try:
        plan = parse_plan(proj, open(path).read(), inv)
    except ValueError as e:
        die(f"edit_plan.md: {e}")
    recs = {r["name"]: r for r in inv["recordings"]}

    blend = args.blend or proj.blend()
    roughcut = os.path.join(proj.root, f"{proj.name}_roughcut.blend")
    if os.path.exists(roughcut) and not args.force:
        die(f"{os.path.basename(roughcut)} already exists; it may hold your edits. Move it away or pass --force.")

    # Always keep a copy of the .blend as it was before the build.
    os.makedirs(proj.path("backups"), exist_ok=True)
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    backup = proj.path("backups", f"{os.path.basename(blend)}.{stamp}")
    shutil.copy2(blend, backup)

    used = sorted({s["recording"] for s in plan["segments"]})
    job = {
        "project": proj.root,
        "blend": blend,
        "roughcut": roughcut,
        "force": bool(args.force),
        "channels": proj.cfg["channels"],
        "volumes": proj.cfg["volumes"],
        "chapter_gap": proj.cfg["chapter_gap_seconds"],
        "recordings": {
            name: {
                "file": os.path.join(proj.root, recs[name]["file"]),
                "fps": recs[name]["fps"],
                "duration": recs[name]["duration"],
                "audio": {role: os.path.join(proj.root, a["path"]) for role, a in recs[name]["audio"].items()},
                "proxy_sizes": proxy_sizes(proj, recs[name]),
            }
            for name in used
        },
        "chapters": plan["chapters"],
        "segments": [{k: s[k] for k in ("title", "recording", "start", "end", "kind", "chapter")}
                     for s in plan["segments"]],
    }
    job_path = proj.path("build_job.json")
    json.dump(job, open(job_path, "w"), indent=1)

    script = os.path.join(os.path.dirname(os.path.realpath(__file__)), "build_blend.py")
    cmd = [proj.cfg["blender"], "-b", "-t", str(proj.cfg["blender_threads"]), "--factory-startup",
           blend, "--python-exit-code", "1", "--python", script, "--", job_path]
    if args.mem_cap and shutil.which("systemd-run"):
        cmd = ["systemd-run", "--user", "--scope", "-q", "-p", f"MemoryMax={args.mem_cap}",
               "-p", "MemorySwapMax=0"] + cmd
    env = dict(os.environ)
    env.pop("LD_LIBRARY_PATH", None)  # dev shells set one that breaks Blender
    log(f"building from {os.path.basename(blend)} (backup: work/backups/{os.path.basename(backup)})")
    res = subprocess.run(cmd, env=env, capture_output=True, text=True)
    result = None
    for line in res.stdout.splitlines():
        if line.startswith("EPCUT:"):
            log(line[6:].strip())
        if line.startswith("EPCUT_RESULT "):
            result = json.loads(line[len("EPCUT_RESULT "):])
    if res.returncode != 0 or result is None:
        tail = (res.stdout + res.stderr).strip().splitlines()[-30:]
        die("Blender build failed:\n" + "\n".join(tail))
    log(f"wrote {os.path.relpath(result['out'], proj.root)}, scene '{result['scene']}': "
        f"{result['segments']} segments, {fmt_dur(result['seconds'])} on the timeline "
        f"({'built into your empty project file' if result['mode'] == 'inplace' else 'your project file already had strips, so this is a separate file'})")
    for note in result.get("notes", []):
        log(f"note: {note}")
    return 0


# --------------------------------------------------------------------------


def main(argv=None):
    p = argparse.ArgumentParser(prog="epcut", description=__doc__.split("\n\n")[0])
    p.add_argument("-C", dest="project", default=".", help="project folder (default: current folder)")
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("doctor")
    s = sub.add_parser("prep")
    s.add_argument("--force", action="store_true", help="extract audio again even if up to date")
    s = sub.add_parser("transcribe")
    s.add_argument("recordings", nargs="*", help="only these recordings (rec_03 ...)")
    s.add_argument("--roles", nargs="+", help="tracks to transcribe (default from settings)")
    s.add_argument("--force", action="store_true")
    sub.add_parser("status")
    s = sub.add_parser("frames")
    s.add_argument("recording")
    s.add_argument("times", nargs="+")
    s.add_argument("--width", type=int, default=960)
    s = sub.add_parser("sheet")
    s.add_argument("recording")
    s.add_argument("start")
    s.add_argument("end")
    s.add_argument("-n", type=int, default=8)
    s = sub.add_parser("plan")
    s.add_argument("--format", action="store_true", help="print the edit_plan.md format")
    s = sub.add_parser("build")
    s.add_argument("--blend", help="build from this .blend instead of <project>.blend")
    s.add_argument("--force", action="store_true", help="overwrite an existing <project>_roughcut.blend")
    s.add_argument("--mem-cap", default="16G", help="memory cap via systemd-run ('' to disable)")
    args = p.parse_args(argv)

    proj = Project(args.project)
    if not os.path.isdir(proj.footage):
        die(f"{proj.root} has no footage/ folder")
    os.makedirs(proj.work, exist_ok=True)
    return {
        "doctor": cmd_doctor, "prep": cmd_prep, "transcribe": cmd_transcribe, "status": cmd_status,
        "frames": cmd_frames, "sheet": cmd_sheet, "plan": cmd_plan, "build": cmd_build,
    }[args.cmd](proj, args)


if __name__ == "__main__":
    sys.exit(main())
