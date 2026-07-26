# Image Wrangler

An in-editor toolbox for manipulating images. Enable it under
**Project → Project Settings → Plugins**, then pick **Image Wrangler** from the
main screen tabs at the top, alongside **2D**, **3D** and **Script**.

## Using it

1. Add images with the **Add** button, or drag them in from the FileSystem dock.
2. Pick an operation and tune its settings. The preview updates as you drag.
3. **Process Selected** / **Process All** writes the results as PNG. You are
   asked before any existing file is replaced.

The preview sits on a checkerboard and is drawn unfiltered, so you can see
exactly what happened to the edge pixels.

### Preview and zoom

| Control | What it does |
| --- | --- |
| `-` / `+` | Steps to the next zoom stop. |
| Zoom dropdown | The stops: **10, 20, 30, 40, 50, 75, 100, 125, 150, 175, 200, 300 … 1000**. The buttons, the wheel and this list all walk the same array, so they cannot disagree. **Right-click it to type an exact value** — Enter accepts, Escape cancels. **Fit** can also land between stops, and such a value gets a row of its own until you leave it, so the control always says what the zoom actually is. |
| **Fit** | Zooms so the image fills the frame, magnifying a small one rather than leaving it at its true size. Whichever axis runs out of room first decides, so the whole image stays on screen. |
| Mouse wheel | Steps the same stops, **towards the pixel under the cursor**, so you can drive into a corner of the silhouette without chasing it with the scrollbars. |
| Drag to pan | Left-drag pans whenever no tool is active. With one active — **Pick**, say — the left button belongs to the tool, and middle-drag or Ctrl+left-drag pans instead. Both are claimed before the tool sees them, so panning never drops an island by accident. |
| Pan range | The image follows the cursor, as if you had grabbed it, and can be dragged clear of the frame edges — zoomed in or out, fitting or not — stopping only once a sliver of it is left on screen, so an edge you are inspecting can be pulled into the middle. **Fit** re-centres. |

The image is never stretched. Below the frame size it sits centred with
transparent margins; above it, scrollbars appear and it is drawn at exactly the
requested zoom with nearest sampling, so at 800% you are looking at real pixel
boundaries rather than a smoothed guess.

Opening an image fits it, so it arrives filling the frame rather than as a
corner crop or a speck. Zoom and scroll then survive everything else — re-running
the operation, toggling **Show Original** — so you can sit at 400% on an edge and
watch a setting change it.

The three columns are split by draggable dividers.

## Remove Background

Keys out a flat background colour while rebuilding the antialiased silhouette.

Set the colour with the **Remove Color** swatch under the operation dropdown. It
defaults to white; the picker's eyedropper can sample one off the screen. The
maths is colour-agnostic, so a green screen or a flat blue plate works exactly as
well as white.

The problem with deleting background-coloured pixels is that the pixels along the
edge are not background *or* subject — they are a blend of both, produced by the
antialiasing that drew the image in the first place. Delete them and the cutout
goes jagged; keep them and you get a fringe that only shows up later, once the
image is composited over something else.

So instead of asking "is this pixel background?", it asks "how much of this
pixel is subject?" and writes the answer to the alpha channel. It then un-blends
the background back out of the RGB, because a half-transparent pixel that is
still half background will read as a halo no matter how correct its alpha is.
Finally it bleeds subject colour outwards into the fully transparent pixels,
since bilinear filtering and mipmaps sample RGB even where alpha is zero.

The full derivation is in the header comment of
`core/remove_background.gd`.

### Settings

The form is split into a **Settings** group and an **Island Picker** group.

| Setting | Default | What it does |
| --- | --- | --- |
| Remove Color | white | The background colour to key out. Sits under the operation dropdown, not in this list, because it is what the operation is *about*. |
| Color Tolerance | 0.02 | How far a pixel may drift from the background colour and still be keyed out. Raise it if a re-compressed background leaves speckles behind. |
| Edge Width | 2 | How many pixels of antialiasing to rebuild. 2 suits ordinary antialiasing; raise it for soft edges, glows and drop shadows; 0 gives a hard cutout. |
| Crevice Reach | 0 (off) | Lets the flood squeeze into nooks it would otherwise stop outside. See below. |
| Crevice Tolerance | 0.5 | How far from the background colour those squeezed-through pixels may be. |
| Only Outer Background | on | Flood fills from the image border, so background-coloured regions enclosed by the subject — eyes, highlights, the holes in an "o" — stay opaque. |
| Island Picker | empty | Enclosed regions to remove anyway, picked off the preview. Held per image. See below. |
| Refine Edges | off | Runs the alpha through a guided filter, snapping it to the edges the image itself has. See below. |
| Refine Radius | 2 | Window radius for that filter: roughly how far a ragged patch of alpha may sit from a real edge and still be pulled onto it. |
| Alpha Floor | 0.0 | Alpha at or below this is forced fully clear. Applied last, so it also clears what **Refine Edges** leaves behind. See below. |
| Alpha Ceiling | 1.0 | Alpha at or above this is forced fully solid, with the range between stretched across the two. |
| Remove Color Fringe | on | Un-blends the background out of partially transparent pixels. This is the setting that actually kills the halo. |
| Color Bleed | 16 | How far subject colour is pushed into transparent pixels, guarding against filtering dragging the background back in. |

### Nooks and crannies

Background sometimes survives in a tight concave corner. The usual cause is not
the edge handling but **reachability**: where two walls nearly meet, their
antialiasing overlaps and no pixel in the gap is close enough to the background
colour to pass the flood's test. The flood stops at the mouth, and everything
behind it stays opaque.

**Crevice Reach** is the remedy — Canny's double-threshold trick applied to
region growing instead of edge linking. A pixel within **Color Tolerance** is
solid background and resets the count; one merely within **Crevice Tolerance**
may still be crossed, but only this many in a row before solid background is
needed again. That squeezes through a constriction while stopping the flood
wandering off across a pale subject, which an unbounded loose threshold would do.

Set it to at least the length of the constriction it has to get through — a
narrow slot 8px long needs roughly that much reach. It is off by default because
it is a remedy rather than something every image wants.

Being generous with it is safer than it sounds. Anywhere the flood reaches only
by straying is reclassified as **edge**, not background, so it is matted by the
ordinary coverage maths rather than cut out — and genuine subject measures as
fully covered there, so it keeps its alpha. Measured across near-white, light
grey and mid grey subjects at every reach from 1 to 32, not one interior pixel
was eroded, and a normal antialiased edge came out bit-identical to reach 0.

### Refining the edge

**Refine Edges** runs the finished alpha through a guided filter (He, Sun & Tang,
ECCV 2010 — the paper's "guided feathering" application). Within each window the
alpha is fitted as a linear function of a guide signal and the fits are averaged.
Where the guide is flat the alpha is smoothed; where the guide has an edge the
fit follows it, so the alpha snaps to that edge instead of blurring across it.

The guide is distance-from-the-key-colour rather than luminance. It is already
computed, and its edges are exactly the background/subject boundary whatever the
hue — so it separates a green screen from an equally bright subject, which
luminance cannot.

It is not only a tidying pass; it is more accurate. Against known coverage it
cut mean edge error by 2.6–3.6×:

| Subject | Edge error, off | On (radius 2) |
| --- | --- | --- |
| Dark colour ramp | 0.0090 | 0.0028 |
| Pure black | 0.0083 | 0.0032 |
| Mid grey | 0.0152 | 0.0043 |
| Near-white (0.88, 0.90, 0.82) | 0.0495 | 0.0193 |

The cost is a few extra passes over the image, which is why it is off by default.
A solid interior loses at most two 8-bit levels of alpha and no halo appears.

**One thing it does not do is remove.** Smoothing pulls a leftover speck of
background *towards* its transparent neighbours, so a solid speck becomes a faint
ghost rather than disappearing. **Alpha Floor** is the answer: set it above where
those ghosts land — around 0.5 — and they go. This is the clip-black/clip-white
pair from keying, applied after refinement so nothing smooths it back into a
haze.

It is not free. Genuinely faint edge pixels are below the floor too and go with
the ghosts, so the silhouette hardens. Measured on a soft antialiased edge:

| Floor / ceiling | Mean edge error | Alpha levels left on the edge |
| --- | --- | --- |
| off | 0.0028 | smooth |
| 0.1 / 1.0 | 0.046 | 15 |
| 0.2 / 0.8 | 0.097 | 11 |
| 0.5 / 0.6 | 0.183 | 5 |
| 0.55 / 0.55 | 0.246 | 2 (a hard cutoff) |

So start low. A floor around 0.1–0.2 with the ceiling left at 1.0 clears haze
while keeping most of the gradient; 0.5 / 0.6 is decisive but close to a binary
cutout. Setting the ceiling at or below the floor is a hard cutoff at that value,
and is honoured rather than rejected.

### Picking islands

**Only Outer Background** is deliberately conservative — it keeps every enclosed
region, because it cannot tell an eye highlight from a gap you wanted gone.
The **Island Picker** is the manual override.

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

Press **H** with the pointer over the dock to hide and show the markers — they
sit right on top of the edges you are trying to judge. The shortcut is scoped to
the dock, so H stays free everywhere else in the editor and never steals a
keystroke from a text field.

**The list belongs to the image, not to the operation.** It names the image it is
showing, and changing selection swaps the list to whatever that image has, so you
can work through a batch picking each image's islands and then process the lot in
one go. Islands are saved with the rest of that image's settings — see
[Per-image settings](#per-image-settings) — so they survive an editor restart.

A picked island is not a hole punch — it starts the same flood fill the image
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

| Subject | Naive threshold cutout | This operation |
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

## Per-image settings

Every setting belongs to the image on screen, not to the operation. Selecting an
image loads its settings; changing one saves them again a moment later.

They live in a **JSON file beside the image**, named by replacing the extension:
`flower_0002.png` → `flower_0002.json`. It is plain text and safe to hand-edit or
commit alongside the art.

```json
{
	"format": "image_wrangler",
	"version": 1,
	"operations": {
		"remove_background": {
			"tolerance": 0.02,
			"islands": { "points": [[128, 64]] }
		}
	}
}
```

**An image with no file inherits whatever is currently dialled in** — so tuning
one image and clicking through a sheet of similar ones carries your work forward,
rather than resetting each time. Islands are the exception: a coordinate in one
image means nothing in another, so they always start empty.

Selecting an image never writes anything. Only editing does.

Three things worth knowing:

- **Files appear beside your art without being asked for.** Everything else this
  addon writes is behind an explicit Process, with a confirmation before
  overwriting. This is not.
- **Settings are no longer shared across a batch.** Dialling in a tolerance and
  hitting **Process All** applies it only to images that have none of their own.
  Anything you previously selected and edited keeps its own values.
- **A `.json` already there and written by something else is left alone.**
  `sprite.json` beside `sprite.png` is exactly what Aseprite names its atlas
  descriptor. The addon reads such a file, sees it is not one of its own, refuses
  to touch it, and says so — so that image simply has no saved settings. Two
  images differing only by extension (`sprite.png`, `sprite.jpg`) also share one
  file name; only one of them can have settings.

Values outside the range their slider allows — from a hand edit, or a file
written by a later version — are pulled back inside it on load, so the form and
the processing can never silently disagree.

## Adding an operation

Write two classes in `core/`: a `Resource` holding the tunables as `@export`
properties, and an `IWOperation` subclass pointing at one. Override
`get_operation_name()`, `get_operation_id()`, `get_settings()`, `set_settings()`,
`make_settings()`, `get_settings_schema()` and `process_image()`, then add the
operation's script path to `OPERATION_SCRIPTS` in `ui/iw_panel.gd`.

That is the whole job. The dock builds the settings form from the schema and the
sidecar codec reflects over the settings Resource, so neither the UI nor the
persistence needs touching — including for a setting deliberately left out of the
schema, as `key_color` is.

Ranges belong in the schema, not in `@export_range`, so there is one source of
truth for them.

Setting types are `BOOL`, `INT`, `FLOAT` and `ISLAND_PICKER`. The last one gives
you the pick-off-the-preview list described above for any `Array[Vector2i]`
property. Give consecutive entries a matching `"group"` and they are boxed under
a heading of that name.

Override `get_key_color_property()` to return the name of a `Color` property and
the dock gives it a swatch under the operation dropdown instead of a row in the
settings form.

```gdscript
@tool
class_name IWMyOperation
extends IWOperation

var amount: float = 0.5

func get_operation_name() -> String:
	return "My Operation"

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
