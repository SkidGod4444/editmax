---
name: balance-then-look
description: Grade a video from ungraded footage to a finished film look, measured at every step: exposure, white balance, contrast, saturation, then a look and finishing. Use when the user asks to grade, color, make it cinematic, or fix flat or off-color footage.
---

# Balance, then look

A look on top of unbalanced shots magnifies every difference between them. Balance each shot first, by the
numbers; style comes last and is the same for all.

## 1. Each clip: balance

For every video clip, at a time inside it that shows the main subject:

1. `frame_stats`. Read lumaMedian (0 to 255), whiteClipped and blackClipped (fractions of the frame) and the
   vectorscope's castName and castStrength.
2. Log footage (flat, grey, low saturation, from a DJI, Sony or similar camera in a log profile): the conversion
   comes first, `set_clip_color` input_lut with the camera maker's .cube. Ask the user for the file if you do not
   have its path. Never guess a log profile, and never stack two conversions.
3. Exposure: `set_clip_color` exposure until lumaMedian sits about 100 to 130 for a day scene, 50 to 90 for a
   night or moody one. whiteClipped stays under 0.01.
4. White balance: a cast shows in `frame_stats` as the vectorscope's castName and castStrength. Warm cast: temperature
   negative. Green cast: tint positive. Move 5 to 10 at a time and measure again; stop when castStrength is
   near zero on something that should be neutral (a white wall, grey road, clouds).
5. Contrast 1.05 to 1.2; then shadows and highlights by 0.05 to 0.1 to keep detail at both ends. blackClipped
   under 0.02.
6. Saturation last, 1.0 to 1.15, or vibrance 0.1 to 0.3 when skin is in the shot (vibrance spares skin).

Check faces with `capture_frame`: skin must still look like skin.

## 2. Across clips: match

Pick the best-looking balanced clip as the reference. For each other clip in the same scene, `match_color` with
that reference. A colour distance under about 5 after the match is close; above 10, pick frames with more
similar content (clip_seconds, reference_seconds) and match again.

## 3. One look for all

1. The same look on every clip, never at full strength: `set_clip_color` look with look_mix 0.3 to 0.6.
   Teal & Orange for travel and action, Film Fade or Warm Vintage for memory and romance, Cool Blue for night
   and tech, High Contrast for sport. A .cube path works as a look too.
2. Finishing, subtle: `set_clip_finish` grain 0.15 to 0.25, vignette 0.2 to 0.35. Glow 0.2 to 0.3 only on shots
   with bright highlights. Sharpen is for soft footage, not for everything.

## 4. Verify

1. `frame_stats` on each clip again: nothing clipped by the look.
2. `capture_scopes` on the two clips that differ most, and look at them side by side in your reply.
3. Tell the user, per clip, what you set and why, as a table. `set_playhead` to the clip that changed most.
