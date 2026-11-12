---
name: rough-cut
description: Rough-cut a recording project (AeroSMP episodes and other solo Minecraft recordings) from its transcript into the project's Blender .blend. Use when the user asks for a rough cut, an edit plan, a transcript, or to prep an episode folder with footage/rec_NN.mp4 recordings and a project .blend.
---

# Rough cut an episode

The user (Goshva) records Minecraft sessions in OBS, pulls them into a project
folder with `obs-pull`, and edits in Blender's Video Sequencer. Your job is the
rough cut: turn hours of recordings into a coherent ~30 minute episode laid out
in the .blend. The user does the rest by hand: music, SFX, timelapses,
montage editing, titles and sponsor segments between chapters.

All the mechanical work is done by the `epcut` command. You do the editorial
part: reading the transcript and writing `work/edit_plan.md`.

## Project layout

```
<project>/<project>.blend       from the obs-split Blender template (named channels)
<project>/footage/rec_NN.mp4    recordings in order; footage/manifest.tsv has the OBS timestamps
<project>/footage/BL_proxy/     Blender proxies, if the user built any
<project>/mics/, mics/out/      used by the user's normalize-mics tool
<project>/work/                 everything epcut writes
```

OBS tracks (defaults, overridable in `<project>/epcut.json`): 1 full mix,
2 Discord ("electron"), 3 game, 4 mic only, 5 desktop.

Never modify anything in `footage/`. Never delete anything outside `work/`
without asking. `epcut build` never overwrites a .blend that has strips in it.

## Steps

1. **Check.** In the project folder, run `epcut doctor`, then `epcut status`.
   If transcripts already exist, skip to step 4.

2. **Prep** (a few minutes): `epcut prep`. It probes every recording and
   extracts the mic, game and Discord tracks to `work/audio/` as FLAC, aligned
   to the video. Tell the user the total footage length it reports.

3. **Transcribe** (long: roughly 1 to 1.5x the amount of speech, on CPU).
   Run it in the background and let the user know they can leave:
   `epcut transcribe > work/transcribe.log 2>&1`
   It's resumable per pack, so an interruption only loses a few seconds of
   work. `epcut status` shows progress per recording. Only ever run one
   transcribe at a time: it already uses every core.

4. **Read the whole transcript**, `work/transcript.txt`, in chunks of about
   1000 lines. Don't skim or sample: coherence depends on knowing what happens
   later. Lines look like `rec_03 0:12:30.4 [me] text`; `[discord]` is other
   players over Discord. `~~ 12:40 no talking ~~` lines mark silent stretches,
   which are usually building, flying or travelling.

   While reading, take notes on:
   - **Goals and plans**: every "I'm gonna build...", "we need...", "the plan
     is...". These are the spine of the episode.
   - **Progress and payoffs**: when a goal is reached, fails or changes.
   - **Funny moments, reactions, surprises, interactions with other players.**
   - **Silent stretches** after a stated plan: montage material.
   - **Dead weight**: menu fiddling, inventory sorting, mod debugging, AFK,
     technical problems, repeated failed attempts (keep the first and the
     success), talk about things off screen that viewers can't follow.

5. **Look where you're unsure.** `epcut sheet rec_03 0:10:00 0:25:00` tiles 8
   frames across a span; `epcut frames rec_03 0:12:30` grabs single frames.
   Read the images. Use this to check what a silent stretch actually shows, or
   where a build starts and ends. A few sheets per episode is enough.

6. **Write `work/edit_plan.md`** (format below; `epcut plan --format` prints
   it). Then run `epcut plan` to check it and see the runtime. Iterate until it
   tells a clear story near the target.

7. **Show the user the plan** before building: a short summary of the arc,
   the chapters with their lengths, the total runtime, and anything you're
   unsure about. Build when they say go. If they edit the plan file themselves,
   re-run `epcut plan` before building.

8. **Build**: `epcut build`. It backs up the .blend to `work/backups/` first.
   If the project .blend is still an empty template, the rough cut goes
   straight into it. Otherwise it writes `<project>_roughcut.blend` and leaves
   the user's file alone; tell them which happened.

9. **Hand over**: the file, runtime, chapters, montage blocks to cut down, and
   anything worth checking by ear. Mention that the mic strips sit on the Mic
   channel, so `normalize-mics` works as usual (with `--blend` if it's the
   `_roughcut` file).

## Editorial rules

Coherence matters more than hitting the runtime. Target ~30 minutes; 20 or 40
is fine if the material calls for it.

- **Story first.** A viewer should always know what Goshva is trying to do
  and why. Keep the short lines that say so, even when they're not funny:
  the plan, the reason, the progress check, the result. Cutting these to keep
  more jokes is the classic failure; the Halloween special's first cut lost
  its arc that way.
- **Set up, then pay off.** If a goal is in the episode, show it being set and
  show how it ends. If the payoff doesn't make the cut, cut the setup too.
- **Chapters** are natural goal changes (arriving, building the hangar, the
  first flight, a trip to another player's base). 3 to 6 per episode, each
  with a clear title. The user puts sponsor segments between chapters, so
  chapter breaks should be clean pauses, not mid-conversation.
- **Montages.** When Goshva announces a build or a flight and then goes quiet,
  make that stretch a `montage` segment covering the raw footage from the
  announcement's end to where the result is shown or talking resumes. Give a
  target length (`~45s`) for the runtime estimate. The user edits those down
  on music; you just mark the full raw range. Put the announcement in a talk
  segment just before, and the reveal or reaction just after.
- **Cut points.** Start a segment about 0.3 s before the first word and end it
  about 0.5 s after the last, using transcript times. Never cut mid-sentence.
  Transcript times can be off by a second; when a cut is tight, leave slack
  rather than clipping a word.
- **Segments** are usually 10 s to 3 min. Merge neighbouring keepers instead
  of leaving 2 s gaps between them.
- **Order** follows the recordings. Only reorder with a reason (a cold open
  teaser is fine, and should be its own short segment at the very top, also
  kept in its place later).
- **Discord.** Other players' lines matter when Goshva reacts to them or they
  drive the story; keep both sides of an exchange.
- **Privacy.** Leave out real names, locations, personal details and anything
  said that sounds like it wasn't meant for the video. Flag borderline bits
  to the user instead of deciding silently.
- Don't invent dialogue in descriptions; quote the transcript.

## Plan format

```markdown
# <Episode title>

## Chapter 1: <chapter title>

### 01. <segment title>
- **Source:** `rec_03` `0:12:30.0` to `0:14:02.5`
- **Kind:** talk
- **What:** what happens, with a short quote
- **Why:** why it's in (story, joke, payoff)

### 02. <segment title>
- **Source:** `rec_03` `0:14:02.5` to `0:31:40.0`
- **Kind:** montage ~45s
- **What:** building the hangar frame, no talking
- **Why:** the build the chapter is about; cut down on music
```

`##` headings are chapters, `###` headings are segments, numbered in order
across the whole episode. Times are in the recording's own time, as in the
transcript. Optional `- **Note:**` lines are for the user. Below the segments,
add a short `## Left out` list of notable moments you cut and why, so the user
can pull them back in.

## Technical notes

- Settings: built-in defaults, then the home-manager module's JSON, then
  `<project>/epcut.json` (tracks, channel names, whisper model, VAD threshold,
  target length). If a recording has fewer audio tracks than expected, prep
  says so; ask the user rather than guessing the layout.
- If a whole track transcribes as nearly empty when you know there was talking,
  the VAD threshold is too strict for that mic: lower `vad.threshold_db` in
  `epcut.json` (e.g. -50), delete that track's file in `work/transcripts/`
  and re-run transcribe for it.
- `epcut build` runs Blender with one thread per video decoder and a 16 GB
  memory cap, because every video strip keeps its own decoder open. It unsets
  `LD_LIBRARY_PATH`, which breaks Blender inside dev shells.
- All recordings must match the .blend's frame rate; retiming strips is not
  supported (and crashes Blender 5.2).
- Never re-run `epcut build --force` once the user has started editing the
  `_roughcut.blend`: it rebuilds from scratch.
