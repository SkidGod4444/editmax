---
name: long-to-short
description: Cut one vertical Short or Reel (9:16, under 60 s) out of a long talking video that is already on the timeline. Use when the user asks for a short, a reel, a clip or "the best moment" from a long recording.
---

# Long video to one Short

The long edit stays safe: every step is a version in History, and the last step tells the user which version to
restore to get the long cut back.

## 1. Find the moment

1. `inspect_timeline`, then `get_transcript` for the clip that carries the speech. Read every page (follow
   `nextWord`) before choosing; a moment picked from the first page only is usually not the best one.
2. Choose a stretch of 20 to 55 seconds that stands alone. It must:
   - open on a claim, a number, a question or a surprise, not on "so", "and", "yeah" or a greeting;
   - make one point and finish it;
   - end on the payoff, not on a trailing "so yeah".
3. If the user named a topic, `search_transcript` for it and choose around the hit.
4. Tell the user the moment you chose: start and end as mm:ss and its first sentence. When they did not name one,
   also list two runners-up with their times, so they can ask for another.

## 2. Cut down to it

1. `add_marker` at the start and at the end of the moment, named "Short in" and "Short out".
2. `ripple_delete` from the end of the moment to the end of the timeline first, then from 0 to the start of the
   moment. This order keeps the first range's times valid.
3. Inside what is left, `remove_silence` (defaults), then `remove_words` for fillers. Do this before captions.
4. `inspect_timeline` and check the length. Over 58 s: cut the weakest sentence with `cut_transcript`.

## 3. Make it vertical

1. `set_project_settings` with width 1080 and height 1920 (clips are already placed, so not `apply_template`).
2. `auto_reframe` every video clip. Then `capture_frame` at three times; if a face is cut off, run `auto_reframe`
   on that clip again with mode person.

## 4. Hook, captions, sound

1. The first frame must show the speaker mid-sentence or the result, with no fade in. Remove a fade with
   `set_clip_fades` fade_in 0.
2. `add_text` with the promise of the short in six words or fewer, start 0, duration 2.5, preset bold, y 0.22; then
   `set_text_animation` with in pop.
3. `add_captions` preset bold, max_words 3.
4. `normalize_loudness` target youtube.

## 5. Check and hand over

1. `capture_frame` at 0.5 s and near the end: the picture fills the frame, and the hook text and the captions do
   not overlap.
2. `set_playhead` to 0 so the user can watch it.
3. Say what you made, its length, and that History holds the long version: name the version just before
   "Short in" so they can restore it. Export only when asked (`export_video`).
