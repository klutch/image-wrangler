# Image Wrangler

An in-editor toolbox for manipulating images. Enable it under
**Project → Project Settings → Plugins**, then open the **Image Wrangler** tab in
the bottom panel.

## Using it

1. Add images with the **Add** button, or drag them in from the FileSystem dock.
2. Pick a tool and tune its settings. The preview updates as you drag.
3. **Process Selected** / **Process All** writes the results as PNG. You are
   asked before any existing file is replaced.

The preview sits on a checkerboard and is drawn unfiltered, so you can see
exactly what happened to the edge pixels.

### Preview and zoom

| Control | What it does |
| --- | --- |
| `-` / `+` | Steps the zoom: 25% at a time below 100%, 100% at a time above, so 1000% is ten clicks away rather than forty. |
| Zoom field | Type any value from 1 to 1000. A trailing `%` is fine. Applied on Enter or when the field loses focus; anything unparseable snaps back. |
| **Fit** | Zooms so the whole image is visible — but never past 100%, so a small sprite is shown at its true size rather than blown up. |
| Mouse wheel | Zooms in 25% steps across the whole range, **towards the pixel under the cursor**, so you can drive into a corner of the silhouette without chasing it with the scrollbars. |

The image is never stretched. Below the frame size it sits centred with
transparent margins; above it, scrollbars appear and it is drawn at exactly the
requested zoom with nearest sampling, so at 800% you are looking at real pixel
boundaries rather than a smoothed guess.

Opening an image fits it, so a large one doesn't appear as a corner crop. Zoom
and scroll then survive everything else — re-running the tool, toggling **Show
Original** — so you can sit at 400% on an edge and watch a setting change it.

The three columns are split by draggable dividers, and the panel itself resizes
from its top edge like any other bottom-panel dock.

## Remove Background

Keys out a flat background colour while rebuilding the antialiased silhouette.

Set the colour with the **Remove Color** swatch under the tool dropdown. It
defaults to white; the picker's eyedropper can sample one off the screen. The
maths is colour-agnostic, so a green screen or a flat blue plate works exactly as
well as white.

The problem with deleting background-coloured pixels is that the pixels along the
edge are not background *or* subject — they are a blend of both, produced by the
antialiasing that drew the image in the first place. Delete them and the cutout
goes jagged; keep them and you get a fringe that only shows up later, once the
image is composited over something else.

So instead of asking "is this pixel background?", the tool asks "how much of this
pixel is subject?" and writes the answer to the alpha channel. It then un-blends
the background back out of the RGB, because a half-transparent pixel that is
still half background will read as a halo no matter how correct its alpha is.
Finally it bleeds subject colour outwards into the fully transparent pixels,
since bilinear filtering and mipmaps sample RGB even where alpha is zero.

The full derivation is in the header comment of
`core/iw_background_remover.gd`.

### Settings

| Setting | Default | What it does |
| --- | --- | --- |
| Remove Color | white | The background colour to key out. Sits under the tool dropdown, not in this list, because it is what the tool is *about*. |
| Color Tolerance | 0.02 | How far a pixel may drift from the background colour and still be keyed out. Raise it if a re-compressed background leaves speckles behind. |
| Edge Width | 2 | How many pixels of antialiasing to rebuild. 2 suits ordinary antialiasing; raise it for soft edges, glows and drop shadows; 0 gives a hard cutout. |
| Edge Contract | 0.0 | Pulls the soft edge inwards. Only needed if a faint halo survives, usually because the source was flattened onto the background twice. |
| Only Outer Background | on | Flood fills from the image border, so background-coloured regions enclosed by the subject — eyes, highlights, the holes in an "o" — stay opaque. |
| Picked Islands | empty | Enclosed regions to remove anyway, picked off the preview. Held per image. See below. |
| Remove Color Fringe | on | Un-blends the background out of partially transparent pixels. This is the setting that actually kills the halo. |
| Color Bleed | 16 | How far subject colour is pushed into transparent pixels, guarding against filtering dragging the background back in. |

### Picking islands

**Only Outer Background** is deliberately conservative — it keeps every enclosed
region, because it cannot tell an eye highlight from a gap you wanted gone.
**Picked Islands** is the manual override.

Hit **Pick** in the settings panel, then click any enclosed region in the
preview. It's added to the list as `(x, y)`, marked with a ring on the preview,
and removed on the next pass. Highlight a row to see which marker it is;
**Remove** and **Clear** take entries back out.

**Each island keys out its own colour** — the colour of the pixel you clicked,
shown as the swatch on its row. So an island need not match **Remove Color**: a
white plate with a red panel inside the subject takes two picks and no fiddling
with tolerance. The colour is sampled from the image at process time rather than
stored, so a swatch can never disagree with what it will actually remove.

One consequence: clicking the subject by mistake keys out *that* colour and eats
part of the subject. The preview shows it at once, and removing the row undoes
it.

**The list belongs to the image, not to the tool.** Its header names the image
it's showing — `Picked Islands: logo.png` — and switching selection swaps the
list to whatever that image has. Entries stay put until you remove them or
remove the image from the queue, so you can work through a batch picking each
image's islands and then process the lot in one go; **Process All** gives every
image its own seeds. Seeds live for the editor session and are not written to
disk.

A picked point is not a hole punch — it seeds the same flood fill the image
border does, so the region's rim gets the identical antialiasing treatment as
the outer silhouette. On a test island of a different colour to the main
background, the worst fringe after compositing over black was 0.013, against
0.691 for a hard-edged cut.

Entries are irrelevant while **Only Outer Background** is off, since every
background-coloured pixel already qualifies then. Click the middle of a region
rather than its edge: an antialiased pixel is a blend, so keying off one keys off
the blend rather than the region's true colour.

### Accuracy

Measured against analytically antialiased test shapes, where the true coverage of
every pixel is known. Error is the mean per-channel difference from ground truth
after compositing the result over black — the arrangement that makes any fringe
obvious.

Against a white background, by subject colour:

| Subject | Naive threshold cutout | This tool |
| --- | --- | --- |
| Dark colour ramp | 0.420 | 0.009 |
| Pure black | 0.419 | 0.000 |
| Mid grey | 0.417 | 0.014 |
| Near-white (0.88, 0.90, 0.82) | 0.364 | 0.050 |

Across background colours, mean alpha error on the soft edge:

| Background | Alpha error | Fringe |
| --- | --- | --- |
| White | 0.009 | 0.009 |
| Blue (0.15, 0.35, 0.85) | 0.010 | 0.009 |
| Green screen (0, 1, 0) | 0.010 | 0.010 |
| Mid grey | 0.017 | 0.007 |
| Black | 0.008 | 0.009 |

Fully opaque interiors stay at alpha 255 and background stays at alpha 0 in
every case; the error above is entirely in the soft edge.

### Known limits

- A subject the same colour as the background where the two meet cannot be
  separated from it. That is missing information, not a tuning problem.
- A feature only one pixel wide is ambiguous — a 50%-covered black line and a
  fully opaque grey line are the same pixels. Such features are kept opaque
  rather than half-erased.
- An edge softer than **Edge Width** keeps part of its halo. Raise the setting;
  overshooting it costs nothing, as the coverage estimate self-corrects.

## Adding a tool

Subclass `IWOperation` in `core/`, override `get_operation_name()`,
`get_settings_schema()` and `process_image()`, then add the script path to
`OPERATION_SCRIPTS` in `ui/iw_panel.gd`. The dock builds the settings form from
the schema, so there is no UI work.

Setting types are `BOOL`, `INT`, `FLOAT` and `POINT_LIST`. The last one gives you
the pick-off-the-preview list described above for any `Array[Vector2i]` property.

Override `get_key_color_property()` to return the name of a `Color` property and
the dock gives it a swatch under the tool dropdown instead of a row in the
settings form.

```gdscript
@tool
class_name IWMyTool
extends IWOperation

var amount: float = 0.5

func get_operation_name() -> String:
	return "My Tool"

func get_settings_schema() -> Array[Dictionary]:
	return [{
		"property": &"amount",
		"label": "Amount",
		"type": SettingType.FLOAT,
		"min": 0.0, "max": 1.0, "step": 0.01,
	}]

func process_image(source: Image) -> Image:
	...
```
