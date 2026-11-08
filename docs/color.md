# Color

EditMax's color tools fix footage and give it a look. Select a clip: the inspector shows the Color, Color wheels,
Curves, Look, Shot match, Grade layers and Finishing cards.

## Work in this order

1. **Input LUT** for log footage.
2. **Color card**: exposure, contrast, saturation, temperature, tint, shadows, midtones, highlights, vibrance.
3. **Color wheels** and **Curves** for finer control.
4. **Look**, blended by its Mix slider.
5. **Grade layers** for parts of the picture, then **Finishing**.

EditMax always applies them in this order, whichever you set first. Sources are decoded in 16-bit, so 10-bit footage
keeps its precision through a LUT.

## Fix log footage with an input LUT

Log footage (DJI D-Log, S-Log, V-Log) looks flat and grey: the camera records it that way to keep more detail. A LUT
(look-up table, a `.cube` file) turns every color into another; the camera maker's conversion LUT turns log into a
normal Rec.709 picture.

1. In the Look card, open **Input LUT** ▸ **Load conversion .cube (D-Log → Rec.709…)…**.
2. Pick the camera's `.cube` file.

It runs first, at full strength, so the other controls behave as expected.

## Add a look

The Look card's **Look** menu has six built-in looks (Teal & Orange, Black & White, Film Fade, Cool Blue, Warm Vintage,
High Contrast) and **Load .cube file…** for a LUT from any grading app. **Mix** sets how much shows.

## Judge the picture: scopes and before/after

The scopes button on the preview shows four scopes:

- **Waveform**: brightness across the frame, black at the bottom, white at the top.
- **Parade**: the same for red, green and blue. Equal traces on a neutral subject mean no color cast.
- **Vectorscope**: distance from the centre is saturation, the angle is hue. Boxes mark the six main colors at 75%;
  the faint orange line is where skin tones sit.
- **Histogram**: how many pixels sit at each level.

**View ▸ Before / After** (⌥⌘B), or the button next to the scopes, shows the clip without its grade. Its arrow picks
**Split at a divider** (drag the divider) or **Whole picture before**. "Before" keeps the input LUT, so log footage
compares against its converted picture. It needs a graded clip and affects only the preview.

## Balance shadows, midtones and highlights with the wheels

**Lift** moves the shadows, **gamma** the midtones, **gain** the highlights and **offset** everything. Drag a wheel's
dot toward a color to tint that range; the slider under it makes the range darker or brighter. Double-click a wheel to
reset it.

## Shape contrast and color with curves

Pick **Master**, **R**, **G**, **B** or **Hue sat**. Click to add a point, drag to move it, double-click to remove it.
Master moves red, green and blue together. Hue sat changes the saturation of one hue: move its point, and keep the
neighbouring hues at 1 (unchanged).

## Match one shot to another

1. In the Shot match card, pick the clip to match from **Choose a clip**.
2. Click **Match**.

EditMax matches this clip's black level, middle, white level and saturation to the other one, and shows the color
distance before and after (under 5 is close). The correction is a "Shot match" grade layer you can mix down, edit or
remove. Matching again replaces it; one undo removes it.

## Grade one part of the picture

A grade layer is an extra grade on top of the clip's own, limited by a mask (the area it applies to).

1. Click **+** in the Grade layers card. The new layer's cards open below; click a layer to open it later.
2. In its mask card, choose where it applies:
   - **Shape**: an ellipse or rectangle, with centre, size, rotation and feather (a soft edge).
   - **Color selection**: a hue, hue range, minimum saturation and brightness range, for example skin tones.
   - **Subject**: **Person** or **Objects**, found in every frame by Apple's on-device model.
3. Grade it with its own basics, wheels and curves.

The layer applies only where all the mask's parts overlap; **Invert** flips it. Layers apply top to bottom, each with an
on/off checkbox, a **Mix** slider and buttons to reorder or remove it.

## Finish the picture

The Finishing card works after the grade and grade layers: **Noise** (reduction), **Sharpen**, **Glow** on highlights,
**Vignette** (left of centre lightens the edges) and **Grain** with a size. Sizes are set for a 1080-line frame, so a
look holds at any project size.

## For agents

| Task | Tools |
|---|---|
| Basics, input LUT, look | `set_clip_color` |
| Wheels and curves | `set_color_wheels`, `set_color_curve` (both take `layer`) |
| Grade layers and masks | `add_grade_layer`, `update_grade_layer`, `remove_grade_layer`, `move_grade_layer`, `set_layer_mask`, `capture_matte` |
| Shot match | `match_color` |
| Finishing | `set_clip_finish` |
| Check the result | `capture_scopes` (image and numbers), `frame_stats` (numbers) |

## Limits

- A clip can have at most 12 grade layers.
- Wheels, curves, grade layers and finishing cannot be keyframed. The Color card sliders and the look's Mix can.
- The Person subject can select about a third of a frame that has no person in it. Agents can check with
  `capture_matte`.
- File ▸ Export Timeline… (Final Cut Pro, Resolve) does not carry wheels, curves, grade layers (including shot
  matches) or finishing; the export lists them under "Stays in EditMax". Export a ProRes master too to keep the grade.
