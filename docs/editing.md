# Editing

This page covers cutting and arranging clips: the trim tools, J and L cuts, the source viewer, scene cuts, keyframes,
slow motion, editing by transcript, multicam, nested sequences and missing media. The tools sit in the timeline
toolbar and in the inspector: select a clip to see its cards, or select nothing to see the project's. Projects saved
before these tools existed play exactly as before.

## Insert clips and delete a range

Inserting a clip at a time is a ripple insert: the clip underneath is split, and everything after it on every track
moves right to make room. Nothing is ever stacked or hidden. A file you drop onto the middle of a clip goes in right
after that clip.

To take out a stretch of time:

1. Put the playhead at the start and press **I**. Put it at the end and press **O**.
2. Choose **Delete range**: the scissors button in the timeline toolbar, the ruler's right-click menu, or the
   **Markers** card in the inspector.

The gap closes on every track, and titles and captions move with the content. **X** clears the range.

Video tracks stay above audio tracks. The top video row covers the rows below it, and text always draws over the
picture. Drag a track header onto another to reorder.

## Change a cut with roll, slip and slide

The timeline toolbar has four tools. Click one, or press its key:

| Tool | Key | What a drag does |
|---|---|---|
| Select | A | Moves a clip, or trims it by its edges. |
| Roll | R | Moves the cut between two touching clips. One gets longer, the other shorter. |
| Slip | Y | Keeps the clip in place and shows an earlier or later part of its media. |
| Slide | U | Moves the clip between the clips beside it. They get longer or shorter to fill the space. |

While you drag, the timeline shows the old edges, the new frames and a tag with the amount. When a move would run
out of media, the tag turns orange and says how far it can go. EditMax never cuts a trim short without telling you.

## Make a J or L cut

A J cut starts a clip's sound before its picture, so you hear the next shot first. An L cut lets the sound run on
after the picture ends.

1. Select a video clip with sound.
2. In the inspector's **Split edit** card, set **Lead** (seconds of sound before the picture) or **Trail** (seconds
   after it). A value below 0 starts the sound later, or stops it earlier, than the picture.
3. Where the extra sound runs under the clip beside it, both sounds play. Set **Neighbor** to **Trim** to cut that
   clip's sound so the two meet instead.

The extra sound is the clip's own media past its in and out points, so EditMax refuses a lead or trail the file does
not have. The timeline draws it as green tabs under the clip, labelled "J 1.00 s" or "L 1.00 s". Splitting,
ripple-deleting and trimming keep each J and L at its own edge, and **Reset** puts the sound back with the picture.

## Add part of a file with the source viewer

The source viewer shows a file before it is on the timeline, so you can pick just the part you want.

1. Right-click a file in the media panel and choose **Open in Source Viewer**. It takes over the preview area.
2. Scrub or play, then press **Mark In** and **Mark Out**.
3. Press **Insert** (**,**) to put the marked part at the playhead and push later clips right on every track. Or press
   **Overwrite** (**.**) to replace what is there, on one track only.

The **Source / Timeline** switch in the viewer's corner flips back, as does View ▸ Source Viewer (⌥⌘S).

This is a three-point edit: of source in, source out, timeline in and timeline out, you give three and EditMax works
out the fourth. If the timeline has in and out marks too, that is four points: EditMax fits the source into that range
by changing its speed (fit to fill).

**Match frame:** press **F** to open the frame under the playhead in the source viewer, marked with that clip's range.

## Split a long video at its scene cuts

1. Select the clip and press **Find Scene Cuts** in the inspector's **Scenes** card. It reads the clip's media once
   and finds the hard cuts, the places where the shot changes.
2. Move the **Sensitivity** slider. Higher finds smaller jumps, and the curve with its marked cuts updates at once.
3. Press **Split at Scene Cuts** to split the clip at every cut, or **Add Markers** to put a "Scene N" marker at each.

Dissolves and fades are not counted as cuts.

## Animate a setting with keyframes

A keyframe pins a value at a moment, and EditMax changes the value between keyframes. Click the diamond next to a
slider to add a keyframe at the playhead. Once a value is animated, dragging its slider writes a keyframe.

**[** and **]** jump to the previous and next keyframe. Speed keyframes make a speed ramp, and 0× is a freeze frame.

## Make slow motion smooth

For a clip slower than 1×, the inspector's **Smooth slow motion** card chooses how the in-between frames are made:

- **Repeat** shows each frame several times. This is the default.
- **Blend** cross-fades the two frames on either side. On fast motion it shows a double image.
- **Optical flow** draws new frames along the motion, using Apple's frame-rate conversion (macOS 15.4 and later). It
  is the cleanest on fast motion, with some smearing where something leaves the frame.

On gentle motion, Blend and Optical flow look about the same, and both look better than Repeat.

EditMax renders the clip once in the background. The preview switches to the render when it is ready, an export waits
for it, and the sound is untouched. A new trim or speed renders again.

If optical flow is not available, or fails during the render, EditMax uses Blend and says so. After a failure, later
clips use Blend until you quit EditMax.

## Edit by the transcript

1. Select a clip with sound. In the inspector's **Transcript** card, press **Transcribe** if it has no transcript yet.
2. Click a word, then another, to select the words between them.
3. Press **Cut N words**. The cut ripples every track, and each cut is its own undo step.

## Remove silences and filler words, then add captions

With nothing selected, the inspector's **Cleanup** card has two buttons:

- **Remove silence** cuts moments where nothing is audible for more than 0.6 s. It listens to every audible clip, so a
  pause in the speech stays where music plays underneath. To have a track ignored, mute it: muted and hidden tracks
  are not listened to, but they are still cut.
- **Remove filler words** cuts spoken fillers (um, uh, hmm…) using the transcript's word timings.

Both ripple every track. Do cleanup before **Add captions** in the **Captions** card, so the captions land on the final
cut.

## Keep titles and captions apart

A title added where a caption or another title is already on screen moves to the nearest free space. If two texts
still cover each other, the inspector warns and offers **Move clear**. The Text lane stacks texts that play at the same
time, so both bars stay readable.

## Cut between camera angles (multicam)

A multicam clip holds several cameras that filmed the same moment, and you choose which one shows when.

1. Select the clips, one per camera, and press **Make multicam from N selected** in the inspector. EditMax lines the
   angles up by their sound.
2. Play, and click an angle number in the **Multicam** card to cut to that angle at the playhead.
3. Choose which angle carries the sound under **Sound from**.

**Sync by audio** lines the angles up again, and **Flatten to clips** turns the multicam back into plain clips, one per
cut.

## Group clips into a nested sequence

A nested sequence folds several clips into one, so grading, speed, fades, transitions and keyframes apply to the
whole group.

1. Select the clips and press **Nest N selected into a sequence** in the inspector.
2. To expand it again, select the nested clip and press **Unnest onto the timeline** in its **Nested sequence** card.

## Find missing media

When a project opens and some files are not where they were, a sheet lists them. Their clips play black and silent
until EditMax finds the files.

1. EditMax first follows the bookmark each file got at import. This finds a file moved or renamed on the same disk.
2. **Search Folder…** looks through a folder and its subfolders. It matches by file name, then checks the length and
   picture size. It also finds a renamed file when exactly one file has the same type, length and size.
3. **Locate…** picks one file by hand.

When more than one file could match, EditMax lists them and does not guess. It refuses a file of another kind, or one
shorter than the part the timeline uses. Relinking is one undo step.

The media panel marks a missing file **MISSING** and shows a warning button above the list. File ▸ Relink Media…
opens the sheet again.

**Keep a project and its media together.** File ▸ Consolidate Media… copies every file the timeline uses into one
folder and points the project at the copies: clips, multicam angles and their sound, media inside nested sequences and
`.cube` LUT files. Originals are only read: nothing is moved, renamed or deleted, and undo points the project back at
them.

In the folder, a file with the same name and size is reused, and a different file with the same name gets a numbered
name ("name 2.mov").

## Keyboard

| Keys | Action |
|---|---|
| Space, J / K / L | Play and pause, shuttle (repeat J or L to double, up to 8×) |
| ← / → (⇧ for 10), Home / End | Step frames, go to start or end |
| S, ⌫ | Split at the playhead, delete the selection |
| M, I / O / X | Marker, in and out points, clear the range |
| A / R / Y / U | Select, roll, slip and slide tools |
| , / . / F | Insert and overwrite from the source viewer, match frame |
| ⌘T, `[` / `]` | Transition on the selected clip, previous and next keyframe |
| ⌘Z / ⇧⌘Z | Undo and redo, the agent's edits included |
| ⌘= / ⌘- | Zoom the timeline |
| ⌥⌘S | Source viewer or timeline |
| ⌘E, ⇧⌘E, ⌥⌘E | Export video, batch export, export timeline |
| ⇧⌘F, ⌥⌘F, ⌥⌘B | Full-screen preview, focus layout (player beside the chat), before/after |
| ⌘N, ⇧⌘N, ⇧⌘P, ⌘, | New project, new project on Home, Home, Settings |

Letter keys never fire while a text field has the focus.

## For agents

| Task | Tools |
|---|---|
| Place, cut and delete | `insert_clip`, `split_clip`, `move_clip`, `trim_clip`, `remove_clips`, `close_gaps`, `ripple_delete`, `add_track`, `move_track` |
| Roll, slip, slide | `roll_edit`, `slip_clip`, `slide_clip` |
| J and L cuts | `set_split_edit` |
| Source viewer | `insert_edit`, `overwrite_edit` (any three points; four is fit to fill), `match_frame` |
| Scene cuts | `detect_scenes` (`action`: `none`, `split` or `markers`) |
| Look at a video | `describe_video` (`asset`, `clip` or `path`; shots, what each picture shows, camera move, sound, a contact sheet) |
| Keyframes | `set_keyframe`, `remove_keyframe` |
| Slow motion | `set_smooth_slow_motion` (`off`, `blend` or `optical_flow`, with `wait`) |
| Transcript | `get_transcript`, `search_transcript`, `cut_transcript` |
| Cleanup and captions | `detect_silence`, `remove_silence`, `remove_words`, `add_captions`, `remove_captions` |
| Multicam | `make_multicam`, `cut_angle`, `set_multicam`, `sync_angles` |
| Nested sequences | `nest_clips`, `unnest_clip`, `inspect_sequence` |
| Missing media | `list_assets` (reports `missing: true`), `relink_media`, `consolidate_media` |

## Limits

- J and L cuts work on video clips with sound, on a video track. The mixer's meters do not show their extra sound
  while it plays.
- Fit to fill changes speed only between 0.1× and 10×. A source range past the end of the media, or shorter than a
  frame, is refused.
- Smooth slow motion does not work on clips at 1× or faster, stills, sound-only clips, nested sequences, multicam clips
  or missing media.
- Timeline export (FCPXML, EDL) does not carry J and L cuts: the sound is cut with the picture. Smooth slow motion
  plays there as repeated frames, so turn on the other app's frame blending or optical flow. The report after the
  export lists both.
