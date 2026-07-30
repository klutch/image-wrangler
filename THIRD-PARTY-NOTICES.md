# Third-party notices

Image Wrangler itself is MIT licensed — see `LICENSE`. It also ships or links against the
components below, each under its own permissive licence. None of them place any condition
on the licence of Image Wrangler's own code; all they ask is that these notices travel
with the binaries.

If you redistribute this addon, keep this file and the licence texts it points at.

## Intel Open Image Denoise 2.5.0 — Apache-2.0

Copyright Intel Corporation.

Used by the Denoise stage. Shipped unmodified as prebuilt binaries in
`addons/image_wrangler/bin/`:

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
Wrangler. Shipped unmodified in `addons/image_wrangler/bin/`:

- `tbb12.dll`
- `tbbbind.dll`, `tbbbind_2_0.dll`, `tbbbind_2_5.dll`

Licence text: `thirdparty/oidn/LICENSE.txt` (the same Apache-2.0 terms)
Upstream notices: `thirdparty/oidn/third-party-programs-oneTBB.txt`

Source: <https://github.com/uxlfoundation/oneTBB>

## godot-cpp — MIT

Copyright (c) 2017-present Godot Engine contributors.

The GDExtension binding, compiled into `image_wrangler.windows.*.dll`. Included as a git
submodule; licence text is at `godot-cpp/LICENSE.md` in a full checkout.

Source: <https://github.com/godotengine/godot-cpp>

## Godot Engine editor icons — MIT

Copyright (c) 2014-present Godot Engine contributors.
Copyright (c) 2007-2014 Juan Linietsky, Ariel Manzur.

`addons/image_wrangler/ui/icons/` is a copy of the Godot editor's own icon artwork, so the
dock can draw icons at a larger size than the editor theme provides. `extension_api.json`
also comes from Godot.

Licence text: `addons/image_wrangler/ui/icons/LICENSE.txt`

Source: <https://github.com/godotengine/godot>

The Godot Engine *logo* is licensed separately (CC BY 4.0, by Andrea Calabró) and is
deliberately **not** included in that folder.

## Microsoft Visual C++ runtime — not redistributed here

Intel's Open Image Denoise binaries import the dynamic MSVC runtime (`MSVCP140.dll`,
`VCRUNTIME140.dll`, `VCRUNTIME140_1.dll`), which is not bundled with this addon. A machine
running an exported project needs the Visual C++ 2015-2022 redistributable installed. See
`thirdparty/oidn/README-vendored.md`.
