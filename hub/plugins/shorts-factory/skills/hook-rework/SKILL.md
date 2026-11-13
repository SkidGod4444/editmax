---
name: hook-rework
description: Rebuild the first three seconds of a Short, Reel or TikTok so people keep watching. Use when the user says the opening is weak, slow or boring, or asks for a better hook.
---

# Rework the hook

Change only the opening. Everything after the hook stays as it is unless the user asks.

## 1. See what is there

1. `inspect_timeline`, then `capture_frame` at 0, 1 and 2.5 seconds and `get_transcript` with to 8.
2. Name the problem in one line before you change anything. The usual ones:
   - it opens on a logo, a greeting or a wide shot;
   - the first words are a warm-up ("so today I want to talk about");
   - nothing moves in the first second;
   - the point arrives after 3 seconds.

## 2. Fix it, in this order

1. **Start on the payoff.** Find the strongest line or picture in the whole video (`search_transcript`, or
   `detect_scenes` for footage without speech). If it is not at the start, trim the warm-up away with
   `cut_transcript` or `ripple_delete`. Do not copy the payoff to the front and leave it in place later as well.
2. **Cut the breath.** The first word starts within 0.2 s of the first frame: `ripple_delete` from 0 to just
   before the first word (not `trim_clip`, which leaves a gap at the start), and remove any fade in with
   `set_clip_fades` fade_in 0.
3. **Move.** Add a slow push-in on the first clip. Read the clip's scale from `inspect_timeline` first (a
   reframed clip is far above 1): `set_keyframe` param scale with that value at the clip's start, and 1.08 times
   that value three seconds later, ease smooth. Never key 1.0 on a reframed clip; it shrinks the picture.
4. **Say it on screen.** `add_text` with the promise in six words or fewer, start 0, duration 2.5, preset bold,
   y 0.22, and `set_text_animation` in pop. Use a number, a name or a place; never "you won't believe this".

## 3. Check

1. `capture_frame` at 0 and 1.5: the picture still fills the frame, the text is readable and does not cover the
   face or sit on the captions.
2. `set_playhead` to 0. Tell the user what the old opening was, what it is now, and how many seconds earlier the
   point lands.
