# Color: wheels, curves, scopes, shot match, finishing, grade layers, masks

How EditMax's color tools work, for users and for whoever changes the code: each section has a user paragraph and an
internals paragraph. The [README](../README.md) has the overview; [INTERNALS](INTERNALS.md) the engine's rules. Every
setting here is optional and decodes as "off", so projects saved before these tools open and render exactly as before.

Order of everything color does to a clip, after its transform (`ColorPipeline.apply`, Engine/GradeStack.swift):
input LUT → exposure → contrast/saturation → temperature/tint → shadows/midtones/highlights → vibrance → **wheels →
curves** → look → **grade layers** (first to last) → **finishing** (noise reduction → sharpen → glow → vignette →
grain) → opacity, fades, transitions. The before/after view skips all of it (it keeps the input LUT only).

## Color wheels

**User.** The inspector's Color wheels card has lift (shadows), gamma (midtones), gain (highlights) and offset
(everything). Drag a wheel's dot toward a colour to tint that range; the slider under it is the wheel's master
(darker/brighter). Double-click a wheel to reset it. Agents use `set_color_wheels`, for example "lift the shadows
−0.05 toward blue" is `wheel lift, master -0.05, toward blue, amount 0.05`.

**Internals.** `ClipColor.wheels: ColorWheels?` (Model/ColorGrading.swift), nil when untouched. Per channel, with
effective value = master + channel balance: `x += offset; x += lift·(1 − x); x = x^(2^(−2·gamma)) (x > 0);
x *= 1 + gain`. `toward` builds a luma-neutral balance pointing at the hue (largest component = amount). The wheel
pads place colours at their Rec.709 vectorscope angle, so a dot dragged toward the scope's B target pushes blue.

## Curves

**User.** The Curves card has Master, R, G, B and Hue sat. Click to add a point, drag to move it, double-click to
remove it. Master moves R, G and B together; Hue sat changes the saturation of one hue (anchor its neighbours at 1).
The old shadows/midtones/highlights sliders still work and apply before the curves. Tool: `set_color_curve`.

**Internals.** `ClipColor.curves: ColorCurves?`. Curves are monotone cubic (Fritsch–Carlson) splines with (0,0) and
(1,1) implied, extended linearly past the ends. Wheels and the master/R/G/B curves are baked together into one 1D
table per channel for `CIColorCurves`, 4096 entries over **−0.5…2.5**, so half-float sources above 1 (exposure
pushes, superwhites) and below 0 go through the curve instead of clipping (verified: gain −0.2 maps 1.5 to 1.2).
Hue vs saturation needs all three channels: a 64³ `CIColorCube` fed with the picture scaled by 0.5 and scaled back by
2, so the cube's 0…1 domain covers 0…2 (values outside clamp, only when a hue-sat curve is set). Tables and cubes are
cached by parameter hash (`BoundedCache`, 64 tables / 6 cubes). The hook is one line in `FrameRenderer.graded`.
Keyframing of wheels and curves is not implemented.

## Scopes: RGB parade and vectorscope

**User.** The scopes panel under the preview now shows the luma waveform, the RGB parade (each channel's levels
across the frame: equal traces on a neutral subject mean no cast), the vectorscope (distance from the centre is
saturation, the angle is hue; boxes mark 75% R, Mg, B, Cy, G, Yl; the faint orange line is skin tone) and the RGB
histogram. Agents get the numbers from `frame_stats` (`parade`, `vectorscope`) or an image plus numbers from
`capture_scopes`.

**Internals.** Engine/ColorScopes.swift samples the same 8-bit frame as the waveform (`ScopeSampler`), builds a
96×96 per-channel parade and a 128×128 vectorscope (each spot in the average colour of its pixels, log brightness),
and computes per-channel 1st/50th/99th percentiles and means, mean saturation (max − min), the cast (mean Cb/Cr
direction converted to an HSV hue) and the saturation-weighted share of 12 hue sectors. `capture_scopes` draws
`ScopesView` with `ImageRenderer`.

## Shot match

**User.** In the Shot match card, choose another clip and press Match: this clip is graded to look like it (black
level, middle, white level per channel and saturation). The correction goes on a "Shot match" grade layer you can
mix down, edit or remove; matching again replaces it; one undo removes it. Tool: `match_color`, which returns the
colour distance before and after (under about 5 is close).

**Internals.** Engine/ShotMatch.swift and `ToolExecutor.matchColor`. Both clips are rendered on their own
(`soloProject`: the clip alone at time 0 without fades, transitions, opacity or titles; `pictureOnly` resets
position/size and gives the canvas the picture's shape so letterbox bars are not measured). The target is measured
on exactly what the layer receives (grade + earlier layers, no finishing). Per channel, lift and gain are solved in
closed form so the 2nd and 98th percentiles land on the reference's, with gamma found by bisection to match the
median; a saturation factor (applied before the wheels, as in the grade) is iterated to match mean saturation.
Distance = RMS of 7 percentiles × 3 channels plus the saturation difference, in 0–255 levels. Measured on the parrot
test frame: 27.9 → 0.9. If the check render fails, the result says the "after" numbers are the solver's prediction.

## Finishing

**User.** The Finishing card has Noise, Sharpen, Glow, Vignette (left lightens the edges) and Grain (with a size).
They apply after the grade and the grade layers. Tool: `set_clip_finish` (with radius, threshold, size and
softness values too). Sizes are pixels of a 1080-line frame, so a look holds at any project size.

**Internals.** Engine/Finishing.swift, built-in filters only, all kept inside the clip's picture and alpha. Noise
reduction = `CIMedianFilter` then `CINoiseReduction`, dissolved by the amount. Sharpen = `CISharpenLuminance`.
Glow = threshold (`CIColorMatrix` + clamp) → Gaussian blur → scaled → `CIScreenBlendMode`. Vignette = an elliptical
`CIRadialGradient` fitted to the picture used as a `CIBlendWithMask` mask toward black (or white). Grain =
`CIRandomGenerator` seeded by the timeline time in ms (the same frame always gets the same grain), two channels
averaged, added with `CILinearLightBlendMode` around 0.5 (zero mean), weighted by 0.25 + 3y(1 − y) of brightness;
never finer than one pixel so a small canvas does not average it away.

## Grade layers

**User.** The Grade layers card adds grades on top of the clip's own, applied top to bottom, each with on/off, a
mix and an order. Click a layer to give it its own basics (exposure, contrast, saturation, temperature, tint),
wheels, curves and mask. Tools: `add_grade_layer`, `update_grade_layer`, `remove_grade_layer`, `move_grade_layer`;
`set_color_wheels` / `set_color_curve` take `layer`.

**Internals.** `Clip.grades: [GradeLayer]` (empty = none) with `id, name, enabled, mix, color: ClipColor, mask`.
`GradeStack.apply` grades the running result with `FrameRenderer.graded` (the layer's input LUT is ignored) and
blends it back with `CIBlendWithMask` by matte × mix. At most 12 layers per clip. The render hook is one line in
`FrameRenderer.render`, replacing `graded(img, color)` with `ColorPipeline.apply(...)`.

## Masks

**User.** A layer's mask card limits where it applies: a shape (ellipse or rectangle with centre, size, rotation
and feather), a colour selection (hue, hue range, minimum saturation, brightness range) and/or the subject (Person
or Objects, found by Apple's Vision). The parts multiply; Invert flips the result. Tools: `set_layer_mask` and
`capture_matte` (a grayscale PNG, white = the layer applies, with the coverage and a note when it is empty).

**Internals.** Engine/Masks.swift. Shapes are placed on the canvas (fractions of the frame, y down; feather is a
fraction of the frame height). The qualifier is a 32³ colour cube of `ColorQualifier.membership` applied to the
picture entering the layer, then blurred; saturation there is chroma (max − min), so dark colours count as less
saturated. The subject matte (`SubjectMatte`) runs `VNGeneratePersonSegmentationRequest` (.balanced) or
`VNGenerateForegroundInstanceMaskRequest` on the clip's own picture before the grade (input LUT applied), at 512 px
high, **live in the compositor, memoized** in an `NSCache` (240 entries) keyed by asset, source time (ms), transform,
canvas, kind, input LUT and stabilization; preview and export use the same matte. Measured on this Mac (512×512):
first call 1.6 s (person) / 3.1 s (foreground) for model load, then about 14–15 ms per new frame; a cached frame
costs nothing. Nothing is stored in the project. `capture_matte` renders a solo copy registered with `MatteProbe`,
which makes the compositor draw that layer's matte; the live preview never sees the copy's id. Vision's person model
is not a detector: on a photo with no person it still marks about a third of the frame, so check with
`capture_matte`.

## Interchange

`Interchange.report` lists, per export, what EDL/FCPXML cannot carry: color wheels, custom curves, grade layers
(with masks and shot matches) and finishing (`ColorPipeline.notTransferred`).
