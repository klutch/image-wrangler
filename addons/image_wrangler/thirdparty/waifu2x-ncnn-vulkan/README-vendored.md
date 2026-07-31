# waifu2x-ncnn-vulkan, vendored

Upstream source from <https://github.com/nihui/waifu2x-ncnn-vulkan>, with two local changes
— see below. MIT — see `LICENSE`. The trained models in `models/` are the waifu2x project's
rather than this port's, and carry their own licence at `models/LICENSE`.

**This is a plain tracked directory, not a submodule.** It used to be a git checkout pinned
by the parent repo, which meant a clone needed `git submodule update` before it could build
and the models arrived only if that ran. The files are now committed here directly, the same
way `../realesrgan-ncnn-vulkan/` is, so a plain `git clone` has everything the build and the
Upscale tab need.

Because there is no longer a checkout to ask, the upstream commits these files came from are
recorded here instead:

| Tree | Upstream commit | Dated |
| --- | --- | --- |
| `waifu2x-ncnn-vulkan` | `64914665c45893135c9e50c1c296170a121b9f77` | 2026-02-12 |
| `src/ncnn` | `c4193aadbbb56582aa87b1850dd3d98fb8fd936d` (tag `20250916`) | 2025-09-15 |
| `src/ncnn/glslang` | version 15.3.0, per `glslang/CHANGES.md` | 2025-04-24 |

Used by the Upscale tab, as one of the two engines it offers. `src/iw_waifu2x.cpp` is the
only code that touches waifu2x itself; the ncnn built out of this tree also serves
Real-ESRGAN, which is why the second change below is here rather than beside that one. See
`../realesrgan-ncnn-vulkan/README-vendored.md`.

## The first local change: the TTA shader cache

`src/waifu2x.cpp` caches each compiled shader in a function-local `static` that is **not
keyed on TTA mode**:

```cpp
static std::vector<uint32_t> spirv;
if (spirv.empty()) { if (tta_mode) compile(...tta...); else compile(...); }
```

The cache outlives the `Waifu2x` that filled it. Upstream reads TTA once from the command
line and runs one process, so a single slot is always the right one. A checkbox in a dock is
not that: the second load reuses the first mode's shader, and since the TTA module declares
ten bindings against the plain one's three, ncnn reports `binding_count not match, expect 3
but got 10` and the process then dies in the descriptor set. It takes down the editor.

The fix is one cache per mode — four lines across the two blocks, marked in the source with
`IMAGE WRANGLER:` comments.

**It is already applied** to the files here, and needs nothing done to it. The patch is kept
at `../waifu2x-tta-shader-cache.patch` only as a record of what diverges from upstream, which
matters now that this is a tracked directory rather than a checkout — there is no upstream
remote left to diff against. Applying it again would fail.

## The second local change: four more ncnn layers

`src/deps_ncnn.cmake` is the layer whitelist — see the section on it below. Four entries are
flipped from `OFF` to `ON`: `binaryop`, `pixelshuffle`, `prelu` and `concat`. **waifu2x uses
none of them.** They are Real-ESRGAN's, and this file is where the switches live because
this is the tree ncnn is built out of.

Recorded as `../waifu2x-realesrgan-layers.patch` on the same terms as the one above —
already applied, kept for reference — and marked in the source with `IMAGE WRANGLER:`
comments. Turning any of them off again breaks Real-ESRGAN at model load, not at build time.

Nothing else in the tree is edited.

## Why this one is built and Open Image Denoise is not

The other vendored dependency here is a prebuilt drop: Intel ships binaries, and
`thirdparty/oidn/` holds an import library and some headers. waifu2x ships source only, so
there is a build step, and it is the one thing about this dependency that costs anything.

**Run it once:**

```
cd addons/image_wrangler
python tools/build_ncnn.py
scons target=editor
```

Needs CMake and a C++ compiler. It does **not** need the Vulkan SDK — see below. Expect
twenty minutes or so the first time; ncnn and glslang together are well over a thousand
source files.

**On CMake 4.** ncnn opens with `cmake_minimum_required(VERSION 2.8.12...3.10)`, and CMake
4 removed compatibility with anything under 3.5 — left alone it stops on the first line of
the first file with a message about policy versions and nothing about this project. The
script passes `CMAKE_POLICY_VERSION_MINIMUM=3.5`, which is CMake's own escape hatch for
exactly that, and raises the floor rather than lowering it. Harmless on CMake 3.

The results land in `thirdparty/ncnn/` and are gitignored. Only the person rebuilding the
extension needs them: what gets committed is `bin/image_wrangler*.dll`, with all of this
already linked in, so an ordinary checkout of the addon has a working Upscale tab and no
build step at all.

**Without that step the addon still builds.** SConstruct notices `thirdparty/ncnn/` is
missing, leaves both networks and both wrappers out, and says so. The Upscale tab then finds
no `IWWaifu2x` class and tells you what to run.

## What is kept from upstream, and what is not

Kept:

```
src/waifu2x.cpp          the network, the tiling and the TTA passes — compiled into the extension
src/waifu2x.h            its header
src/waifu2x_*.comp       four compute shaders, embedded at build time (see below)
src/ncnn/                the inference library, built by tools/build_ncnn.py — used by
                         Real-ESRGAN as well
models/                  the three trained model directories, read at runtime by path
```

Real-ESRGAN's models used to sit in `models/` too. They are not waifu2x's and nothing here
can load them, so they moved to `../realesrgan-ncnn-vulkan/models/`.

Deleted, because nothing here builds or reads them. They used to arrive with the checkout;
committing the tree meant deciding what was worth carrying, and this was not:

- `src/main.cpp`, and the image-loading headers beside it — the command-line tool. It does
  argument parsing, directory walking and a three-stage thread pipeline around the same
  `Waifu2x` class this links against directly. `iw_waifu2x.cpp` reimplements the two parts
  of it that matter: which model file a noise level and ratio resolve to, and the loop that
  reaches 4x and above by running the 2x network again. Both are commented there as being
  upstream's.
- `src/libpng`, `src/libjpeg-turbo`, `src/libwebp`, `src/zlib-ng` — file decoding, for
  reading images off disk, and only ever used by `main.cpp`. Godot has already decoded the
  image by the time any of this is reached.
- `src/CMakeLists.txt` and the rest of upstream's build — `tools/build_ncnn.py` points CMake
  straight at `src/ncnn/`, and SConstruct compiles `waifu2x.cpp` itself. Neither ever read
  upstream's own build files. `src/deps_ncnn.cmake` is the exception and is kept, because the
  script parses it; see the section on the layer whitelist below.
- `images/` — upstream's README samples, which Godot had begun importing.
- Inside `src/ncnn/`: `examples/`, `tests/`, `benchmark/`, `tools/`, `python/`, `docs/` and
  its own `images/`. `tools/build_ncnn.py` already builds with `NCNN_BUILD_TOOLS`,
  `NCNN_BUILD_EXAMPLES`, `NCNN_BUILD_TESTS` and `NCNN_BUILD_BENCHMARK` all `OFF`, so none of
  these was ever compiled.
- Inside `src/ncnn/glslang/`: `Test/` — a 42 MB corpus, and the single biggest thing here —
  along with `gtests/`, `External/` and the CI scripts. ncnn sets `GLSLANG_TESTS`,
  `BUILD_EXTERNAL` and `ENABLE_GLSLANG_BINARIES` to `OFF`, so none of it is reached.

That takes the folder from 175 MB to 70 MB. Both licence texts the notices point at —
`src/ncnn/LICENSE.txt` and `src/ncnn/glslang/LICENSE.txt` — are deliberately kept.

### Two files that look prunable and are not

Both were deleted on the first pass and had to be put back. Anyone tidying this folder again
will reach for them, so:

- `src/ncnn/glslang/CHANGES.md` is **not** a changelog as far as the build is concerned. It
  is where glslang's version number comes from: `parse_version.cmake` reads the first
  `## <major>.<minor>.<patch>` heading out of it, and CMake stops with `Unable to parse
  version` if it is missing.
- `src/ncnn/glslang/StandAlone/DirStackFileIncluder.h` is the one file in `StandAlone/` that
  the glslang *library* uses — `glslang_c_interface.cpp` includes it. The rest of that folder
  builds only the command-line binaries, which are switched off, so the folder is otherwise
  empty here.

## No Vulkan SDK, and no compute shaders of ours

ncnn is configured with `NCNN_SIMPLEVK=ON`, which is upstream's own setting for this
project. It means ncnn carries the Vulkan declarations it needs and resolves the driver by
name at runtime — `vulkan-1.dll` on Windows — so nothing here has to find or ship an SDK.
A machine with no Vulkan driver falls back to the CPU path, which works and is perhaps a
hundred times slower; `IWWaifu2x.gpu_available()` is how the dock knows which it is on.

The four `.comp` files are GLSL compute shaders, and they are waifu2x's, not this addon's.
They are pre- and post-processing for the network — packing pixels into the layout ncnn
wants and back out again — and glslang compiles them to SPIR-V at runtime, inside ncnn.
SConstruct's only involvement is embedding the GLSL text as a byte array, which is a port
of upstream's `generate_shader_comp_header.cmake`. No part of Image Wrangler's own image
processing uses a compute shader.

## The layer whitelist, and why the build script reads upstream's file

ncnn compiles one class per network layer type, and `src/deps_ncnn.cmake` switches most of
them off — waifu2x uses about fifteen of a hundred-odd, and Real-ESRGAN four more.
`tools/build_ncnn.py` parses that file for its `option()` lines rather than carrying its own
copy of the list.

That is deliberate. A layer left out does not fail the build. It fails at model load,
inside ncnn, with a message about an unknown layer type — so a list that drifted out of
step with upstream would break at runtime, on somebody else's machine, long after the
change that caused it.

## The C runtime, which here does match

godot-cpp defaults `use_static_cpp=yes`, which is `/MT`. `tools/build_ncnn.py` passes
`CMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded` so ncnn is built against the same one. Unlike
Intel's prebuilt OIDN — see `thirdparty/oidn/README-vendored.md`, which explains why that
mismatch is survivable — this library is built here, so it is simply asked for the right
runtime and there is no mismatch to reason about.

`NCNN_DISABLE_EXCEPTION=ON` gives ncnn `/D_HAS_EXCEPTIONS=0`, which is the same macro
godot-cpp sets for `disable_exceptions`. The two sides therefore agree about the shape of
the standard library, which they must: they pass `std::string` and `std::vector` across the
boundary.

`NCNN_OPENMP` is left at upstream's default, which is on. That means the objects carry a
`/DEFAULTLIB` directive for the MSVC OpenMP runtime, so an exported project needs
`vcomp140.dll` from the VC++ redistributable. It adds no new burden: Intel's OIDN binaries
already require that redistributable, for the reasons in `../oidn/README-vendored.md`. It
only matters for the CPU fallback path — on a machine with a Vulkan driver, none of the
threaded CPU kernels are reached.

## Godot and this folder

`src/.gdignore` keeps the editor from walking the couple of thousand C++ files under
`src/ncnn/`. `models/` is deliberately left visible — those files are read at
runtime by absolute path, so they have to exist on disk rather than only inside a `.pck`.
Nothing in `models/` is a Godot resource; the editor leaves `.bin` and `.param` alone.
