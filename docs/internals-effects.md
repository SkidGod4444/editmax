# Effects: internals

How the effects tools work inside, with the measurements and tests behind them, for whoever changes them. Users: see
[effects.md](effects.md). The engine's general rules are in [INTERNALS](INTERNALS.md).

How EditMax's effects, compositing and HDR output work. Each feature has a user paragraph and an engine paragraph.
The [README](../README.md) has the overview; [INTERNALS](INTERNALS.md) the engine's rules. Every setting here is off by
default and decodes with a default, so projects saved before these features render exactly as they did.

## Green-screen key

**For users.** Select a clip and switch on **Key** under **Green screen** in the inspector. EditMax picks the screen colour from the edges of the frame, or you can choose it yourself. **Tolerance** takes more of the screen, **Softness** smooths the edge, and **Spill** takes the green or blue cast off hair and skin. **Shrink / grow** and **Edge blur** clean up the matte. Put the clip on a track above its new background. Agents use `set_chroma_key` (colour `"auto"` picks it from the frame) and `key_matte`, which returns the matte as a PNG with the share of keyed, edge and kept pixels.

**Internals.** `Keyer` (Engine/ChromaKey.swift) builds a 64³ `CIColorCube` from the key colour. The input is rated by its distance from the key in BT.709 CbCr, scaled by how saturated the key is. Alpha ramps between two thresholds set by tolerance and softness. Spill is removed along the key's chroma axis, keeping luma. Cubes are cached by their key settings, up to eight. Shrink, grow and edge blur rebuild the alpha as a separate matte (`CIMorphologyMinimum`/`Maximum` and `CIGaussianBlur`, scaled to the frame height) and mix it with `CIBlendWithMask`. The key runs in `Effects.source`, on the oriented source before crop, stabilization, transform and grade, so the key follows the picture and a grade never moves it. Auto-detect samples the outer 10 % of a 160 px frame into 36 hue bins and refuses below 0.3 confidence.

## Blend modes

**For users.** **Blend → Mode** mixes a clip with the video tracks below it: multiply, screen, overlay, soft light, add, difference, colour and more (19 in all). The clip's opacity sets how much of the effect shows. Agents use `set_blend_mode`.

**Internals.** `Effects.composite` swaps `composited(over:)` for the Core Image blend filter of the clip's mode in `FrameRenderer.frame`. Add uses `CIAdditionCompositing` with the alpha set to one. Clips with a non-normal mode use a true premultiplied opacity (`Effects.opacity`, an alpha-only colour matrix). Normal clips keep `withAlpha` exactly as before; that function squares the opacity, which is pre-existing behaviour and left alone.

## Face blur

**For users.** **Face blur → Find faces** finds and tracks every face in the clip and blurs it. Choose **Blur**, **Pixelate** or **Black box**, then set **Strength**, **Expand** (covers hair and chin) and **Feather**. Switch a face off to leave it sharp. Finding runs once; changing the look reuses the result. Agents use `blur_faces` (with `exclude`/`only` face numbers) and `blur_region`, which takes a rectangle and can track it through the clip with `track: true`.

**Internals.** `FaceAnalyzer` reads the source at 640 px every 0.1 s and runs `VNDetectFaceRectanglesRequest`. `associate` links detections into tracks by IoU, or by a near centre with a similar size. It bridges gaps up to 1.5 s, drops one-frame hits, numbers faces by first appearance and smooths over three samples. Tracks are stored in `Project.faceTracks` under a key of asset and source range. That is an analysis cache: `withoutHistory` strips it, and `EditMaxDocument` carries it across undo and redo, like `motionPaths`. `hydratedBlur` fills them into the clip at build time. `blur_region` with tracking uses `VNTrackObjectRequest` and stops after five low-confidence frames. `FaceBlurRenderer` builds a mask (ellipses for faces, feathered rectangles for regions) and mixes in a cropped blur, pixellate or black cover. It runs before the key in `Effects.source`.

## Animated titles and lower thirds

**For users.** Under **Animation**, any text can come on and go off with fade, slide up, slide down, pop, typewriter, word by word or wipe, each with its own length. **Lower third** turns a text into a name strap: the text is the name, plus a role line and an accent colour, in the Bar, Box or Line style. Agents use `set_text_animation` and `add_lower_third`.

**Internals.** `TitleRasterizer` (Engine/TitleAnimation.swift) draws an animated or lower-third text once per composition build. It uses a 2× bitmap with the same box, font, wrap and padding as `OverlayLayerBuilder.renderText`, and it records the character and word rectangles from the same `NSLayoutManager` that draws the glyphs. `TitleAnimator.draw` composes each frame from that raster with crops, transforms and alpha, so preview, export and `capture_frame` match. Plain texts return nil and keep the old path unchanged. `TextLayout.box` measures lower thirds as drawn, for hit-testing and the canvas outline.

## Transitions

**For users.** New transitions: push and slide in four directions, zoom, blur dissolve, iris, dip to white, and wipe up or down. Pick one in the transition menu or with `set_transition`. In Final Cut and Resolve exports they arrive as cross dissolves, and the hand-off report says so.

**Internals.** `Transitions.blend` (Engine/Transitions.swift) handles every new kind in the `default:` case of `FrameRenderer.blend`. The four original kinds keep their code. It works on the two pictures with an eased progress. Kinds are listed from `Transition.Kind.allCases`, so the MCP schema follows the enum. FCPXML writes a dissolve for them, and `Effects.notTransferred` adds a line for each.

## HDR

**For users.** **Project → Colour** sets the timeline to SDR (Rec.709, the default), HDR HLG or HDR PQ (Rec.2020). In an HDR project, iPhone HLG footage keeps its highlights. SDR clips, stills and titles sit at HDR reference white (203 nits), and the HEVC 10-bit and ProRes masters are written as Rec.2020 HLG or PQ (PQ also carries mastering-display and light-level metadata in HEVC). The preview, H.264 exports and frame captures of an HDR project stay SDR: the HDR footage is tone-mapped into them. (The preview was HDR once, but macOS showed a paused HDR frame differently from the same video playing, so picking HLG or PQ changed the paused picture until you pressed play.) Colour is SDR or HDR, not quality: normal footage looks the same at best in HDR. SDR projects are unchanged.

**Internals.** `ColorManagement.configure` runs after `CompositionBuilder` and does nothing for SDR projects. For HDR projects:

- The 10-bit compositor is swapped for an HDR subclass that accepts HDR source frames. Its output is HLG or PQ with Rec.2020 colour properties.
- The preview's composition is left as in an SDR project (no HDR compositor, no colour properties), so the Colour setting never changes it. An HDR-capable compositor gets SDR sources already converted toward its colour tags, which shifted normal footage. Every other compositor becomes `EditMaxCompositorToneMapped`, with Rec.709 colour properties set explicitly. Without them AVFoundation read its output as HDR and tone-mapped it again.
- HLG and PQ source buffers are tagged with their colour space, so Core Image keeps values above 1.0. They are rendered by a second `CIContext` (extended sRGB working space, half float) into a tagged buffer.
- SDR frames stay untagged and are treated as working-space values.
- The tone-mapped path applies `CIToneMapHeadroom` (1000/203 to 1) in linear light.
- `tagMaster` sets the writer's colour properties. For PQ HEVC it also sets the VideoToolbox mastering-display and content-light-level properties, but only when the writer accepts them.

Grades and LUTs work on values from 0 to 1 and clip HDR highlights.
