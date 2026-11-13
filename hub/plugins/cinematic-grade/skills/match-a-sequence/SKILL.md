---
name: match-a-sequence
description: Make shots that are cut together look like they were filmed at the same time with the same camera. Use when the user says shots do not match, a cut jumps in color or brightness, or two cameras look different.
---

# Match a sequence

## 1. Find what differs

1. `inspect_timeline` for the clips in the sequence.
2. `frame_stats` in the middle of each. Put lumaMedian and the vectorscope's castName, castStrength and
   meanSaturation in a table. The
   clips that stand out from the rest are the ones to change.

## 2. Choose the reference

The reference is the shot that already looks right, usually the wide or the one with the most neutral light. Not
the brightest and not the most saturated. Say which one you chose and why. If the user named one, use theirs.

## 3. Match

For each other clip:

1. `match_color` clip, reference. By default it measures the middle of each; when the middles show different
   things (a face against a landscape), pass clip_seconds and reference_seconds for frames with similar content
   and light.
2. Read the distance it returns. Under about 5: done. 5 to 10: acceptable for different angles. Over 10: try
   other frames; if it stays high, the shots were lit differently and a full match is not possible. Lower the
   match with `update_grade_layer` layer "Shot match", mix 0.6 to 0.8, rather than forcing it.
3. A match that shifts skin toward green or magenta is wrong even with a low distance: check with
   `capture_frame` and pull the mix down.

Two cameras for the whole piece: match one clip of camera B to camera A, check it, then apply the same to the
rest of camera B's clips the same way, one `match_color` each against the same reference.

## 4. Verify the cuts

For each cut in the sequence, `capture_frame` just before and just after it. A cut that still jumps in brightness
gets a small exposure change on the darker clip (`set_clip_color` exposure, 0.1 to 0.3). Report the distance
before and after for every clip, and name any cut that still does not sit right.
