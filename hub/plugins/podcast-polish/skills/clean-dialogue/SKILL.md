---
name: clean-dialogue
description: Clean the sound of a podcast, interview or talking-head video: room noise, hum, harsh s sounds, uneven levels, and a final loudness of -16 LUFS. Use when the user asks to clean up, fix or master speech audio.
---

# Clean dialogue

Work clip by clip on the clips that carry speech. Measure before and after; report both.

## 1. Measure first

1. `inspect_timeline` to find the speech clips, and `inspect_mix` for what is already on them.
2. `measure_loudness` for the whole mix. Keep the numbers for the report.

## 2. Per speech clip, in this order

1. `set_clip_audio` voice_isolation 0.6. Go to 0.8 only for a loud room or street; at 1 voices start to sound
   thin. It renders once per source, so the preview catches up after a moment.
2. `set_clip_audio` high_pass 90 (use 110 for a thin or high voice, 80 for a deep one).
3. A steady low buzz from the mains: `set_clip_hum_removal` enabled true (it finds 50 or 60 Hz itself). Skip it
   when there is none; it costs a little tone.
4. Sharp s and sh sounds: `set_clip_deesser` enabled true.
5. Uneven levels inside one take (someone leans in and out): `set_clip_compressor` enabled true.
6. Room tone between words that is still audible: `set_clip_audio` gate -45.

Leave the EQ bands (low, mid, high) alone unless the voice is plainly dull or boomy; then 1 to 2 dB at most.

## 3. Two or more speakers

Match them with the meter: `measure_loudness` with clip for each speaker's longest clip, then
`normalize_loudness` with clip and the same target for each, so nobody is quieter than the other.

## 4. Music and edits

1. Music under speech: `set_ducking` on the music track, under the voice track, level 0.25.
2. A cut inside speech on an audio track that clicks gets a short crossfade: `set_audio_crossfade` on the
   incoming clip, duration 0.02, curve linear. It is refused for a clip on a video track; leave those cuts.

## 5. Master

1. `normalize_loudness` target podcast (-16 LUFS, true peak -1 dBTP). For YouTube use target youtube instead.
2. Report as a small table: integrated loudness and true peak before and after, and what you put on each clip.
   Say plainly what you could not fix (clipping that was recorded, two people on one microphone talking over
   each other).
