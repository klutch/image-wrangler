#pragma once

// Real-ESRGAN, wrapped for the Upscale tab.
//
// The sibling of [IWWaifu2x], and deliberately shaped like it: an Image in, an Image out,
// held open across a batch, nothing on disk but the model. The two are separate classes
// rather than one with a switch because the networks are not the same shape — Real-ESRGAN
// enlarges by 2, 3 or 4 in a single pass and has no denoising at all, where waifu2x only
// ever doubles and picks a model by denoise level. See
// thirdparty/realesrgan-ncnn-vulkan/README-vendored.md.
//
// The Vulkan instance underneath is shared with [IWWaifu2x]; see `iw_ncnn_instance.h`.

#include <godot_cpp/classes/global_constants.hpp>
#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>

// Forward-declared for the same reason waifu2x's class is: realesrgan.h pulls in ncnn's
// net.h, gpu.h and layer.h, and nothing outside this translation unit should see them.
class RealESRGAN;

namespace godot {

class IWRealESRGAN : public RefCounted {
    GDCLASS(IWRealESRGAN, RefCounted)

protected:
    static void _bind_methods();

public:
    IWRealESRGAN();
    ~IWRealESRGAN();

    // Ratios the networks come in. Every one is a single pass — there is no doubling and
    // repeating here, which is why the ceiling is 4 rather than waifu2x's 32.
    static constexpr int64_t SCALE_MIN = 2;
    static constexpr int64_t SCALE_MAX = 4;

    // What every Real-ESRGAN model wants each tile padded by. One number for all of them,
    // where waifu2x has three — see the note in the implementation.
    static constexpr int PREPADDING = 10;

    // Whether there is a Vulkan device to run on at all.
    //
    // An ordinary method rather than a static one, for the reason given on
    // [method IWWaifu2x.has_gpu]: the class is left out of a build that has not had ncnn
    // made for it, so GDScript reaches it through `ClassDB.instantiate` and never by name.
    bool has_gpu() const;

    // Brings up a device and reads the model. [param model_dir] is a full path to a folder
    // holding one, and [param scale] must be one the folder actually ships.
    //
    // Returns OK, or an error with [method get_last_error] set to a line worth showing.
    Error open(const String &model_dir, int64_t scale, bool tta);

    // Drops the device, the model and the two pipelines. Safe to call on a closed one.
    void close();

    bool is_open() const;

    // The upscaled image, or null when this is not open or [param source] is empty.
    //
    // One pass, whatever the ratio. Alpha comes through on a bicubic resize beside the
    // network rather than through it, which is upstream's arrangement and waifu2x's too.
    Ref<Image> process(const Ref<Image> &source);

    // Why the last call failed, or empty when it did not.
    String get_last_error() const;

    // Every ratio [param model_dir] actually ships a network for, ascending, or empty for
    // a folder holding none.
    //
    // Bound because the dock has the same question: it fills a Scale dropdown and must not
    // offer a ratio that would fail on the way in. Asking here rather than working it out
    // in GDScript keeps one copy of the naming rule — and the rule is the whole of it,
    // since which files exist is what decides.
    PackedInt32Array supported_scales(const String &model_dir) const;

private:
    // The model files [param model_dir] would load at [param scale], or empty strings when
    // it ships none for that ratio.
    static void model_files(const String &model_dir, int64_t scale, String &r_param, String &r_bin);

    // Tile size for the device now open, from the free video memory.
    static int tile_size();

    RealESRGAN *worker = nullptr;

    int scale_factor = 4;

    String last_error;
};

} // namespace godot
