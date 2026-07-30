# 🖼️ Image Wrangler

<p>
  <img alt="Godot 4.7+" src="https://img.shields.io/badge/Godot-4.7%2B-0072B2?style=for-the-badge&logo=godotengine&logoColor=white">
  <img alt="GDExtension C++" src="https://img.shields.io/badge/GDExtension-C%2B%2B-E69F00?style=for-the-badge&logoColor=white">
  <img alt="Windows x86_64" src="https://img.shields.io/badge/Windows-x86__64-56B4E9?style=for-the-badge&logo=windows&logoColor=white">
  <img alt="MIT License" src="https://img.shields.io/badge/License-MIT-009E73?style=for-the-badge">
  <img alt="Built with Claude" src="https://img.shields.io/badge/Built%20with-Claude-CC79A7?style=for-the-badge">
</p>

> ### 🤖 A note before anything else
> **Claude was used extensively to build this addon.** The code, the comments and this
> README were written with heavy help from Anthropic's Claude.

---

## 🌸 What it is

Image Wrangler is a **whole editor tab** inside Godot — sitting next to 2D, 3D and Script —
for cleaning up images without leaving the engine. Load a pile of files, stack up a few
operations, watch the result live at 800% zoom, and write the finished files back out.

**🎯 The thing it was built for: cleaning up AI-generated sprite sheets.** Image generators
hand you a grid of lovely sprites glued to a flat white background, with JPEG mush around
every edge, faint halos, speckles, and hairline rules between the cells. Getting that into
a game means cutting each sprite out cleanly — and a plain colour-key leaves you either a
white fringe or a chewed-up silhouette.

**🧰 It is not only for AI images, though.** Nothing in here knows or cares where a picture
came from. Scans, screenshots, photographed artwork, old assets with a background baked in —
same tools, same results.

---

## 📸 Screenshots

**Before** — three AI-made flower sheets, backgrounds and all:

![The original sheet loaded in the editor](workspace_original.png)

**After** — background gone, edges kept soft, a few regions fixed by hand:

![The same sheet with the background removed](workspace_modified.png)

**Packed** — every flower lifted off all three sheets and laid onto one atlas:

![114 sprites packed onto a single sheet](workspace_packing.png)

---

## ✨ What it can do

Operations are stacked. You add the ones an image actually needs, drag them into the order
you want, and they run as one pass — so a stage never sees a half-finished image.

### 🔵 Repair — fix the pixels before anything reads them

| | Operation | What it does |
|:--|:--|:--|
| 🌫️ | **Denoise** | Runs Intel Open Image Denoise over the source. Lifts grain and JPEG mosquito noise while leaving edges where it found them. |
| ▦ | **Smooth Blocks** | Flattens the 8×8 grid a JPEG leaves behind. |
| 🎨 | **Smooth Color** | Flattens colour while leaving brightness alone, fixing colour smeared sideways past every edge. |
| 〰️ | **Smooth Halos** | Flattens the faint ripples a JPEG leaves beside a hard edge. |

### 🟠 Color — move the colours around

| | Operation | What it does |
|:--|:--|:--|
| 🎚️ | **HSV Adjust** | Pick rectangles off the preview; each gets its own hue, saturation and value sliders. Regions may overlap. |
| 🎲 | **Random HSV Tiles** | Finds every separate object on its own and gives each one a random colour. Forty flowers, forty palettes, one click. |

### 🟣 Background — take the background out

| | Operation | What it does |
|:--|:--|:--|
| 🧽 | **Remove Background** | The main event. Recovers real per-pixel coverage from an antialiased edge instead of thresholding it away, so the silhouette stays soft rather than fringed or jagged. |
| 📐 | **Remove Crevice** | Squeezes background into nooks too narrow for the flood fill to have reached. |

### 🟡 Edges — clean up the silhouette it left

| | Operation | What it does |
|:--|:--|:--|
| 🪶 | **Refine Edges** | A guided filter that tidies the alpha while following the picture's own edges. No softening. |
| ✏️ | **Edge Cleanup** | Restores antialiasing on an edge that came back hard, and can outline it. |

### 🟢 By Hand — for what the maths can't name

| | Operation | What it does |
|:--|:--|:--|
| 🖌️ | **Brush Edit** | Paint alpha up or down along strokes dragged over the preview. |
| 🎯 | **Island Picker** | Click a region to remove or protect it, one at a time. For patches no colour rule can single out. |
| 🔺 | **Polygon Edit** | Draw a shape and force it transparent or opaque, whatever's inside it. Good for watermarks and scan edges. |

### 🔴 Cleanup — tidy what's left

| | Operation | What it does |
|:--|:--|:--|
| 🪣 | **Fill Pinholes** | Closes small transparent specks inside a subject, painting each one to match its surroundings. |
| ➖ | **Remove Lines** | Erases anything the silhouette is too thin to have earned — hairlines, scan borders, leftover grid rules, specks. |

---

## 📦 Batch tools

These two describe the **whole batch** rather than any one image, so they sit in their own
tabs beside the stack.

### 🏷️ Rename

Writes files out under new names, pixels untouched. Find-and-replace, a prefix, a base name,
a zero-padded counter with your own start and step, and a choice of which end the number goes on.

### 🧩 Packing

Lifts every separate object out of **every open image** and lays them all onto one sheet.

| Mode | Behaviour |
|:--|:--|
| 🟦 **Shelf** | Tallest first, filling rows left to right. The usual choice — packs well, order is lost. |
| 🟧 **Grid** | One cell per sprite, all cells the size of the largest. Wasteful, but frames land on a stride you can index by number. |
| 🟩 **Tight** | Each sprite dropped into the lowest gap that fits. Densest, least predictable. |
| 🟪 **Original Order** | Rows again, but in the order sprites were found. The only mode where the output order means something. |

The sheet can hold a size you've decided on, or double until everything fits.

---

## 🛠️ Other things it does

- **👀 Live preview** — zoom from 1% to 1000%, wheel-zoom towards the cursor, drag to pan,
  fade the original back in over the result, and a magenta backdrop for spotting stray pixels.
- **↩️ Undo history** — every edit made to an image's stack this session, in a list. Click one
  to rewind to it.
- **💾 Settings sidecars** — each image's stack is saved next to it as `yourfile_wrangler.json`,
  so reopening the project picks up where you left off. Settings can also be copied between
  images or saved as a preset.
- **📥 Drag and drop** — drag images straight in from the FileSystem dock.
- **⚡ Fast** — the heavy pixel work is C++ running off the main thread, with a progress bar
  per stage so you can see which one is the slow one.
- **📄 Formats** — `png`, `jpg`, `jpeg`, `bmp`, `tga`, `webp`.

---

## 🚀 Installing

1. Copy the `addons/image_wrangler` folder into your project's `addons/` folder.
2. In Godot, open **Project → Project Settings → Plugins** and tick **Image Wrangler**.
3. An **Image Wrangler** tab appears next to 2D, 3D and Script. That's it.

### 📋 Requirements

- **Godot 4.7 or newer**
- **Windows x86_64** — that's what the prebuilt binaries in `addons/image_wrangler/bin/` are for.
  Other platforms need a build from source (`scons` in the addon folder, with the `godot-cpp`
  submodule checked out).

---

## 📜 License

MIT — see [`addons/image_wrangler/LICENSE`](addons/image_wrangler/LICENSE).

Third-party components (Intel Open Image Denoise, oneTBB, godot-cpp, and the editor icon set)
carry their own licenses, listed in
[`addons/image_wrangler/THIRD-PARTY-NOTICES.md`](addons/image_wrangler/THIRD-PARTY-NOTICES.md).
