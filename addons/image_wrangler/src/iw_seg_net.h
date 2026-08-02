#pragma once

// A trained segmentation network, wrapped for the Neural Remove Background stage.
//
// The fourth class here built on ncnn, and shaped like [IWNormalNet] on purpose — open a
// folder, hold it across a run, close it. It differs in what it answers: the others give
// back pixels, where this gives back a per-pixel probability that the pixel is subject,
// and the stage turns that into a matte with the same machinery Remove Background uses.
//
// [b]No model ships with this addon.[/b] Nothing here names a network, downloads one or
// carries weights — the folder is the user's, and the class stands down when it holds
// nothing loadable. That is what keeps the addon's own licence clear of whatever the model
// was trained and released under.
//
// [b]No tiling, deliberately.[/b] The normal net covers a big sprite in overlapping passes
// because a normal is local. Saliency is not: a network deciding what is subject needs the
// whole picture, and a tile of it answers a different question. So the image is letterboxed
// into the network's fixed size whole, and the answer comes back at that resolution.
//
// The Vulkan instance underneath is shared with the upscalers; see `iw_ncnn_instance.h`.

#include <godot_cpp/classes/global_constants.hpp>
#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>

#include <string>

// Forward-declared for the reason the upscalers' networks are: ncnn's net.h drags in gpu.h
// and layer.h, and nothing outside this translation unit should see them.
namespace ncnn {
class Net;
}

namespace godot {

class IWSegNet : public RefCounted {
    GDCLASS(IWSegNet, RefCounted)

protected:
    static void _bind_methods();

public:
    IWSegNet();
    ~IWSegNet();

    // What the network runs at, exactly.
    //
    // [b]Not a size that can be tuned.[/b] The model is exported with its shapes frozen at
    // this, so handing it anything else fails inside ncnn rather than merely running
    // slower. Every image is fitted into this square, longest side flush, the rest padding.
    static constexpr int SIZE = 1024;

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

    // The probability that each pixel is subject, or null on failure.
    //
    // Returns an L8 image at the size the content occupies inside the letterbox — the
    // padding is cropped off here, so what comes back scales onto the source with a plain
    // resize. 255 is certainly subject, 0 certainly background.
    //
    // A failure on the GPU is retried once on the CPU before giving up, because this
    // network is far heavier than the others and a card that upscales happily can still
    // refuse it.
    Ref<Image> segment(const Ref<Image> &source);

    // Why the last call failed, or empty when it did not.
    String get_last_error() const;

    // Whether [param model_dir] holds a network this could open, without opening it.
    bool has_model(const String &model_dir) const;

private:
    // The two files [param model_dir] would load, or empty strings when it holds no pair.
    static void model_files(const String &model_dir, String &r_param, String &r_bin);

    // Reads the pair into the open network. Opened as file handles rather than handed over
    // as paths, because ncnn takes a narrow string and a model folder may sit somewhere
    // that cannot be spelled in one.
    bool load_into(const String &param_path, const String &bin_path);

    Error open_with(const String &model_dir, bool force_cpu);

    ncnn::Net *net = nullptr;

    // Where the open model came from, kept so the CPU retry can reopen it.
    String open_dir;

    // Read off the loaded network rather than written down here, since the folder is the
    // user's and nothing says what their converter called things.
    std::string input_blob;
    std::string output_blob;

    String last_error;
};

} // namespace godot
