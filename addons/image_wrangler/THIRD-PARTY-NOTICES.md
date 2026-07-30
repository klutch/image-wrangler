# Third-party notices

Image Wrangler itself is MIT licensed — see `LICENSE`. It also ships or links against the
components below, each under its own permissive licence. None of them place any condition
on the licence of Image Wrangler's own code; all they ask is that these notices travel
with the binaries.

If you redistribute this addon, keep this file and the licence texts it points at. Every
path below is relative to this folder, which is self-contained: copying it into another
Godot project brings the notices along with the binaries they cover.

## Intel Open Image Denoise 2.5.0 — Apache-2.0

Copyright Intel Corporation.

Used by the Denoise stage. Shipped unmodified as prebuilt binaries in `bin/`:

- `OpenImageDenoise.dll`
- `OpenImageDenoise_core.dll` (includes the pretrained CNN weights, also Apache-2.0)
- `OpenImageDenoise_device_cpu.dll`

Licence text: `thirdparty/oidn/LICENSE.txt`
Upstream notices: `thirdparty/oidn/third-party-programs.txt`

Source and releases: <https://github.com/RenderKit/oidn>

Image Wrangler does not modify Open Image Denoise. It calls the public C API only, and
links against the import library in `thirdparty/oidn/lib/`. See
`thirdparty/oidn/README-vendored.md` for what was kept from the official drop and why.

## Intel oneAPI Threading Building Blocks (oneTBB) — Apache-2.0

Copyright Intel Corporation.

A runtime dependency of Open Image Denoise's CPU device, not used directly by Image
Wrangler. Shipped unmodified in `bin/`:

- `tbb12.dll`
- `tbbbind.dll`, `tbbbind_2_0.dll`, `tbbbind_2_5.dll`

Licence text: `thirdparty/oidn/LICENSE.txt` (the same Apache-2.0 terms)
Upstream notices: `thirdparty/oidn/third-party-programs-oneTBB.txt`

Source: <https://github.com/uxlfoundation/oneTBB>

## waifu2x-ncnn-vulkan — MIT

Copyright (c) 2019 nihui.

Used by the Upscale tab. One source file from it, `src/waifu2x.cpp`, is compiled into
`image_wrangler.windows.*.dll`, along with its four GLSL compute shaders. The trained
models in `thirdparty/waifu2x-ncnn-vulkan/models/` are read at runtime and ship as they
came.

Licence text: `thirdparty/waifu2x-ncnn-vulkan/LICENSE`

Source and releases: <https://github.com/nihui/waifu2x-ncnn-vulkan>

**Modified.** One bug fix is applied to `src/waifu2x.cpp`, kept as a patch alongside it at
`thirdparty/waifu2x-tta-shader-cache.patch`: its compiled-shader cache is a function-local
static that is not keyed on TTA mode, so switching that setting inside one process runs the
wrong shader and crashes. Upstream picks TTA once from the command line, so it never meets
this; a checkbox in a dock does. The patch is marked in the source with `IMAGE WRANGLER:`
comments.

Past that, `src/iw_waifu2x.cpp` calls the `Waifu2x` class and reimplements the two decisions
its command-line front end makes — which model file a noise level and ratio resolve to, and
how a ratio above 2 is reached. See `thirdparty/waifu2x-ncnn-vulkan/README-vendored.md`.

The models are the waifu2x project's, originally by nagadomi
(<https://github.com/nagadomi/waifu2x>), MIT.

## ncnn — BSD-3-Clause

Copyright (C) 2017 Tencent. All rights reserved.

The neural network inference library underneath waifu2x, built from source by
`tools/build_ncnn.py` and linked statically into `image_wrangler.windows.*.dll`. Not called
directly by this addon.

Licence text: `thirdparty/waifu2x-ncnn-vulkan/src/ncnn/LICENSE.txt`, which also lists the
third-party components inside ncnn and their own terms.

Source: <https://github.com/Tencent/ncnn>

## glslang — BSD-3-Clause and others

Copyright (c) 2002-2005 3Dlabs Inc. Ltd., and others.

Bundled inside ncnn, which uses it to compile its shaders to SPIR-V at runtime. Linked
statically into `image_wrangler.windows.*.dll`. Not called directly by this addon.

Licence text: `thirdparty/waifu2x-ncnn-vulkan/src/ncnn/glslang/LICENSE.txt`, which covers
several licences — the file lists which applies to what.

Source: <https://github.com/KhronosGroup/glslang>

## godot-cpp — MIT

Copyright (c) 2017-present Godot Engine contributors.

The GDExtension binding, compiled into `image_wrangler.windows.*.dll`. Included as a git
submodule; licence text is at `godot-cpp/LICENSE.md` in a full checkout.

Source: <https://github.com/godotengine/godot-cpp>

## Godot Engine editor icons — MIT

Copyright (c) 2014-present Godot Engine contributors.
Copyright (c) 2007-2014 Juan Linietsky, Ariel Manzur.

`ui/icons/` is a copy of the Godot editor's own icon artwork, so the dock can draw icons
at a larger size than the editor theme provides.

Licence text: `ui/icons/LICENSE.txt`

Source: <https://github.com/godotengine/godot>

The Godot Engine *logo* is licensed separately (CC BY 4.0, by Andrea Calabró) and is
deliberately **not** included in that folder.

## Microsoft Visual C++ runtime — not redistributed here

Intel's Open Image Denoise binaries import the dynamic MSVC runtime (`MSVCP140.dll`,
`VCRUNTIME140.dll`, `VCRUNTIME140_1.dll`), which is not bundled with this addon. A machine
running an exported project needs the Visual C++ 2015-2022 redistributable installed. See
`thirdparty/oidn/README-vendored.md`.
