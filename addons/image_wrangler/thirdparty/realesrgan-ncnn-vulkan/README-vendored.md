# Real-ESRGAN-ncnn-vulkan, vendored

Upstream from <https://github.com/xinntao/Real-ESRGAN-ncnn-vulkan>. MIT — see `LICENSE`.
The trained models are the Real-ESRGAN project's
(<https://github.com/xinntao/Real-ESRGAN>) and are BSD-3-Clause, not MIT — their own text
sits beside them in `models/LICENSE`.

Used by the Upscale tab as the second choice of engine, beside waifu2x. `src/iw_realesrgan.cpp`
is the only code that touches it.

## Not a checkout

This folder is **not** a clone of upstream, unlike `../waifu2x-ncnn-vulkan/`. Only two
things were taken: the network class and the four compute shaders, both rewritten against
the ncnn this project actually builds. Everything else upstream ships — the command-line
front end, the image codecs, its own copy of ncnn — is either unnecessary here or already
present next door.

```
src/realesrgan.h        the class, upstream's interface
src/realesrgan.cpp      the tiling, the padding, the alpha handling — upstream's, adapted
src/realesrgan_*.comp   four compute shaders, embedded at build time
models/                 three trained model directories, read at runtime by path —
                        downloaded rather than committed, see below
```

**The models used to live in `../waifu2x-ncnn-vulkan/models/`**, which was wrong: they are
not waifu2x's, they are not covered by its licence, and nothing in that project can load
them. They moved here unchanged.

## The models are not in this repository

`models/` holds 44 MB of trained networks — a quarter of everything the repository tracked.
They are ignored by `addons/image_wrangler/.gitignore` and fetched on demand instead, the
same way the Neural normal map layer's model is. `models/LICENSE` stays committed, because
the licence has to be there whether or not the files it covers are.

**Press Download Latest Model** in the Upscale tab, under the Model dropdown. It appears
only when Real-ESRGAN is the selected engine, since waifu2x's models are small enough to
ship and are still committed next door. Until the models arrive the tab says so and runs
nothing.

The archive is
`realesrgan-ncnn-vulkan-20220424-windows.zip`, 45 MB, from the **Real-ESRGAN** releases —
see `Upscale.MODEL_SOURCES` in `core/upscale.gd`. Not from the ncnn port's own releases:
that repository has no `models/` folder at all and its release zips carry only the program.

**The archive is not arranged the way this folder is.** It puts every model file together in
one `models/` folder, beside a program, two runtime libraries, two sample images and a video.
The download keeps only the `.param` and `.bin` files and sorts them into a folder each, by
taking any trailing ratio off the file name — `realesr-animevideov3-x2` goes in
`realesr-animevideov3`, and `realesrgan-x4plus`, whose 4 is part of the name rather than a
ratio, names its own folder. See `IWModelFolder._destination_for` in
`ui/iw_model_folder.gd`. Nothing else in the archive is written to disk.

## What was changed, and why

Every change is marked in the source with an `IMAGE WRANGLER:` comment.

**The shaders are compiled at runtime.** Upstream embeds SPIR-V it built ahead of time, in
six variants of each shader, and picks one by inspecting `net.opt`. That needs a shader
compiler at build time and a checked-in blob per variant. waifu2x's newer code hands the
GLSL to `compile_spirv_module` instead and lets glslang — which is already inside ncnn —
pick the variant itself. The shaders here are therefore written in waifu2x's style: no
hand-rolled `#define sfp`, and `buffer_ld1`/`buffer_st1` for the loads and stores, which is
what the current ncnn's preamble provides.

The two shaders differ from waifu2x's in exactly two ways, and both are Real-ESRGAN's:

- The preproc **mirrors at the image edge** where waifu2x repeats the edge pixel.
- The postproc takes **`crop_x` and `crop_y`**. waifu2x's convolutions do not pad, so its
  tile comes back already shorn of the border it was given. Real-ESRGAN's do pad, so the
  border comes back out and the postproc has to skip past `prepadding * scale` of it.

**One cache per TTA mode**, the same fix `../waifu2x-tta-shader-cache.patch` makes upstream
next door. The compiled shader is held in a function-local `static` that outlives the object
that filled it, and the TTA module declares ten bindings against the plain one's three — so
a cache shared between the two modes hands out the wrong shader on the second load and
takes the editor down with it.

**A CPU path**, which upstream does not have at all: it is Vulkan or nothing. `process_cpu`
is waifu2x's, with the same two differences the GPU path has — no alignment padding to round
a tile up for a deconvolution, and every read out of the network's answer offset past the
border. It repeats the edge pixel rather than mirroring it, because ncnn's
`copy_make_border` offers no mirror; that shows only in the outermost ten pixels of the
whole image. **It is untested** — this machine has a Vulkan driver, so nothing here has
exercised it.

**Guarded destructor.** Upstream dereferences its three `Interp` layers unconditionally, so
an instance whose `load` never ran cannot be destroyed. The wrapper needs to throw one away
after a model file turns out to be missing.

**No progress on stderr.** Upstream prints a percentage per tile. Nothing in the editor
reads it.

## The models, and which ratios each does

| Folder | Ratios | Layers | Notes |
| --- | --- | --- | --- |
| `realesr-animevideov3` | 2x, 3x, 4x | 40 | Much the fastest. Separate network per ratio. |
| `realesrgan-x4plus-anime` | 4x | 268 | |
| `realesrgan-x4plus` | 4x | 999 | Much the slowest. Photographs. |

The naming is upstream's and the wrapper reads it rather than carrying a table: a folder
shipping several ratios puts the ratio in the file name (`realesr-animevideov3-x3.param`),
and one shipping a single ratio names the file after itself (`realesrgan-x4plus.param`) with
the ratio in the folder name. `IWRealESRGAN.supported_scales` is what the Scale dropdown
asks, so a ratio a folder cannot do is never offered — which matters, because the failure
would not be graceful. The network would run at its own ratio into a buffer sized for
another.

**Prepadding is 10 for all of them**, where waifu2x has three numbers and refuses a folder
it does not recognise. Upstream pads everything in its models directory by ten, so a folder
somebody drops in here gets the same.

## The four ncnn layers this needed

ncnn compiles one class per layer type and `../waifu2x-ncnn-vulkan/src/deps_ncnn.cmake`
switches most of them off. Four that waifu2x does not use had to be turned on:

| Layer | Wanted by |
| --- | --- |
| `binaryop` | all three — each adds a resized copy of the input back onto the output |
| `pixelshuffle` | `realesr-animevideov3`, which enlarges with one |
| `prelu` | `realesr-animevideov3`, as its activation |
| `concat` | the two `x4plus` models, for their dense blocks |

That edits the waifu2x tree, so it is recorded as `../waifu2x-realesrgan-layers.patch`
beside the TTA one. **Both are already applied** — that tree is committed to this repository
rather than checked out, so nothing needs reapplying and the patches are kept only as a
record of what diverges from upstream. See `../waifu2x-ncnn-vulkan/README-vendored.md`.

`tools/build_ncnn.py` reads `deps_ncnn.cmake` for its `option()` lines, so turning a layer on
there is the whole of it — but **ncnn has to be rebuilt afterwards**, and a layer left out
does not fail the build. It fails at model load, inside ncnn, with a message about an unknown
layer type.

## No separate build step

Everything else this needs is already there. ncnn is built once by `tools/build_ncnn.py`
for waifu2x and serves both networks; the Vulkan instance underneath is shared too, which
is what `src/iw_ncnn_instance.h` exists for. Without `thirdparty/ncnn/`, SConstruct leaves
`IWWaifu2x` and `IWRealESRGAN` both out and the Upscale tab says what to run.
