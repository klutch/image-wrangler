#pragma once

// The Vulkan instance ncnn runs on, brought up once and shared.
//
// [b]Process-wide because ncnn's is.[/b] `create_gpu_instance` enumerates the physical
// devices once and every `VulkanDevice` handed out afterwards points into that
// enumeration — so there is one instance, not one per upscaler and not one per class.
//
// Two classes now sit on top of it, [IWWaifu2x] and [IWRealESRGAN], and that is the reason
// this is its own file rather than a few statics inside one of them. Either can be the
// first to want a device and either can be the last to let one go, and a count kept by one
// of them would let the other tear the instance down out from under a live device.

namespace iw_ncnn {

// Brings the instance up on first use, and remembers whether it came.
//
// False on a machine with no Vulkan driver, and on one whose driver refused. Nothing is
// pushed as an error — ncnn reports the failure on stderr itself, and the caller turns
// this into a line on the dock instead.
bool ensure_instance();

// Says another upscaler is open, or that one has closed. The instance outlives every one
// of them; see [method shutdown].
void retain();
void release();

// Tears the instance down. Called once, from the extension's terminator.
//
// Stands down while anything is still open: ncnn's teardown frees the device every live
// upscaler still holds a pointer into. Leaking it instead costs nothing — the process is
// on its way out, and the driver reclaims it.
void shutdown();

} // namespace iw_ncnn
