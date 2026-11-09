# Export

Export turns the timeline into a video file. Timeline export hands the edit itself to another editor, such as
DaVinci Resolve or Final Cut Pro.

## Export a video

1. Choose **File ▸ Export Video…** (⌘E).
2. Pick a format:
   - **MP4 (H.264):** for YouTube, social media and sharing.
   - **HEVC 10-bit:** a smaller master that keeps more color detail.
   - **ProRes 422 HQ, 422 or 4444:** a `.mov` master for further work, with 24-bit sound.
3. Choose where to save it.

Every format carries everything EditMax renders: grades, looks, titles, captions and the mixed sound. A project set to
HDR (HLG or PQ) exports HDR; see [effects](effects.md).

**Batch Export…** (⇧⌘E) renders one file per format you pick, such as landscape for YouTube and vertical for Shorts. Landscape
clips are reframed for vertical and square formats automatically.

## Muted tracks

If a track with sound is muted, silent because another track is soloed, or in a muted bus, EditMax says so before the
export starts. **Export Anyway** (Return) exports it as it is, **Turn Sound On** unmutes those tracks (one undoable
step), **Cancel** (Escape) stops. Tick **Don't ask again** when the mute is on purpose, such as camera sound under music:
that project stops asking until a different track goes silent. Tracks of silent clips (screen recordings without
sound) and hidden tracks don't ask.

## Disk space

Before an export starts, EditMax estimates the file size. If the disk is too small, it says so and offers
**Export Anyway**. While it writes, it keeps checking: below 0.5 GB free it stops, deletes the unfinished file and
tells you how much it had written.

## YouTube chapters

Markers become a chapter list. Choose **File ▸ Export Chapters…** and paste the list into the YouTube description.
Batch Export also saves it beside the videos when the project has markers.

## Send the edit to Resolve or Final Cut

**File ▸ Export Timeline…** (⌥⌘E) writes the edit, pointing at your original media files.

- **FCPXML 1.10** (DaVinci Resolve, Final Cut Pro) carries every track: clip order, trims and gaps, cross dissolves,
  speed changes and ramps, volume and fades, scale, position, rotation and opacity, markers, and titles as plain text.
  Captions go beside it as an `.srt` file.
- **EDL (CMX 3600)** carries the picture of the bottom video track only, for a conform.

Neither format carries EditMax's own processing: grades, looks and LUTs, title and caption styles, EQ, gate, voice
isolation, ducking, stabilization, crops and other keyframes. After each export, EditMax lists what went over and what
did not. To keep the grade, export a ProRes master as well and send both.

## Quitting during an export

Quitting while an export runs asks first:

- **Quit When Done** (Return): EditMax quits by itself when the export ends. The export bar offers Don't Quit.
- **Keep Working** (Esc): nothing changes.
- **Quit Now:** the export stops unfinished.

## For agents

| Tool | What it does |
|---|---|
| `export_video` | Renders one file. `ignore_disk_estimate` is the agent's Export Anyway. Its result lists, under `warnings`, each track whose sound was left out. |
| `export_batch` | Renders several formats at once, with the same `warnings` on each file. |
| `export_timeline` | Writes FCPXML or EDL. |
| `export_chapters` | Writes the YouTube chapter list. |

## Limits

- Timeline export carries the edit, not the processing (see above). Chapters are a text file, not a track inside the
  video.
- HDR projects preview tone-mapped to SDR, and grades and keys clip HDR highlights above SDR white. ProRes HDR masters
  carry the HLG or PQ tags but no mastering-display metadata.
- The size estimate follows the format's bit rate, so it runs high for a still picture.
