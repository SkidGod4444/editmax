# Audio

This page covers the tools that shape sound: EQ and cleanup, compressor, limiter, de-esser, hum removal, gain and
pan, crossfades, ducking, the mixer and loudness. Select a clip with sound to see its cards in the inspector. The
**Mixer** button in the timeline toolbar opens the mixer.

The preview, every export and the loudness meter hear the same sound. Every setting starts off, so projects saved
before these tools existed play exactly as before.

## Know what happens in what order

Each clip's sound goes through these steps:

1. Cleanup: high-pass, hum removal, EQ, gate.
2. De-esser, compressor, clip gain, clip pan, clip limiter.
3. Track gain and pan, then the bus (gain, compressor, limiter), then the master (gain, limiter).

Volume keyframes, fades, ducking and crossfades apply after that. A limiter still holds its ceiling when you raise a
clip's volume.

## Clean up a voice (EQ & cleanup)

The clip's **EQ & cleanup** card has:

- **Low, Mid, High:** turn the bass (around 200 Hz), the middle (1 kHz) and the treble (6 kHz) up or down, by up to
  18 dB.
- **High-pass:** removes low rumble below the frequency you set. 80 to 120 Hz suits most voices.
- **Noise gate:** silences the clip whenever it is quieter than the level you set, which hides background hiss between
  words.
- **Voice isolation:** keeps speech and removes the rest, using Apple's on-device model. It is worked out once per
  file on this Mac, so the first time takes a moment.

**Reset** clears the card.

## Make music duck under speech

Ducking turns a music track down while someone talks on another track, and back up when they stop.

1. Click an empty part of the timeline to show the project inspector.
2. In the **Ducking** card, set the music track to **Under** the voice track.
3. Set the level it drops to (25 % by default).

It drops in 0.15 s and comes back in 0.4 s. An agent can change both with `set_ducking`.

## Even out loud and quiet words (compressor)

A compressor turns down whatever goes over a level you set, so loud and quiet words sit closer together. Turn it on in
the clip's **Compressor** card. It starts with the defaults below.

| Setting | Range | Default | What it does |
|---|---|---|---|
| Threshold | −60 to 0 dBFS | −18 | The level where turning down starts. dBFS counts down from 0, the loudest a file can hold. |
| Ratio | 1:1 to 20:1 | 3:1 | How hard it turns down. At 3:1, sound 3 dB over the threshold comes out 1 dB over. |
| Attack | 0.5 to 100 ms | 10 ms | How fast it reacts. |
| Release | 20 to 1000 ms | 150 ms | How fast it lets go. |
| Knee | 0 to 24 dB | 6 dB | How gently it starts around the threshold. |
| Makeup | −12 to +24 dB | 0 | Gain after it, to bring the level back up. |

## Stop peaks going over a ceiling (limiter)

A limiter is a hard stop: nothing in the clip goes over its ceiling. That includes true peaks, the peaks between
samples that appear after conversion, measured in dBTP. Turn it on in the clip's **Limiter** card.

| Setting | Range | Default |
|---|---|---|
| Ceiling | −24 to 0 dBTP | −1 |
| Release | 1 to 1000 ms | 100 ms |
| Look-ahead | 0 to 5 ms | 1.5 ms |

Look-ahead delays the sound a little, so the limiter can turn down before a peak arrives. Every clip on the track is
delayed by the same amount, so clips never shift against each other. The limiter is always last in a clip's chain.

The master limiter is in the mixer's **Master** section. See [Limits](#limits) for what it can and cannot catch.

## Hit a loudness target for YouTube or podcasts

Loudness is measured in LUFS: how loud the whole piece sounds to a listener, on average. YouTube, Apple and podcast
apps, and broadcasters set their targets in LUFS.

1. Open the mixer.
2. In the **Master** section, press **Measure** to see the loudness, the true peak and the loudness range (in LU,
   how much the loudness varies).
3. Choose **Normalize** ▸ **YouTube, −14 LUFS**, **Apple and podcasts, −16 LUFS** or **EBU R128, −23 LUFS** (the
   broadcast standard).

Normalize sets the master gain and a master limiter at −1 dBTP, then measures again and shows the result. It is one
undo step. To do one clip on its own, use **Measure** and **Normalize** in the clip's **Gain & pan** card: they set
that clip's gain and limiter instead.

## Soften harsh s sounds (de-esser)

The de-esser turns down harsh s and sh sounds in a voice, only while they stand out from the rest of it. Bright music
and cymbals are mostly left alone. Turn it on in the clip's **De-esser** card.

- **Amount** runs 0 to 100 % (default 50 %). At full amount it turns the s sounds down by up to 18 dB.
- **Frequency** is where the s sounds start: 3 to 12 kHz, default 6 kHz. Try 4.5 to 5.5 kHz for a low voice, 7 to
  8 kHz for a bright one.

## Remove mains hum

Mains hum is a low buzz at 50 or 60 Hz from the power supply, with harmonics (its multiples, like 100 and 150 Hz).
Turn on the clip's **Hum removal** card.

1. The first time, EditMax listens to the clip (up to its first minute) and picks 50 or 60 Hz. The note says what it
   heard and how clearly.
2. If you know the country it was filmed in, pick **50 Hz** or **60 Hz** under **Mains** yourself. **Detect** listens
   again.
3. Set **Amount** (0 to 100 %, default 100 %) and **Harmonics** (1 to 8, default 4).

Each notch is narrow, about 2 Hz wide at 60 Hz, so the voice is left alone.

## Crossfade two audio clips

On an audio track, the cut between two touching clips can become a crossfade: the outgoing clip keeps playing under
the incoming one and fades away while the incoming one fades up.

1. Select the clip after the cut and turn on its **Crossfade in** card.
2. Set **Duration**, from 0.05 to 5 s.
3. Pick a **Curve**. **Equal power** (the default) keeps the level steady, for two different sounds. **Linear** dips
   about 3 dB in the middle with unrelated sounds, and is right for two takes of the same sound.

The outgoing clip needs that much media past its out point. A longer request is shortened to what is there, with a
note. The crossfade replaces both clips' own fades at that cut, and the outgoing clip keeps its sound settings
through the fade.

## Mix tracks with the mixer

The **Mixer** button in the timeline toolbar opens a pane beside the timeline:

- **Tracks:** mute (the speaker), solo (the headphones: hear only soloed tracks), a level meter with gain reduction, a
  bus picker, gain (−60 to +12 dB) and pan. They are the same switches as the speaker and headphones in the track
  header: changing one changes the other.
- **Buses:** a bus groups tracks, like dialogue or music, so you set their level together. Each has a name, mute,
  **Comp** and **Limit**, gain, threshold and ceiling. Type a name under **New bus** and press **+** to make one, then
  pick it in each track's bus picker.
- **Master:** gain (−24 to +24 dB), the limiter and its ceiling, **Measure** and **Normalize**.

Solo silences every other track in exports too, not only in the preview. The meters run only while the mixer is open.

A track that is left out says so under its name in the timeline: **Muted** or **Hidden** in orange, or **Silent** when
another track is soloed or its bus is muted (hover it for the reason). Before an export, EditMax lists every track with
sound that would be left out; see [export](export.md#muted-tracks).

One clip's gain (−24 to +24 dB) and pan are in its **Gain & pan** card.

## For agents

| Task | Tools |
|---|---|
| EQ, high-pass, gate, voice isolation | `set_clip_audio` |
| Ducking | `set_ducking` (`level`, `attack`, `release`) |
| Clip dynamics | `set_clip_compressor`, `set_clip_limiter`, `set_clip_deesser`, `set_clip_hum_removal` (`frequency: "auto"` detects again) |
| Clip gain and pan | `set_clip_mix` |
| Crossfades | `set_audio_crossfade` |
| Mixer | `set_track_mix`, `set_bus` (a new name creates the bus), `set_master`, `inspect_mix` |
| Loudness | `measure_loudness`, `normalize_loudness` |

Agents can set a wider range than the sliders: compressor attack 0.1 to 200 ms and release 10 to 2000 ms, crossfades
0.02 to 10 s.

`measure_loudness` works on the whole mix or one clip on its own. Besides loudness, true peak and range, it returns
the sample peak, RMS, the loudest momentary (0.4 s) and short-term (3 s) readings, and how far each target is.

`normalize_loudness` takes a `target`: `youtube` (−14, the default), `apple` or `podcast` (−16), `ebu` (−23), or a
number from −40 to −5. Its ceiling runs −9 to 0 dBTP, default −1. "Make it −14 LUFS for YouTube" is the single call
`normalize_loudness {}`, and it returns the before and after numbers in the same call.

## Limits

- A mono clip plays in both speakers and cannot be panned.
- The bus compressor, bus limiter and master limiter work on each track on its own, because EditMax adds the tracks
  together after them. A bus compressor reacts to each track's level, not the bus total. Two tracks peaking at the
  same moment can add up past a limiter's ceiling.
- Normalize checks the real, added-up mix, so its result stays under the ceiling. On a mix of several tracks it can
  stop short of the target for that reason, and its note says where and why. A voice and music test mix reached
  −16 LUFS for a −14 target.
- Normalize refuses while a track is soloed, because it would measure the wrong mix.
- A clip limiter delays its track's sound by the look-ahead plus a little, under 6 ms in all. Tracks without one are
  not delayed.
- The limiter cannot fully see peaks made of very high sound, above about 21 kHz. Pushed hard into the limiter, such
  sound can pass the ceiling slightly. At ordinary levels this does not show.
- Crossfades work on audio tracks only. On a video track, use a transition. A transition on the same cut wins, and a
  crossfade cannot be added there. There is no timeline handle for a crossfade yet.
- Under a video transition, the outgoing clip's sound loses its EQ, high-pass and gate for the length of the
  transition. Its hum removal, de-esser, compressor, limiter, gain and pan carry on.
- Timeline export (FCPXML) carries none of these settings. The report after the export lists each one in use. An EDL
  carries no sound at all.
