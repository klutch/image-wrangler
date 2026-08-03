#!/usr/bin/env python
"""Builds the vendored ncnn into a static library the SCons build can link.

Run once, from the addon root (addons/image_wrangler/):

    python tools/build_ncnn.py

It puts headers in thirdparty/ncnn/include/ and every static library the build produced
in thirdparty/ncnn/lib/. SConstruct picks both up from there and knows nothing about
CMake. Rerun it after the vendored ncnn source changes; nothing else needs it.

Needs CMake 3.10 or newer and a C++ compiler on PATH. It does **not** need the Vulkan
SDK: ncnn is configured with NCNN_SIMPLEVK, which means it carries its own Vulkan
declarations and loads vulkan-1.dll (or libvulkan.so) by name at runtime.

Expect this to take a while. ncnn compiles a few hundred files and glslang a few hundred
more, and the shader work on top of that is not free either.

Why a separate build at all: ncnn is a CMake project that generates a dozen headers at
configure time and compiles every GLSL shader it ships. Porting that into SConstruct
would mean owning a copy of it that goes stale the next time ncnn is updated. So it is built
the way upstream builds it, once, and what comes out is vendored exactly as Intel's
prebuilt Open Image Denoise drop is — see thirdparty/oidn/README-vendored.md for the
pattern this follows.
"""

import argparse
import os
import re
import shutil
import subprocess
import sys

ADDON_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WAIFU2X_ROOT = os.path.join(ADDON_ROOT, "thirdparty", "waifu2x-ncnn-vulkan")
NCNN_SOURCE = os.path.join(WAIFU2X_ROOT, "src", "ncnn")
DEPS_NCNN = os.path.join(WAIFU2X_ROOT, "src", "deps_ncnn.cmake")
PREFIX = os.path.join(ADDON_ROOT, "thirdparty", "ncnn")
BUILD_DIR = os.path.join(ADDON_ROOT, "thirdparty", "ncnn-build")

# Static libraries, by platform. Everything matching lands in the prefix; see collect().
LIB_SUFFIXES = (".lib", ".a")


def options_from_deps_cmake():
    """The option() lines out of waifu2x's deps_ncnn.cmake, as -D arguments.

    Read from upstream's file rather than written out here, because that list is what
    decides which of ncnn's hundred-odd layers get compiled in — and a layer waifu2x needs
    but this script forgot would not fail the build. It would fail at load, at runtime,
    inside ncnn, with a message about a layer type it has never heard of.
    """
    if not os.path.isfile(DEPS_NCNN):
        raise SystemExit("Could not find %s. It is committed to this repository, so a "
                "missing file means the checkout is incomplete." % DEPS_NCNN)

    with open(DEPS_NCNN, "r", encoding="utf-8") as handle:
        text = handle.read()

    flags = []
    for name, value in re.findall(r'option\(\s*(\w+)\s+""\s+(ON|OFF)\s*\)', text):
        flags.append("-D%s=%s" % (name, value))
    if not flags:
        raise SystemExit("Found no option() lines in %s. Has upstream changed shape?" % DEPS_NCNN)
    return flags


def configure_arguments(config):
    # A static library, with the SDK laid out where SConstruct expects it. Upstream's own
    # build wants neither: it links ncnn straight into an executable in the same tree, so
    # it has no use for an install step and says so.
    ours = {
        "NCNN_INSTALL_SDK": "ON",
        "NCNN_SHARED_LIB": "OFF",
        "NCNN_BUILD_TOOLS": "OFF",
        "NCNN_BUILD_EXAMPLES": "OFF",
        "NCNN_BUILD_TESTS": "OFF",
        "NCNN_BUILD_BENCHMARK": "OFF",
    }

    # Anything set here wins outright rather than being appended after upstream's and
    # relying on the last -D taking effect, which is true of CMake but is not the kind of
    # thing to build on.
    flags = [flag for flag in options_from_deps_cmake()
             if flag.split("=")[0][2:] not in ours]
    flags += ["-D%s=%s" % (name, value) for name, value in ours.items()]
    flags += [
        "-DCMAKE_BUILD_TYPE=" + config,
        "-DCMAKE_INSTALL_PREFIX=" + PREFIX,
        "-DCMAKE_POSITION_INDEPENDENT_CODE=ON",
        # [b]ncnn opens with cmake_minimum_required(VERSION 2.8.12...3.10), and CMake 4
        # removed compatibility with anything under 3.5.[/b] Without this the configure
        # stops on the first line of the first file with a message about the policy version
        # rather than anything to do with this project.
        #
        # This is CMake's own escape hatch for exactly that, and it raises the floor rather
        # than lowering it — every policy below 3.5 is simply treated as 3.5. Harmless on
        # CMake 3, which ignores a cache variable it has no use for.
        "-DCMAKE_POLICY_VERSION_MINIMUM=3.5",
    ]

    if sys.platform == "win32":
        # [b]The C runtime has to match, and here it can.[/b] godot-cpp defaults
        # use_static_cpp=yes, which is /MT, and a static library built against /MD would
        # drag a second CRT into the same DLL — duplicate symbols at best and two heaps at
        # worst. Unlike Intel's prebuilt OIDN, this one is built here, so it is simply
        # asked for the right one. CMP0091 is what makes the setting apply at all.
        flags += [
            "-DCMAKE_POLICY_DEFAULT_CMP0091=NEW",
            "-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded",
        ]

    return flags


def run(arguments):
    print("  " + " ".join(arguments))
    subprocess.check_call(arguments)


def hide_from_godot(directory):
    """Drops a .gdignore in [directory], so the editor does not walk it.

    [b]Not merely tidiness.[/b] Godot claims the .obj extension for Wavefront meshes, and a
    CMake build tree is thousands of compiler objects wearing exactly that name. Left
    visible, every project scan tries to import each one as a 3D model and fails, which is
    several thousand errors in the log and an import queue that never settles.

    Written by this script rather than committed, because these directories are gitignored —
    a file inside one would not survive a fresh checkout, and --clean deletes the build tree
    outright.
    """
    os.makedirs(directory, exist_ok=True)
    marker = os.path.join(directory, ".gdignore")
    if not os.path.exists(marker):
        with open(marker, "w", encoding="utf-8"):
            pass


def collect():
    """Copies every static library the build produced into the prefix.

    Swept rather than named. ncnn installs its own library and nothing else, but a static
    ncnn is not self-contained: it needs glslang and SPIRV beside it to compile the shaders
    it runs, and those are built here without being installed. The exact set of them is an
    ncnn version's business rather than this script's, so all of them are taken.
    """
    lib_dir = os.path.join(PREFIX, "lib")
    os.makedirs(lib_dir, exist_ok=True)

    taken = 0
    for root, _dirs, files in os.walk(BUILD_DIR):
        for name in files:
            if not name.endswith(LIB_SUFFIXES):
                continue
            destination = os.path.join(lib_dir, name)
            source = os.path.join(root, name)
            # The install step has already put ncnn's own library here, and it is the
            # same file.
            if os.path.abspath(source) == os.path.abspath(destination):
                continue
            shutil.copy2(source, destination)
            taken += 1

    if taken == 0:
        raise SystemExit("The build produced no static libraries. Something went wrong above.")
    print("Collected %d static librar%s into %s" % (taken, "y" if taken == 1 else "ies", lib_dir))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", default="Release",
            help="CMake build type. Release unless you are debugging ncnn itself.")
    parser.add_argument("--jobs", type=int, default=0,
            help="Parallel compile jobs. Left to CMake by default.")
    parser.add_argument("--clean", action="store_true",
            help="Throw the build tree away first.")
    args = parser.parse_args()

    if not os.path.isfile(os.path.join(NCNN_SOURCE, "CMakeLists.txt")):
        raise SystemExit(
                "No ncnn source at %s.\n"
                "\n"
                "It is not part of this addon: it is a thousand files that only somebody\n"
                "rebuilding the extension needs, and the built DLLs in bin/ already have it\n"
                "linked in. Put it there yourself to build it.\n"
                "\n"
                "  git clone --depth 1 --branch 20250916 --recurse-submodules \\\n"
                "      https://github.com/Tencent/ncnn.git \\\n"
                "      \"%s\"\n"
                "\n"
                "Version 20250916 is what the committed DLLs were built against, and\n"
                "--recurse-submodules matters: glslang is one, and ncnn does not build\n"
                "without it.\n"
                "\n"
                "Skipping this is fine. SConstruct leaves the Upscale tab and both neural\n"
                "stages out and says so; everything else builds."
                % (NCNN_SOURCE, NCNN_SOURCE))

    if shutil.which("cmake") is None:
        raise SystemExit("CMake is not on PATH. Install it from https://cmake.org/download/")

    if args.clean and os.path.isdir(BUILD_DIR):
        print("Removing %s" % BUILD_DIR)
        shutil.rmtree(BUILD_DIR)

    # Before anything is written into them, so the editor never sees a build tree it would
    # try to import.
    hide_from_godot(BUILD_DIR)
    hide_from_godot(PREFIX)

    print("Configuring ncnn")
    run(["cmake", "-S", NCNN_SOURCE, "-B", BUILD_DIR] + configure_arguments(args.config))

    print("Building ncnn. This takes a while.")
    build = ["cmake", "--build", BUILD_DIR, "--config", args.config]
    if args.jobs > 0:
        build += ["--parallel", str(args.jobs)]
    else:
        build += ["--parallel"]
    run(build)

    print("Installing headers and the library")
    run(["cmake", "--install", BUILD_DIR, "--config", args.config])

    collect()
    print("\nDone. Now build the extension:\n    scons target=editor")


if __name__ == "__main__":
    main()
