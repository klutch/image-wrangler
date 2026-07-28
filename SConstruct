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
sources = Glob("src/*.cpp")

library = env.SharedLibrary(
    "addons/image_wrangler/bin/image_wrangler{}{}".format(env["suffix"], env["SHLIBSUFFIX"]),
    source=sources,
)

Default(library)
