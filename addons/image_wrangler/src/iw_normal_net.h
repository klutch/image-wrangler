#pragma once

// A trained network, wrapped for IWPacking's Neural normal mode.
//
// The third class here built on ncnn, and shaped like [IWWaifu2x] and [IWRealESRGAN] on
// purpose — open a folder, hold it across a run, close it. It differs from those two in
// what it is handed and what it gives back: they take one picture and return a bigger one,
// where this takes a packed sheet and the rectangle of every sprite on it and returns a
// normal map for the whole sheet.
//
// [b]No model ships with this addon.[/b] Nothing here names a network, downloads one or
// carries weights — the folder is the user's, and the class stands down when it holds
// nothing loadable. That is what keeps the addon's own licence clear of whatever the model
// was trained and released under. See the Model Folder setting on the Export tab.
//
// [b]It works a sprite at a time, inside that sprite's rectangle.[/b] The same guarantee
// the other three modes make, and the reason this takes the rectangles rather than being
// handed the sheet alone: a tile spanning two sprites would let the network read one while
// answering for the other, and nothing in the picture would say it had.
//
// The Vulkan instance underneath is shared with the two upscalers; see `iw_ncnn_instance.h`.

#include <godot_cpp/classes/global_constants.hpp>
#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>

#include <string>

// Forward-declared for the reason the upscalers' networks are: ncnn's net.h drags in gpu.h
// and layer.h, and nothing outside this translation unit should see them.
namespace ncnn {
class Net;
}

namespace godot {

class IWNormalNet : public RefCounted {
    GDCLASS(IWNormalNet, RefCounted)

protected:
    static void _bind_methods();

public:
    IWNormalNet();
    ~IWNormalNet();

    // What the network runs at, exactly.
    //
    // [b]Not a tile size that can be tuned.[/b] A model exported at a fixed size has the
    // sizes of its upsampling steps written into it — DeepBump's five say 16, 32, 64, 128
    // and 256 — so handing it anything else fails inside ncnn rather than merely running
    // slower. Everything smaller is padded up to this and everything larger is covered in
    // overlapping passes.
    static constexpr int TILE = 256;

    // How much neighbouring passes share, for sprites bigger than a tile.
    //
    // The seam between two passes is the one place a network's answer jumps, so the overlap
    // is faded across rather than cut. A quarter of a tile is what upstream offers as its
    // middle setting.
    static constexpr int OVERLAP = 64;

    // Whether there is a Vulkan device to run on at all.
    bool has_gpu() const;

    // Reads the model in [param model_dir]. Any `.param` with a `.bin` beside it of the
    // same name will do — the folder is the user's and nothing here knows what a model is
    // supposed to be called.
    //
    // Returns OK, or an error with [method get_last_error] set to a line worth showing.
    Error open(const String &model_dir);

    // Drops the network. Safe to call on a closed one.
    void close();

    bool is_open() const;

    // The normal map for [param sheet], or null when this is not open.
    //
    // [param rects] is x, y, w, h per sprite, the same flattening the other normal kernels
    // take. Returns a new RGBA8 image the size of the sheet, flat wherever no sprite covers
    // and carrying the sheet's own alpha throughout.
    //
    // [param green_down] writes green the DirectX way round rather than Godot's.
    Ref<Image> process(
            const Ref<Image> &sheet, const PackedInt32Array &rects, bool green_down);

    // Why the last call failed, or empty when it did not.
    String get_last_error() const;

    // Whether [param model_dir] holds a network this could open, without opening it.
    //
    // Bound because the dock asks the same question to decide whether to offer the mode at
    // all, and asking here keeps one copy of what counts as a model.
    bool has_model(const String &model_dir) const;

private:
    // The two files [param model_dir] would load, or empty strings when it holds no pair.
    static void model_files(const String &model_dir, String &r_param, String &r_bin);

    // Reads the pair into the open network. Opened as file handles rather than handed over
    // as paths, because ncnn takes a narrow string and a model folder may sit somewhere
    // that cannot be spelled in one.
    bool load_into(const String &param_path, const String &bin_path);

    // Runs one padded tile and writes its three channels into `r_total`, weighted by the
    // feather so overlapping passes can be averaged.
    bool run_tile(const float *grey, int64_t width, int64_t height, int64_t left, int64_t top,
            float fill, const float *feather, float *r_total, float *r_weight);

    ncnn::Net *net = nullptr;

    // Read off the loaded network rather than written down here, since the folder is the
    // user's and nothing says what their converter called things.
    std::string input_blob;
    std::string output_blob;

    String last_error;
};

} // namespace godot
