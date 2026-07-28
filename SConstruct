#!/usr/bin/env python
"""Builds the Image Wrangler GDExtension.

    scons target=editor              # what the editor and the parity harness load
    scons target=template_release    # what an exported project would load

The library lands in addons/image_wrangler/bin/ and is committed, so the addon works
from a checkout without anyone having to build it.

Godot holds the DLL open while it is running. A build that fails with a permission
error on the link step means the editor is still up — close it. The parity harness runs
in a separate process that exits, so it does not get in the way.
"""

env = SConscript("godot-cpp/SConstruct")

# Floating-point parity with the GDScript this replaces.
#
# The whole port is gated on producing identical bytes, and fast-math is the one
# compiler setting that would quietly break that everywhere at once: it permits
# reassociation, it lets a*b+c contract into a single fused multiply-add with one
# rounding instead of two, and it assumes no NaN. The guided filter and the coverage
# maths both do exactly the kind of arithmetic those change.
#
# /fp:precise is already the MSVC default and -ffast-math is already off for GCC and
# Clang; both are set here anyway, because a default is something that can change
# under you and a flag is not.
if env.get("is_msvc", False):
    env.Append(CCFLAGS=["/fp:precise", "/fp:except-"])
else:
    env.Append(CCFLAGS=["-ffp-contract=off", "-fno-fast-math"])

env.Append(CPPPATH=["src/"])

# Intel Open Image Denoise, for the Denoise stage.
#
# Vendored and committed under thirdparty/, and deliberately not under src/ — the glob
# below is flat and would sweep any source there into the build under this project's own
# flags. Only headers and an import library are needed here; the runtime DLLs are
# committed straight into addons/image_wrangler/bin/ beside the extension, which is where
# both Godot's loader and OIDN's own module lookup expect them. See
# thirdparty/oidn/README-vendored.md.
env.Append(CPPPATH=["thirdparty/oidn/include"])
env.Append(LIBPATH=["thirdparty/oidn/lib"])
env.Append(LIBS=["OpenImageDenoise"])

if env.get("is_msvc", False):
    # The CRTs do not match, and that is all right.
    #
    # godot-cpp defaults use_static_cpp=yes, which is /MT; Intel's prebuilt OIDN is built
    # against the dynamic CRT. What a mismatch rules out is sharing CRT state across the
    # boundary — memory one side allocates and the other frees, a FILE*, a locale. The
    # denoise kernel does none of it: every buffer handed over is ours, passed by
    # oidnSetSharedFilterImage and freed by us, and nothing OIDN allocates ever leaves
    # OIDN. An import library links no foreign CRT objects either.
    #
    # Switching to use_static_cpp=no would silence the warning and cost every exported
    # game a dependency on the VC++ redistributable. Not a trade worth making — and see
    # the README, because OIDN's own DLLs impose that dependency regardless.
    #
    # godot-cpp has already put /WX on the linker, so an advisory warning here is a
    # failed build. These two are named rather than the flag being dropped: 4098 is the
    # CRT remark above, 4099 is "no PDB for OpenImageDenoise.lib" — there is not one, and
    # godot-cpp defaults debug_symbols=no in any case.
    env.Append(LINKFLAGS=["/IGNORE:4098", "/IGNORE:4099"])

sources = Glob("src/*.cpp")

library = env.SharedLibrary(
    "addons/image_wrangler/bin/image_wrangler{}{}".format(env["suffix"], env["SHLIBSUFFIX"]),
    source=sources,
)

Default(library)
