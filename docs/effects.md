# Effects

A green-screen key, blend modes, face blur that follows every face, animated titles and lower thirds, more
transitions, and HDR output. Select a clip for its Green screen, Blend and Face blur cards, or a text for its Animation
and Lower third cards. Grain, glow and vignette are in [Finishing](color.md#finish-the-picture).

## Key out a green screen

A key makes the screen color transparent, so the track below shows through. Blue screens work too.

1. Put the background on a video track and the green-screen clip on the track above.
2. Select the green-screen clip and switch on **Key** in the Green screen card. EditMax picks the screen color from
   the frame's edges. If it can't, it starts from standard green: set **Screen color**, or click **Pick from edges** on
   another frame.
3. **Tolerance** takes more of the screen, **Softness** smooths the edge, **Spill** removes the green or blue cast from
   hair and skin.
4. **Shrink / grow** and **Edge blur** tidy the matte (the mask of what stays).

## Mix a clip with the tracks below

A blend mode sets how a clip combines with the video under it, as in a photo editor. The Blend card's **Mode** has 19,
Normal included: Multiply, Screen, Overlay, Soft light, Add, Difference, Color and more. The clip's **Opacity**
(Transform card) sets how much shows.

## Blur faces

1. Select a video clip and click **Find faces** in the Face blur card. EditMax finds and follows every face.
2. Pick the **Look**: **Blur**, **Pixelate** or **Black box**.
3. Set **Strength**, **Expand** (covers hair and chin) and **Feather** (a soft edge).
4. Switch a face off to leave it sharp.

Finding runs once; changing the look reuses it. Agents can also blur and track a rectangle, such as a licence plate;
the card shows how many there are, and Remove clears them all.

## Animate a title

Select a title or caption. In the Animation card, **In** and **Out** pick how it comes on and goes off (fade, slide
up, slide down, pop, typewriter, word by word or wipe), and **In length** and **Out length** how long each takes.

## Make a lower third

A lower third is a name strap: a name with a role line under it, low on the left.

1. Select a title (not a caption) and switch on **Lower third**. The text becomes the name.
2. Type the **Role**, then pick the **Template** (Bar, Box or Line) and the **Accent** color.

## Add a transition

Right-click a clip ▸ **Transition in**, or use the Transition in card; ⌘T adds a cross dissolve. Besides cross
dissolve, dip to black and wipe left or right, there are push and slide in four directions, zoom, blur dissolve, iris,
dip to white, and wipe up or down.

## HDR

HDR (high dynamic range) video has brighter highlights than normal SDR video. HLG and PQ are two ways of storing it,
both in the wider Rec.2020 color range; iPhone HDR video is HLG.

1. Click an empty part of the timeline so nothing is selected.
2. In the Project card, set **Color** to **HDR HLG (Rec.2020)** or **HDR PQ (Rec.2020)** (the default is SDR Rec.709).
3. Export with File ▸ Export Video… as HEVC 10-bit or ProRes.

HDR footage then keeps its highlights, and SDR clips, stills and titles sit at HDR reference white (203 nits). PQ HEVC
exports also carry mastering-display and light-level metadata. The preview, H.264 exports and frame captures stay SDR,
with HDR footage tone-mapped. HDR is not a quality setting: normal footage looks the same at best.

## For agents

| Task | Tools |
|---|---|
| Green-screen key | `set_chroma_key` (color `"auto"` picks it), `key_matte` (the matte as a PNG, with the share keyed) |
| Blend mode | `set_blend_mode` |
| Blur | `blur_faces` (`exclude` / `only` face numbers), `blur_region` (`track: true` follows it) |
| Titles | `set_text_animation`, `add_lower_third` |
| Transitions | `set_transition` |
| HDR | `set_project_color` |

## Limits

- Grades, LUTs and the key work on values from 0 to 1, so they clip HDR highlights in the clips that use them.
- File ▸ Export Timeline… (Final Cut Pro, Resolve) sends the newer transitions as cross dissolves, drops keys, blend
  modes, face blur and title animations, brings lower thirds in as plain titles, and marks HDR projects as Rec.709.
  The export lists all of this under "Stays in EditMax".
