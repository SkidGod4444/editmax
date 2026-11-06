# Audio: dynamics, loudness, cleanup, crossfades and the mixer

How EditMax's audio tools work, for users and for whoever changes the code. The [README](../README.md) has the overview;
[INTERNALS](INTERNALS.md) the engine's rules. All of it runs in the one `MTAudioProcessingTap` per clip span that the EQ
already used (`Engine/AudioTap.swift`), so the preview, every export and the loudness meter hear the same sound. Every
setting is off by default and decodes with a default, so old projects play exactly as before.

## The signal chain

For each clip, in order, inside the tap (`AudioTapContext.run`):

1. high-pass, hum notches, low / mid / high EQ, gate (the existing cleanup; hum removal joins it)
2. de-esser, compressor, clip gain, clip pan, clip limiter
3. track gain, track pan, bus gain, bus compressor, bus limiter, master gain, master limiter

AVFoundation then applies the clip's volume envelope (volume keyframes, fades, ducking, crossfade ramps) and adds the
tracks together. Two facts about the tap decide the rest, both checked by `testTapSeesTheSourceFormatAndGainAppliesThroughTheMix`:

- The tap sees the source's own format. A mono file arrives as one channel, so a mono clip cannot be panned in the tap.
  The tools refuse pan on mono clips and say so.
- The tap runs before the volume envelope. The limiters are given the envelope (`Span.envelope`) and scale their
  detector by it, so a clip at volume 2.0 still stops at its ceiling.

The tap allocates nothing while it runs. Filters, the limiter's delay lines, its sliding minimum and the per-frame
scratch are all allocated in the tap's prepare callback for the format it is given. A jump in time of more than 20 ms
(a seek) clears their state.

## Compressor

**For the user.** It evens out loud and quiet words. Set a threshold (−60 to 0 dBFS), a ratio (1:1 to 20:1), attack
(0.1 to 200 ms), release (10 to 2000 ms), knee (0 to 24 dB) and makeup gain (−12 to +24 dB). Turn it on in the
inspector's Compressor card or with `set_clip_compressor`. The defaults are −18 dBFS, 3:1, 10 ms, 150 ms, 6 dB knee and no makeup.

**Internals.** `CompressorDSP` is a feed-forward compressor with a smooth decoupled peak detector in the log domain
(Giannoulis, Massberg and Reiss, 2012), a quadratic soft knee, and stereo-linked gain (the loudest channel drives both).
Its static curve is `CompressorDSP.curve`, which `testCompressorSteadyState` checks against the formula.

## Limiter

**For the user.** Nothing in the clip goes over the ceiling (−24 to 0 dBTP), and that includes the peaks between
samples that appear after conversion. Release is 1 to 1000 ms and look-ahead is 0 to 5 ms. The limiter is always the
last stage of a clip. Turn it on in the Limiter card or with `set_clip_limiter`.

The master limiter is in the mixer's Master section and in `set_master`. It works: see "Mixer" below for what it can
and cannot see.

**Internals.** `LimiterDSP` runs in this order:

1. A 4× polyphase true-peak estimate of the incoming frame (`TruePeakDetector`: 16-tap Kaiser β 4 sinc phases, flat to 20 kHz, delay 8).
2. The gain each frame needs.
3. A sliding minimum over L + 1 frames (a monotonic deque).
4. Release smoothing.
5. A box average over L frames, so the gain is already down when the peak arrives.

The audio is delayed L + 8 frames to line up with the gain. At the 1.5 ms default and 48 kHz that is about 1.7 ms.

Every clip on a track is delayed by the same amount, the largest look-ahead on that track
(`TrackStrip.clipLimiterLookahead`). A clip without a limiter gets a pass-through delay of the same length, so clips on
the same track never shift against each other. Tracks without a limiter are not delayed. The worst case across tracks
is 5 ms + 8 frames, under 6 ms.

Tests hold the ceiling at −1, −3 and −0.1 dBTP, measured with the same true-peak meter as the loudness check. A quiet
signal comes out bit-exact apart from the delay.

**Known limit.** A 16-tap 4× interpolator is flat to about 20 kHz, so it cannot fully see peaks made of content above
21 kHz.

- A synthetic voice with strong energy up there, driven 12 dB into a −1 dBTP limiter, reads −1.0 dBTP on this meter,
  −0.7 on ffmpeg's `ebur128` and +0.3 dBFS on a 16× upsampled reference.
- At ordinary gains this does not show. The normalized mix, +4.6 dB with the master limiter at −1, reads −1.6 dBTP in
  ffmpeg, as WAV and as the exported ProRes master.
- The fix would be a longer filter: 32 taps is flat to about 22 kHz, at 8 more frames of latency.

## Loudness: measure and normalize

**For the user.** `measure_loudness` returns the following, for the whole mix or for one clip on its own:

- integrated loudness (LUFS), loudness range (LU);
- true peak (dBTP), sample peak and RMS;
- the loudest momentary and short-term readings;
- how far each delivery target is.

`normalize_loudness` takes a target and an optional ceiling:

- Targets: `youtube` (−14, the default), `apple` or `podcast` (−16), `ebu` (−23), or a number from −40 to −5.
- Ceiling: −9 to 0 dBTP, default −1.

It sets the gain and a limiter at the ceiling, then measures again and returns the before and after numbers in the same
call. For the mix it sets the master gain and the master limiter. For a clip it sets the clip gain and the clip limiter.
"Make it −14 LUFS for YouTube" is the single call `normalize_loudness {}`. It is one undo step. It refuses while a track
is soloed, because it would measure the wrong mix.

On a mix of several tracks it can stop short of the target. The master limiter runs on each track, not on their sum, so
past some gain the summed peaks would cross the ceiling; normalize stops there and says so in its `note` (a voice and
music test mix reached −16 LUFS for −14). A limiter on the summed mix, in the export path, would remove this limit.

In the UI: Measure and Normalize sit in the mixer's Master section and in the clip's Gain & Pan card.

**Internals.** `LoudnessMeter` is ITU-R BS.1770-4 / EBU R128:

- The K-weighting filters are designed for the actual sample rate (they match the standard's 48 kHz coefficients).
- 400 ms blocks with 75 % overlap.
- An absolute gate at −70 LUFS, then a relative gate at −10 LU.
- Loudness range: 3 s windows, gates −70 and −20, P95 − P10.
- True peak: the same 4× detector as the limiter.

`Loudness.render` reads the project's real composition through `AVAssetReaderAudioMixOutput` at 48 kHz stereo float,
with every tap in place, so the meter hears what an export would.

`Loudness.solve` works like this:

1. Measure, then move the gain by (target − measured). It stops when the error is under 0.05 LU, or after 6 measurements.
2. If a measurement's true peak is more than 0.05 dB over the ceiling, it lowers the gain by the excess plus 0.1 dB and
   never raises it again.
3. It keeps the best measured plan whose true peak is under the ceiling. If the target cannot be reached under the
   ceiling (heavy limiting would be needed), the note says so and gives the level reached.

Checks:

- EBU Tech 3341 case 3 measures −23.1 LUFS, the same as ffmpeg.
- A −72 dBFS block is gated out.
- LRA on a 10 dB step measures 10 LU.
- A fs/4 sine at 45° phase gives sample −3 dB and true peak 0 dB.

## De-esser

**For the user.** It softens harsh s and sh sounds in a voice. Amount runs 0 to 100 %. Frequency (3 to 12 kHz,
default 6 kHz) is where the s band starts. The band is turned down only while it stands out from the rest of the voice,
by up to 18 dB at full amount.

Use the De-esser card or `set_clip_deesser`.

**Internals.** `DeEsserDSP` splits the sound with a 4th-order Linkwitz-Riley crossover at the frequency. The low band
passes untouched. The high band is compressed with a key that is relative: the band's level minus the whole signal's
level, against a −15 dB threshold.

- The ratio is 1 + 5·amount.
- The maximum reduction is 18·amount dB.
- Nothing happens below −60 dBFS.

Being relative, it leaves bright music and cymbals mostly alone and reacts only when the top end jumps ahead of the
voice.

## Hum removal

**For the user.** It notches out 50 or 60 Hz mains hum and up to 8 harmonics (default 4). Amount runs 0 to 100 %.
Turning it on for the first time listens to the clip and picks 50 or 60 Hz. The note says what it heard and how
clearly.

- Detect in the card, or `set_clip_hum_removal` with `frequency: "auto"`, runs detection again.
- Pick 50 or 60 by hand when you know the country.

**Internals.** `HumFilter` subtracts a narrow band-pass at each harmonic (Q 30, in series):

    y −= amount · BPF(y)

At full amount that is a notch about 2 Hz wide at 60 Hz, which leaves the voice's fundamental alone.

`HumDetector` checks up to the first 60 s of the clip:

1. It takes 1 s Hann windows.
2. Goertzel power at each harmonic is compared with ±4 and ±6 Hz around it (its prominence).
3. The 50 Hz family (50, 100, 150 and 200 Hz) is set against the 60 Hz family (60, 120, 180 and 240 Hz).

"Clear" means the winner beats the loser by 3 dB and stands 6 dB over its surroundings.

## Audio crossfades

**For the user.** On an audio track, the cut between two clips that touch can become a crossfade: the outgoing clip
keeps playing under the incoming one and fades away while the incoming one fades up. Choose:

- the duration, 0.02 to 10 s;
- the curve: equal power (default; the level holds through the fade for different sounds) or linear (dips about 3 dB in
  the middle for unrelated sounds; right for two takes of the same sound).

The outgoing clip needs that much media past its out point. A longer request is shortened to what is there, with a note.

The Crossfade In card on the incoming clip has the control. The tool is `set_audio_crossfade`.

Limits:

- Audio tracks only. A video clip's sound would need its picture extended too; use a transition there.
- A transition on the same cut wins, and the tool refuses to add a crossfade where one exists.
- There is no timeline handle for it yet.

**Internals.** `AudioCrossfades.plan` finds each crossfade's outgoing clip.

- The outgoing clip's media is extended past its out point on its own composition track, the way a transition tail is,
  with 16 volume ramp pieces that follow the curve: gain 1−u when linear, cos(πu/2) for equal power.
- The incoming clip's head ramp follows the matching curve. It replaces that clip's own fade-in, and the outgoing clip's
  fade-out is ignored at that cut.
- The tail gets its own tap span, so the outgoing clip's compressor, limiter, gain and pan carry on through the fade.

## Mixer

**For the user.** The Mixer button in the timeline toolbar (`toolbar.mixer`) opens a pane beside the timeline with
three sections:

- **Tracks:** mute (M), solo (S), a level meter with gain reduction, a bus picker, gain (−60 to +12 dB) and pan.
- **Buses:** a name, mute, Comp and Limit, gain, threshold and ceiling.
- **Master:** gain (−24 to +24 dB), the limiter and its ceiling, Measure and Normalize.

Clip gain (−24 to +24 dB) and clip pan are in the inspector's Gain & Pan card.

Tools:

- `set_track_mix`, `set_bus` (a new name creates the bus), `set_master` and `inspect_mix`.
- `set_clip_mix` for one clip.

Solo mutes every other track in the preview and in exports, like a DAW bounce. Normalize refuses while soloed.

**Internals.** AVFoundation adds the tracks together itself after every tap, and gives no hook on the summed signal.
So:

- **Exact:** track gain, track pan, bus gain, master gain, mute and solo. They are linear gains, so applying them per
  track gives the same sum.
- **Approximate:** the bus compressor, bus limiter and master limiter run inside each track's tap, on that track alone
  (`Mixer` doc comment, `TrackStrip`).
  - A bus compressor reacts to each member track's own level, not to the bus sum.
  - A limiter keeps each track under the ceiling, but two tracks peaking at the same moment can sum over it.
  - `normalize_loudness` renders the real summed mix and lowers the master gain until the summed true peak is under the
    ceiling, so its result is exact. Only a hand-set master or bus limiter is the per-track safety net.

The exact alternative would render the whole mix through `AVAudioEngine` offline and then mux it, a new export path
for every format, which this branch does not do.

**Meters.** Each preview track's tap posts its peak and gain reduction to a `MeterSlot`. It holds two
`Atomic<UInt32>` floats, so there is no lock or allocation in the tap. The pane reads them at 15 Hz.

Meters exist only while the pane is open:

- Opening the pane rebuilds the player once with metering taps on every track. Closing it rebuilds once without them.
- Exports and loudness renders never meter.

## Edit lists (FCPXML / EDL)

None of the new settings are written to FCPXML. `Interchange.report` lists each one in use under "not transferred"
(`Mixer.notTransferred`): compressor, limiter, de-esser, hum removal, clip gain or pan, crossfades, track gain or pan,
solo, buses, master gain and limiter. The EQ line now counts only EQ, high-pass, gate and isolation. An EDL already
reports that no sound is transferred.

## Two things found on the way

- **The −11800 / −12780 render failures.** `CompositionBuilder.build` loaded the base black video
  (`BlankVideo`) and isolated-voice files into `AVURLAsset`s that nothing kept. `AVMutableComposition` does not retain
  its sources, so a reader started after the build could fail when they were freed. `Output.sources` now holds every
  asset the composition reads from, and `Loudness.render` keeps the output alive while it reads
  (`withExtendedLifetime`). `testRenderingTheSameProjectRepeatedlyNeverFails` reads ten times in a row. Every other
  one-off render (both export paths, `renderFrame`, shot match) now holds its `Output` the same way, and the player
  keeps its last one in `PlayerController.lastOutput`.
- **Transition tails had no EQ.** The part of an outgoing clip that plays under a transition was outside every tap span,
  so it lost its EQ, gate and isolation for the length of the transition. That is unchanged here, to keep the existing
  sound. The tail now gets its own span with the clip's dynamics, gain and pan only, so a compressed or limited clip
  does not jump in level through a dissolve. Giving it the cleanup too is a one-line change in
  `AudioMixPlan.transitionTail` (do not call `clearCleanup()`).
