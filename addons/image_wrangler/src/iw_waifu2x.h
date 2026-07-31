#pragma once

// waifu2x, wrapped for the Upscale tab.
//
// The vendored upstream is a command-line tool: it reads a file, runs the network, writes
// a file. Only the middle of that is wanted here, so this holds the one class from it that
// does the work — `Waifu2x`, out of thirdparty/waifu2x-ncnn-vulkan/src/waifu2x.cpp — and
// gives GDScript an Image in, Image out. Nothing touches the disk except the model, which
// ncnn insists on reading by path.
//
// [b]Held open across a batch, unlike every other native class here.[/b] The rest are
// static kernels called and forgotten. This one is not: bringing up a Vulkan device,
// compiling the two SPIR-V modules and reading a model off disk costs a second or two and
// is identical for every image in a run. So the dock opens one of these, runs the whole
// list through it, and closes it — which is also why `close` exists rather than being left
// to the destructor.
//
// The Vulkan instance underneath is process-wide, shared with [IWRealESRGAN], and outlives
// any one of these; see `iw_ncnn_instance.h`.

#include <godot_cpp/classes/global_constants.hpp>
#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>

// Forward-declared rather than included: waifu2x.h pulls in ncnn's net.h, gpu.h and
// layer.h, and nothing outside this class's own translation unit has any business seeing
// them.
class Waifu2x;

namespace godot {

class IWWaifu2x : public RefCounted {
    GDCLASS(IWWaifu2x, RefCounted)

protected:
    static void _bind_methods();

public:
    IWWaifu2x();
    ~IWWaifu2x();

    // Denoise levels the models are trained for. -1 is "leave the noise alone", which is
    // a separate model rather than a strength of zero.
    static constexpr int64_t NOISE_NONE = -1;
    static constexpr int64_t NOISE_MIN = -1;
    static constexpr int64_t NOISE_MAX = 3;

    // Whether there is a Vulkan device to run on at all.
    //
    // False on a machine with no Vulkan driver, and on one whose driver refused to bring
    // an instance up. The CPU path still works and is perhaps a hundred times slower, so
    // this is worth asking before offering the feature rather than after.
    //
    // [b]An ordinary method rather than a static one, though it answers nothing about this
    // instance.[/b] The whole class is optional — a build that has not had ncnn made for it
    // does not contain it — so GDScript reaches everything here through
    // `ClassDB.instantiate`, and a static bound method is not reachable that way without
    // naming the class in source, which is the one thing an optional class cannot survive.
    bool has_gpu() const;

    // Brings up a device and reads the model. [param model_dir] is a full path to one of
    // the directories [method list_models] returns.
    //
    // Returns OK, or an error with [method get_last_error] set to a line worth showing.
    // Both are answered before anything is constructed: upstream's loader reports a
    // missing model to stderr and then reads from the null file handle anyway, so the
    // files are checked here rather than there.
    Error open(const String &model_dir, int64_t noise, int64_t scale, bool tta);

    // Drops the device, the model and the two pipelines. Safe to call on a closed one.
    void close();

    bool is_open() const;

    // The upscaled image, or null when this is not open or [param source] is empty.
    //
    // Runs the 2x network log2(scale) times over, which is what upstream does for 4 and
    // above — there is no 4x model. Alpha comes through: it is carried by a bicubic
    // resize rather than by the network, which is upstream's own arrangement and the
    // reason a keyed sprite survives this at all.
    Ref<Image> process(const Ref<Image> &source);

    // Why the last call failed, or empty when it did not.
    String get_last_error() const;

private:
    // Whether [param scale] is one of the ratios waifu2x accepts.
    static bool is_supported_scale(int64_t scale);

    // What upstream pads each tile by before running it, which depends on the model and
    // on what is being asked of it. Negative for a model directory whose name says
    // nothing about which of the three it is — see the note in the implementation.
    static int prepadding_for(const String &model_dir, int64_t noise, int64_t scale);

    // Tile size for [param model_dir] on the device now open, from the free video memory.
    static int tile_size_for(const String &model_dir);

    Waifu2x *worker = nullptr;

    // The ratio asked for, 1 to 32, which is not the ratio the network runs at — that is
    // always 2 above a ratio of 1.
    int scale_factor = 2;

    String last_error;
};

} // namespace godot
