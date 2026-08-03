# Intel Open Image Denoise, vendored

**Version 2.5.0**, x64 Windows, from the official Intel prebuilt drop
(`oidn-2.5.0.x64.windows.zip`, <https://github.com/RenderKit/oidn/releases>).
Apache-2.0 — see `LICENSE.txt` and the two `third-party-programs*.txt` beside it.

Used by the Denoise stage. `IWStageKernels::denoise` is the only code that touches it.

## What is here, and what is not

Kept, for building:

```
include/OpenImageDenoise/oidn.h      the C API, and the only one we include
include/OpenImageDenoise/oidn.hpp    part of the drop; MUST NOT be included — see below
include/OpenImageDenoise/config.h    version macros, pulled in by oidn.h
lib/OpenImageDenoise.lib             import library
```

**`oidn.hpp` must not be included from anywhere.** godot-cpp builds this extension with
`disable_exceptions`, which means `_HAS_EXCEPTIONS=0` and no `/EHsc`. The C++ wrapper
throws and will not compile under that. `oidn.h` is plain C and pulls in nothing but
`<stdint.h>` and `<stddef.h>`. It is kept only so the drop is complete.

The runtime DLLs are **not** here. They live in `addons/image_wrangler/bin/`, beside the
built extension, because that is the only place both loaders will find them:

- Godot adds the GDExtension's own directory to the DLL search path, so
  `OpenImageDenoise.dll` resolves as a sibling of `image_wrangler.dll`.
- `OpenImageDenoise_core.dll` loads the device module by name at runtime rather than
  importing it — the name appears nowhere in its import table — and resolves it relative
  to itself. Siblings satisfy both; a `bin/oidn/` subdirectory would satisfy neither.

Dropped from the zip, and why it is safe: the CUDA, HIP, SYCL and Metal device modules,
the SYCL runtime (`sycl8.dll`, `ur_*.dll`) and the three tools. About 24 MB. Safe only
because the kernel asks for `OIDN_DEVICE_TYPE_CPU` by name.
`OIDN_DEVICE_TYPE_DEFAULT` probes for the others and must not be used.

## The runtime is not in this repository, and is delay-loaded

The seven DLLs are 50 MB — `OpenImageDenoise_core.dll` is 48 of them — so they are ignored
by `addons/image_wrangler/.gitignore` and fetched on demand. **Press Download Runtime** on
the Denoise stage's card. The whole 56 MB zip comes down and only those seven files are
written out of it, wherever in the archive they sit; see `Denoise.RUNTIME_FILES` in
`core/denoise.gd` and `IWModelFolder._destination_for` in `ui/iw_model_folder.gd`.

**This only works because `OpenImageDenoise.dll` is delay-loaded.** It is an ordinary
load-time import otherwise, and `image_wrangler.dll` imports it directly — so a missing
`OpenImageDenoise_core.dll` would be settled by the Windows loader before any of this
project's code ran. The extension would fail to load and *every* native class would go with
it: the upscalers, the normal map network, every stage kernel. Fifty megabytes for a stage
nobody may be using is not worth that, so SConstruct passes
`/DELAYLOAD:OpenImageDenoise.dll` and links `delayimp`, and nothing is touched until the
first `oidn*` call.

**Nothing may make that call blind.** The delay-load helper reports a failure by raising a
structured exception, and this extension is built with exceptions disabled, so a failed
delayed load would take the editor down rather than return. `oidn_runtime_loaded()` in
`src/iw_denoise_kernels.cpp` is what stands in front of it, and
`IWStageKernels.denoise_available()` is how GDScript asks the same question.

Two details in that function are not decoration:

- **It loads by full path**, worked out from this extension's own module handle. Godot
  resolves the extension's imports against the folder it loaded it from, but a plain
  `LoadLibrary` later searches from the running executable — Godot's folder, not this
  addon's — and would not find it. `LOAD_WITH_ALTERED_SEARCH_PATH` is then what lets
  `OpenImageDenoise_core.dll` resolve as a sibling. Once it is in, the delay-load helper
  finds it already loaded under that name and reuses it.
- **It asks again each time** rather than remembering the answer, which is what lets a
  runtime downloaded into `bin/` work without restarting the editor. Once the DLL is there
  it costs a module-table lookup.

## The seven DLLs, and why each one

Confirmed from the import tables, not from the documentation:

| DLL | Why |
| --- | --- |
| `OpenImageDenoise.dll` | The API. Imports `OpenImageDenoise_core.dll`. |
| `OpenImageDenoise_core.dll` | Kernels and the embedded weights. 48 MB of the 49. |
| `OpenImageDenoise_device_cpu.dll` | The CPU device, loaded by name at runtime. |
| `tbb12.dll` | Imported directly by `OpenImageDenoise_device_cpu.dll`. |
| `tbbbind*.dll` | Three variants; TBB picks one at runtime for hybrid-CPU and NUMA awareness. Not fatal if absent — TBB degrades silently — but 0.4 MB total is cheaper than diagnosing it later. |

## The CRT dependency, which is not ours to remove

All three OIDN DLLs import `MSVCP140.dll`, `VCRUNTIME140.dll` and `VCRUNTIME140_1.dll` —
the *dynamic* MSVC runtime. They are not in the drop. On a development machine they
resolve from System32 and nothing looks wrong.

**An exported game therefore needs the VC++ 2015-2022 redistributable on the target
machine**, and that holds however this extension is built: godot-cpp's `use_static_cpp`
gives *our* code a static CRT, but Intel's binaries were built against the dynamic one.
The alternative is app-local deployment of those three CRT DLLs, which Microsoft's
redistribution terms permit; they would go beside the others and into the
`[dependencies]` block. Not done here, because it is a decision about how the addon is
shipped rather than about how it is built.

## Re-vendoring

Replace the four files above from the zip, and move the download with them: the version is
in the URL, so `Denoise.RUNTIME_URL` and `Denoise.RUNTIME_BYTES` in `core/denoise.gd` both
change. The seven DLLs in `bin/` are no longer committed, so nothing needs replacing there —
delete them and press Download Runtime, which is also the test that the new URL is right.
Check
`OIDN_QUALITY_*` in `oidn.h` — the values are 4, 5 and 6 rather than 0, 1 and 2, and
`quality_for()` in `src/iw_denoise_kernels.cpp` maps `DenoiseSettings.Quality` onto them
by hand precisely so a renumbering on either side is a compile-time edit rather than a
silently different filter.

A version bump no longer adds 49 MB to git history, which it did while the DLLs were
committed — only the URL and the byte count move.
