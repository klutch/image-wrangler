# Image Wrangler

<p>
  <img alt="Godot 4.7+" src="https://img.shields.io/badge/Godot-4.7%2B-0072B2?style=for-the-badge&logo=godotengine&logoColor=white">
  <img alt="GDExtension C++" src="https://img.shields.io/badge/GDExtension-C%2B%2B-E69F00?style=for-the-badge&logoColor=white">
  <img alt="Windows x86_64" src="https://img.shields.io/badge/Windows-x86__64-56B4E9?style=for-the-badge&logo=windows&logoColor=white">
  <img alt="MIT License" src="https://img.shields.io/badge/License-MIT-009E73?style=for-the-badge">
  <img alt="Built with Claude" src="https://img.shields.io/badge/Built%20with-Claude-CC79A7?style=for-the-badge">
</p>

> **Claude was used extensively to build this addon.** The code, the comments and this
> README were written with heavy help from Anthropic's Claude.

---

## What it is

A full-window image editor inside the Godot editor, built for cutting subjects out of
images and turning them into game-ready sheets.

Each image gets a stack of operations. You add the ones it needs, order them, and see the
result live. The main job is separating a subject from its background without the fringe or
the chewed silhouette a colour-key leaves — it recovers real per-pixel coverage from a soft
edge rather than thresholding it away. Around that sit tools for repairing compression
damage, shifting colour, fixing what the maths got wrong, and removing leftover specks.

Once the images are clean, the batch tools take over: pack every object onto one sheet with
a normal map and a lookup table beside it, enlarge everything with a trained network, or
write the files out under new names.

It was built for AI-generated sprite sheets, which arrive as a grid of sprites on a flat
background with compression mush, halos, speckles and hairline rules between cells. Nothing
in it cares where an image came from — scans, screenshots and old assets with a background
baked in take the same path.

---

## Screenshots

Three AI-made flower sheets, backgrounds and all:

![The original sheet loaded in the editor](workspace_original.png)

Background removed, edges kept soft, some regions corrected with the manual tools:

![The same sheet with the background removed](workspace_modified.png)

Every flower lifted off all three sheets and packed onto one atlas:

![114 sprites packed onto a single sheet](workspace_packing.png)

---

## Operations

Operations are stacked. Add the ones an image needs, drag them into order, and they run as
one pass, so no stage sees a half-finished image. The Add dropdown lists them all:

| Operation | What it does |
|:--|:--|
| **Brush Edit** | Paints alpha up or down along strokes dragged over the preview. |
| **Denoise** | Runs Intel Open Image Denoise over the source. Lifts grain and compression noise, leaving edges where it found them. |
| **Edge Cleanup** | Restores antialiasing on an edge that came back hard, and can outline it. |
| **Exclude Tiles** | Click whole objects to hold them back, or to keep only those. |
| **Fill Pinholes** | Closes small transparent specks inside a subject, matching each to its surroundings. |
| **HSV Adjustment** | Pick rectangles off the preview. Each gets its own hue, saturation and value sliders. Regions may overlap. |
| **Island Picker** | Click a region to remove or protect it, one at a time. For patches no colour rule can single out. |
| **Polygon Edit** | Draw a shape and force everything inside it transparent or opaque. For watermarks and scan edges. |
| **Random HSV Tiles** | Finds every separate object and gives each a random colour. |
| **Refine Edges** | A guided filter that tidies alpha while following the picture's own edges. No softening. |
| **Remove Background** | Recovers per-pixel coverage from an antialiased edge instead of thresholding it, so the silhouette stays soft rather than fringed or jagged. |
| **Remove Crevice** | Squeezes background into nooks too narrow for the flood fill to reach. |
| **Remove Lines** | Erases anything too thin to be real — hairlines, scan borders, leftover grid rules. |
| **Remove Minimum Area** | Removes every separate shape below a given area. Keyer crumbs are rarely thin, just small. |
| **Smooth Blocks** | Flattens the 8×8 grid compression leaves behind. |
| **Smooth Color** | Flattens colour while leaving brightness alone, fixing colour smeared sideways past an edge. |
| **Smooth Halos** | Flattens the faint ripples compression leaves beside a hard edge. |

---

## Batch tools

These describe the whole batch rather than one image, so they sit in their own tabs beside
the stack.

### Rename

Writes files out under new names, pixels untouched. Find-and-replace, a prefix, a base
name, a zero-padded counter with its own start and step, and a choice of which end the
number goes on.

### Export

Lifts every separate object out of every open image and lays them onto one sheet.

| Mode | Behaviour |
|:--|:--|
| **Shelf** | Tallest first, filling rows left to right. Packs well. The order is lost. |
| **Grid** | One cell per sprite, all cells the size of the largest. Wasteful, but frames land on a stride you can index by number. |
| **Tight** | Each sprite dropped into the lowest gap that fits. Densest and least predictable. |
| **Original Order** | Rows again, in the order sprites were found. The only mode where output order means anything. |

The sheet holds a size you set, or doubles until everything fits. Export settings are
remembered per batch.

**Lookup table.** A sheet cannot say where anything on it went. Switch **Create Lookup
Table** on and saving writes a second file beside the PNG, named the same with `_lut.res`
on the end. It holds two pixels per sprite, in the order the sprites were found: the
rectangle it landed in, then its pivot. A shader given a sprite's number finds both in two
fetches.

**Normal maps.** A normal map can come off the same sheet, so 2D lights have something to
catch. Add generators to the stack on the Export tab and saving writes a third file, named
the same with `_normal.png` on the end. Each generator builds on what the ones above it
made.

| Generator | What it reads |
|:--|:--|
| **Round Edges** | Rounds each sprite off from its outline inwards. The silhouette only, so a flat shape comes out looking carved. |
| **Color Regions** | The same rounding, plus every colour boundary inside the sprite, so each flat area of colour lifts on its own. |
| **Brightness** | Reads the sprite's own light and dark as high and low. Picks up line work and large form. |
| **Neural** | Hands each sprite to a trained network. Needs a ncnn-compatible model. Tested using [klutch/deepbump-ncnn](https://github.com/klutch/deepbump-ncnn). |

Four switches act on the whole map rather than one generator. **Green Points Down** flips
the green channel for DirectX-style engines; off is what Godot wants. **Show Normal Map**
previews the map in place of the sheet. **Clean Edges** replaces each sprite's noisy
outermost rim with the shape found just inside it, as deep as **Inner Reach** says.

**Getting the Neural model.** Add a Neural generator and press **Download Latest Model**.
It fetches the model, about thirteen megabytes, and unpacks it into the folder named above
the button. It can also be downloaded by hand from
[klutch/deepbump-ncnn](https://github.com/klutch/deepbump-ncnn), with the folder pointed at
wherever you put it.

### Upscale

Enlarges every open image with a trained network, which invents pixels rather than
stretching them. Runs on the GPU through Vulkan.

It works on what each image's stack produced, not on the file it came from, so a background
you keyed out is cut against edges the source actually had rather than edges the network
guessed at.

| Setting | What it does |
|:--|:--|
| **Engine** | [waifu2x](https://github.com/nihui/waifu2x-ncnn-vulkan) or [Real-ESRGAN](https://github.com/xinntao/Real-ESRGAN-ncnn-vulkan). waifu2x doubles and can denoise. Real-ESRGAN goes 2x–4x in one pass, invents more detail, and has no denoising. The settings below change with it. |
| **Model** | Which trained network, from the engine's own set. Most are for drawn art, one of each is for photographs. The line under the dropdown says which is which. |
| **Scale** | 1x to 32x on waifu2x, which doubles, so anything past 2x is that pass run again on its own output. On Real-ESRGAN, whichever ratios the model ships. |
| **Denoise** | waifu2x only. Off, or four strengths. Off is a different model, not a strength of zero. |
| **Sharpen** | Tightens the antialiasing round the object, where transparency is partial. At 1 the edge is a hard cut. The object never changes size. |
| **TTA Mode** | Runs each image eight ways and averages them. Eight times the work for a small difference. |

Alpha survives: it rides across on a bicubic resize beside the network, so a keyed sprite
comes out keyed. **Sharpen** tidies the ramp that leaves behind and costs nothing to
adjust, since it works on the finished picture rather than running the network again.

---

## Other features

- **Live preview** — zoom from 1% to 1000%, wheel-zoom towards the cursor, drag to pan,
  fade the original back in over the result, and a magenta backdrop for spotting stray
  pixels.
- **Undo history** — the History tab lists every edit made to an image's stack this
  session. Click one to rewind to it.
- **List housekeeping** — Remove and Clear take images off the list without touching disk.
  The red cross on each row deletes the file and its config file from disk, after asking.
- **Saved settings** — each image's stack is saved beside it as `yourfile.iwc`, so
  reopening the project picks up where you left off. Older `yourfile_wrangler.json` files
  are converted the first time their image is opened. Stacks can also be copied between
  images or saved to a file.
- **Drag and drop** — drag images in from the FileSystem dock.
- **Speed** — the heavy pixel work is C++ running off the main thread, with a progress bar
  per stage.
- **Formats** — `png`, `jpg`, `jpeg`, `bmp`, `tga`, `webp`.

---

## Installing

1. Copy the `addons/image_wrangler` folder into your project's `addons/` folder.
2. In Godot, open **Project → Project Settings → Plugins** and tick **Image Wrangler**.
3. An **Image Wrangler** tab appears in the editor.

### Requirements

- **Godot 4.7 or newer**
- **Windows x86_64**, which is what the prebuilt binaries in `addons/image_wrangler/bin/`
  are for. Other platforms need a build from source (`scons` in the addon folder, with the
  `godot-cpp` submodule checked out).

**No GPU is needed.** A Vulkan driver only makes two things faster: the Upscale tab and the
Neural normal map generator. Without one both still run on the processor. Upscale takes
minutes rather than seconds and says so on the tab; the Neural generator slows down without
comment. Everything else is processor-only to begin with.

Building the extension needs one step before `scons`, because the inference library the
upscalers and the Neural generator run on ships as source rather than binaries. That source
is committed here, so a plain clone already has it:

```
cd addons/image_wrangler
python tools/build_ncnn.py     # once, needs CMake
scons target=editor
```

Skip it and everything still builds. The Upscale tab says what to run, and the Neural
generator stays out of its dropdown. The other three generators need none of this. See
[`thirdparty/waifu2x-ncnn-vulkan/README-vendored.md`](addons/image_wrangler/thirdparty/waifu2x-ncnn-vulkan/README-vendored.md)
and [`thirdparty/realesrgan-ncnn-vulkan/README-vendored.md`](addons/image_wrangler/thirdparty/realesrgan-ncnn-vulkan/README-vendored.md).

---

## License

MIT — see [`addons/image_wrangler/LICENSE`](addons/image_wrangler/LICENSE).

Third-party components (Intel Open Image Denoise, oneTBB, waifu2x-ncnn-vulkan and
Real-ESRGAN-ncnn-vulkan with their trained models, ncnn, glslang, godot-cpp, and the editor
icon set) carry their own licenses, listed in
[`addons/image_wrangler/THIRD-PARTY-NOTICES.md`](addons/image_wrangler/THIRD-PARTY-NOTICES.md).
