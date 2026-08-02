#include "iw_seg_net.h"

#include "iw_math.h"
#include "iw_ncnn_instance.h"

#include <godot_cpp/classes/dir_access.hpp>
#include <godot_cpp/variant/variant.hpp>

// ncnn. Included here and nowhere else.
#include "cpu.h"
#include "gpu.h"
#include "mat.h"
#include "net.h"

#include <cstdio>

using namespace godot;

void IWSegNet::_bind_methods() {
    ClassDB::bind_method(D_METHOD("has_gpu"), &IWSegNet::has_gpu);
    ClassDB::bind_method(D_METHOD("open", "model_dir"), &IWSegNet::open);
    ClassDB::bind_method(D_METHOD("close"), &IWSegNet::close);
    ClassDB::bind_method(D_METHOD("is_open"), &IWSegNet::is_open);
    ClassDB::bind_method(D_METHOD("segment", "source"), &IWSegNet::segment);
    ClassDB::bind_method(D_METHOD("get_last_error"), &IWSegNet::get_last_error);
    ClassDB::bind_method(D_METHOD("has_model", "model_dir"), &IWSegNet::has_model);
}

IWSegNet::IWSegNet() {}

IWSegNet::~IWSegNet() {
    close();
}

bool IWSegNet::has_gpu() const {
    return iw_ncnn::ensure_instance();
}

// Any `.param` with a `.bin` of the same name beside it.
//
// [b]Nothing here knows what a model is called.[/b] The folder is the user's, holding
// whatever their converter wrote. So the pair is what is looked for, and the first one
// found is the one used.
void IWSegNet::model_files(const String &model_dir, String &r_param, String &r_bin) {
    r_param = String();
    r_bin = String();
    if (model_dir.strip_edges().is_empty()) {
        return;
    }

    PackedStringArray names = DirAccess::get_files_at(model_dir);
    names.sort();
    for (int64_t i = 0; i < names.size(); i++) {
        const String name = names[i];
        if (name.get_extension().to_lower() != "param") {
            continue;
        }
        const String bin = name.get_basename() + ".bin";
        if (!names.has(bin)) {
            continue;
        }
        r_param = model_dir.path_join(name);
        r_bin = model_dir.path_join(bin);
        return;
    }
}

bool IWSegNet::has_model(const String &model_dir) const {
    String param;
    String bin;
    model_files(model_dir, param, bin);
    return !param.is_empty();
}

Error IWSegNet::open(const String &model_dir) {
    return open_with(model_dir, false);
}

Error IWSegNet::open_with(const String &model_dir, bool force_cpu) {
    close();
    last_error = String();

    String param_path;
    String bin_path;
    model_files(model_dir, param_path, bin_path);
    if (param_path.is_empty()) {
        last_error = model_dir.strip_edges().is_empty()
                ? String("No model folder has been named.")
                : vformat("%s holds no .param with a .bin beside it.", model_dir.get_file());
        return ERR_FILE_NOT_FOUND;
    }

    const bool on_gpu = !force_cpu && iw_ncnn::ensure_instance();
    const ncnn::VulkanDevice *device =
            on_gpu ? ncnn::get_gpu_device(ncnn::get_default_gpu_index()) : nullptr;

    net = new ncnn::Net();
    // Set before anything is read: ncnn decides how to lay the weights out as it loads
    // them, and the Vulkan path wants them laid out differently. The same options the
    // upscalers run under.
    net->opt.use_vulkan_compute = device != nullptr;
    net->opt.use_fp16_packed = true;
    net->opt.use_fp16_storage = true;
    net->opt.use_fp16_arithmetic = false;
    net->opt.use_int8_storage = true;
    net->opt.num_threads = device != nullptr ? 1 : ncnn::get_big_cpu_count();
    // Only with one in hand: ncnn reads the device's index off the pointer without
    // checking it, so handing it null to mean "no device" is a crash rather than a no.
    if (device != nullptr) {
        net->set_vulkan_device(device);
    }

    if (!load_into(param_path, bin_path)) {
        delete net;
        net = nullptr;
        last_error = vformat("%s could not be read as a network.", param_path.get_file());
        return ERR_CANT_OPEN;
    }

    const std::vector<const char *> &ins = net->input_names();
    const std::vector<const char *> &outs = net->output_names();
    if (ins.empty() || outs.empty()) {
        delete net;
        net = nullptr;
        last_error = vformat("%s names no input or no output.", param_path.get_file());
        return ERR_INVALID_DATA;
    }
    input_blob = ins.front();
    // The conversion recipe prunes the model to exactly one output before converting,
    // and that is load-bearing: pnnx numbers outputs by graph topology, not by the order
    // the ONNX declared them, so on a multi-head export front() lands on whichever head
    // the graph reaches first — measured as a quarter-resolution one, which fails the
    // shape check below. One output in the file makes front() the only answer there is.
    output_blob = outs.front();

    open_dir = model_dir;
    iw_ncnn::retain();
    return OK;
}

bool IWSegNet::load_into(const String &param_path, const String &bin_path) {
#ifdef _WIN32
    FILE *param_file = _wfopen(
            std::wstring(param_path.wide_string().get_data()).c_str(), L"rb");
    FILE *bin_file = _wfopen(std::wstring(bin_path.wide_string().get_data()).c_str(), L"rb");
#else
    FILE *param_file = fopen(param_path.utf8().get_data(), "rb");
    FILE *bin_file = fopen(bin_path.utf8().get_data(), "rb");
#endif
    bool ok = param_file != nullptr && bin_file != nullptr;
    if (ok) {
        ok = net->load_param(param_file) == 0 && net->load_model(bin_file) == 0;
    }
    if (param_file != nullptr) {
        fclose(param_file);
    }
    if (bin_file != nullptr) {
        fclose(bin_file);
    }
    return ok;
}

void IWSegNet::close() {
    if (net == nullptr) {
        return;
    }
    delete net;
    net = nullptr;
    input_blob.clear();
    output_blob.clear();
    open_dir = String();
    iw_ncnn::release();
}

bool IWSegNet::is_open() const {
    return net != nullptr;
}

String IWSegNet::get_last_error() const {
    return last_error;
}

Ref<Image> IWSegNet::segment(const Ref<Image> &source) {
    last_error = String();
    if (net == nullptr) {
        last_error = "The network is not open.";
        return Ref<Image>();
    }
    ERR_FAIL_COND_V(source.is_null(), Ref<Image>());
    if (source->is_empty()) {
        return Ref<Image>();
    }

    Ref<Image> rgba = source;
    if (rgba->get_format() != Image::FORMAT_RGBA8) {
        rgba = rgba->duplicate();
        rgba->convert(Image::FORMAT_RGBA8);
    }
    const int64_t w0 = rgba->get_width();
    const int64_t h0 = rgba->get_height();

    // The letterbox, exactly as upstream's inference does it: longest side flush against
    // SIZE, the other scaled to match and truncated, the rest centred padding. Truncation
    // and the floor split are upstream's — matching them is what makes the parity check
    // meaningful.
    int64_t content_w = SIZE;
    int64_t content_h = SIZE;
    if (h0 > w0) {
        content_w = iw::maxi((SIZE * w0) / h0, 1);
    } else {
        content_h = iw::maxi((SIZE * h0) / w0, 1);
    }
    const int pad_top = static_cast<int>((SIZE - content_h) / 2);
    const int pad_left = static_cast<int>((SIZE - content_w) / 2);

    const PackedByteArray pixels = rgba->get_data();
    ncnn::Mat scaled = ncnn::Mat::from_pixels_resize(pixels.ptr(),
            ncnn::Mat::PIXEL_RGBA2RGB, static_cast<int>(w0), static_cast<int>(h0),
            static_cast<int>(content_w), static_cast<int>(content_h));
    if (scaled.empty()) {
        last_error = "The image could not be prepared for the network.";
        return Ref<Image>();
    }

    ncnn::Mat padded;
    ncnn::copy_make_border(scaled, padded, pad_top,
            SIZE - static_cast<int>(content_h) - pad_top, pad_left,
            SIZE - static_cast<int>(content_w) - pad_left, ncnn::BORDER_CONSTANT, 0.0f);
    if (padded.empty()) {
        last_error = "The image could not be prepared for the network.";
        return Ref<Image>();
    }
    // Upstream divides by 255 and subtracts no mean. Applied after the padding, which
    // changes nothing — zero scales to zero — and keeps the border constant literal.
    const float norm[3] = { 1.0f / 255.0f, 1.0f / 255.0f, 1.0f / 255.0f };
    padded.substract_mean_normalize(nullptr, norm);

    // One pass, retried once on the CPU. This network is far heavier than the others —
    // 320 GFLOPs against DeepBump's few — so a card that upscales happily can still run
    // out of memory here, and ncnn reports that as a failed extract rather than anything
    // more specific.
    ncnn::Mat out;
    for (int attempt = 0; attempt < 2; attempt++) {
        ncnn::Extractor ex = net->create_extractor();
        if (ex.input(input_blob.c_str(), padded) == 0 &&
                ex.extract(output_blob.c_str(), out) == 0) {
            break;
        }
        out = ncnn::Mat();
        if (attempt == 0 && net->opt.use_vulkan_compute) {
            if (open_with(open_dir, true) != OK) {
                return Ref<Image>();
            }
            continue;
        }
        last_error = "The network could not run. The GPU may be out of memory.";
        return Ref<Image>();
    }
    if (out.empty() || out.w != SIZE || out.h != SIZE || out.c < 1) {
        last_error = "The network answered with the wrong shape.";
        return Ref<Image>();
    }

    // The content region only, so the caller can lay this straight over the source with
    // a plain resize. L8 rather than floats: a byte per pixel is what the stage caches,
    // and the matte maths downstream never needed more than the classification threshold
    // anyway.
    PackedByteArray bytes;
    bytes.resize(content_w * content_h);
    uint8_t *dst = bytes.ptrw();
    const float *answer = out.channel(0);
    for (int64_t y = 0; y < content_h; y++) {
        const float *row = answer + (pad_top + y) * SIZE + pad_left;
        for (int64_t x = 0; x < content_w; x++) {
            dst[y * content_w + x] = static_cast<uint8_t>(
                    iw::roundi(iw::clampf(iw::widen(row[x]), 0.0, 1.0) * 255.0));
        }
    }
    return Image::create_from_data(content_w, content_h, false, Image::FORMAT_L8, bytes);
}
