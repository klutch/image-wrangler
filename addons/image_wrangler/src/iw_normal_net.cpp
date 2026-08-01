#include "iw_normal_net.h"

#include "iw_islands.h"
#include "iw_math.h"
#include "iw_ncnn_instance.h"
#include "iw_normal_shared.h"

#include <godot_cpp/classes/dir_access.hpp>
#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/variant/variant.hpp>

// ncnn. Included here and nowhere else.
#include "cpu.h"
#include "gpu.h"
#include "net.h"

#include <cmath>
#include <cstdio>
#include <vector>

using namespace godot;

namespace {

// 1 across the middle, easing to 0 over `edge` pixels at each end.
//
// Only the ends matter: a sprite small enough to fit one pass is covered by the middle,
// where this is flat, so padding a small sprite costs it nothing.
std::vector<float> feather_window(int size, int edge) {
    std::vector<float> ramp(static_cast<size_t>(size), 1.0f);
    if (edge <= 0 || edge * 2 >= size) {
        return ramp;
    }
    for (int i = 0; i < edge; i++) {
        const float along = static_cast<float>(i + 1) / static_cast<float>(edge + 1);
        ramp[static_cast<size_t>(i)] = along;
        ramp[static_cast<size_t>(size - 1 - i)] = along;
    }
    return ramp;
}

// Where the passes start along one side, so that every pixel is covered and the last pass
// ends flush with the edge.
std::vector<int64_t> pass_starts(int64_t length, int64_t tile, int64_t overlap) {
    std::vector<int64_t> starts;
    if (length <= tile) {
        starts.push_back(0);
        return starts;
    }
    const int64_t step = iw::maxi(tile - overlap, 1);
    for (int64_t at = 0; at < length - tile; at += step) {
        starts.push_back(at);
    }
    starts.push_back(length - tile);
    return starts;
}

} // namespace

void IWNormalNet::_bind_methods() {
    ClassDB::bind_method(D_METHOD("has_gpu"), &IWNormalNet::has_gpu);
    ClassDB::bind_method(D_METHOD("open", "model_dir"), &IWNormalNet::open);
    ClassDB::bind_method(D_METHOD("close"), &IWNormalNet::close);
    ClassDB::bind_method(D_METHOD("is_open"), &IWNormalNet::is_open);
    ClassDB::bind_method(D_METHOD("process", "sheet", "rects", "green_down"),
            &IWNormalNet::process);
    ClassDB::bind_method(D_METHOD("get_last_error"), &IWNormalNet::get_last_error);
    ClassDB::bind_method(D_METHOD("has_model", "model_dir"), &IWNormalNet::has_model);
}

IWNormalNet::IWNormalNet() {}

IWNormalNet::~IWNormalNet() {
    close();
}

bool IWNormalNet::has_gpu() const {
    return iw_ncnn::ensure_instance();
}

// Any `.param` with a `.bin` of the same name beside it.
//
// [b]Nothing here knows what a model is called.[/b] The upscalers can insist on a naming
// shape because their folders come from upstream; this folder is the user's, holding
// whatever their converter wrote. So the pair is what is looked for, and the first one
// found is the one used.
void IWNormalNet::model_files(const String &model_dir, String &r_param, String &r_bin) {
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

bool IWNormalNet::has_model(const String &model_dir) const {
    String param;
    String bin;
    model_files(model_dir, param, bin);
    return !param.is_empty();
}

Error IWNormalNet::open(const String &model_dir) {
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

    const bool on_gpu = iw_ncnn::ensure_instance();
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

    // Opened here rather than handed over as a path, because ncnn takes a narrow string and
    // a model folder may sit somewhere that cannot be spelled in one.
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
    output_blob = outs.back();

    iw_ncnn::retain();
    return OK;
}

bool IWNormalNet::load_into(const String &param_path, const String &bin_path) {
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

void IWNormalNet::close() {
    if (net == nullptr) {
        return;
    }
    delete net;
    net = nullptr;
    input_blob.clear();
    output_blob.clear();
    iw_ncnn::release();
}

bool IWNormalNet::is_open() const {
    return net != nullptr;
}

String IWNormalNet::get_last_error() const {
    return last_error;
}

bool IWNormalNet::run_tile(const float *grey, int64_t width, int64_t height, int64_t left,
        int64_t top, float fill, const float *feather, float *r_total, float *r_weight) {
    ncnn::Mat in(TILE, TILE, 1, static_cast<size_t>(4));
    if (in.empty()) {
        return false;
    }
    float *field = in;
    for (int64_t y = 0; y < TILE; y++) {
        const int64_t from_y = top + y;
        float *row = field + y * TILE;
        for (int64_t x = 0; x < TILE; x++) {
            const int64_t from_x = left + x;
            row[x] = (from_y < height && from_x < width)
                    ? grey[from_y * width + from_x]
                    : fill;
        }
    }

    ncnn::Extractor ex = net->create_extractor();
    if (ex.input(input_blob.c_str(), in) != 0) {
        return false;
    }
    ncnn::Mat got;
    if (ex.extract(output_blob.c_str(), got) != 0) {
        return false;
    }
    if (got.w != TILE || got.h != TILE || got.c < 3) {
        return false;
    }

    const int64_t plane = width * height;
    for (int channel = 0; channel < 3; channel++) {
        const float *answer = got.channel(channel);
        for (int64_t y = 0; y < TILE; y++) {
            const int64_t into_y = top + y;
            if (into_y >= height) {
                break;
            }
            for (int64_t x = 0; x < TILE; x++) {
                const int64_t into_x = left + x;
                if (into_x >= width) {
                    break;
                }
                const float share = feather[y] * feather[x];
                const int64_t at = into_y * width + into_x;
                r_total[channel * plane + at] += answer[y * TILE + x] * share;
                if (channel == 0) {
                    r_weight[at] += share;
                }
            }
        }
    }
    return true;
}

Ref<Image> IWNormalNet::process(
        const Ref<Image> &sheet, const PackedInt32Array &rects, bool green_down) {
    last_error = String();
    if (net == nullptr) {
        last_error = "The network is not open.";
        return Ref<Image>();
    }
    ERR_FAIL_COND_V(sheet.is_null(), Ref<Image>());
    if (sheet->is_empty() || rects.is_empty()) {
        return Ref<Image>();
    }

    const int64_t width = sheet->get_width();
    const int64_t height = sheet->get_height();
    const PackedByteArray pixels = iw::sheet_bytes(sheet);
    const uint8_t *src = pixels.ptr();
    PackedByteArray out = iw::blank_normal(src, width * height);
    uint8_t *dst = out.ptrw();

    const std::vector<float> feather = feather_window(TILE, OVERLAP);
    const int32_t *rect_ptr = rects.ptr();

    for (int64_t n = 0; n + 3 < rects.size(); n += 4) {
        int64_t rx = 0;
        int64_t ry = 0;
        int64_t rw = 0;
        int64_t rh = 0;
        if (!iw::rect_at(rect_ptr, n, width, height, rx, ry, rw, rh)) {
            continue;
        }

        // How light and dark the sprite is, which is all the network reads.
        std::vector<float> grey(static_cast<size_t>(rw * rh), 0.0f);
        double total = 0.0;
        int64_t counted = 0;
        for (int64_t y = 0; y < rh; y++) {
            const int64_t row = (ry + y) * width + rx;
            for (int64_t x = 0; x < rw; x++) {
                const uint8_t *here = src + (row + x) * 4;
                const double level = (here[0] + here[1] + here[2]) / 3.0 / 255.0;
                grey[static_cast<size_t>(y * rw + x)] = iw::narrow(level);
                if (here[3] / 255.0 >= iw::SOLID_ALPHA) {
                    total += level;
                    counted++;
                }
            }
        }
        if (counted == 0) {
            continue;
        }

        // [b]Everything outside the sprite is filled with the sprite's own average, and so
        // is the padding round it.[/b] A clear pixel carries near-black colour under its
        // zero alpha, and left that way the network reads every silhouette as a cliff and
        // rings the sprite in a hard rim. Measurably worse; this is what fixes it.
        const float fill = iw::narrow(total / static_cast<double>(counted));
        for (int64_t y = 0; y < rh; y++) {
            const int64_t row = (ry + y) * width + rx;
            for (int64_t x = 0; x < rw; x++) {
                if (src[(row + x) * 4 + 3] / 255.0 < iw::SOLID_ALPHA) {
                    grey[static_cast<size_t>(y * rw + x)] = fill;
                }
            }
        }

        std::vector<float> answer(static_cast<size_t>(rw * rh * 3), 0.0f);
        std::vector<float> weight(static_cast<size_t>(rw * rh), 0.0f);
        bool ran = true;
        for (const int64_t top : pass_starts(rh, TILE, OVERLAP)) {
            for (const int64_t left : pass_starts(rw, TILE, OVERLAP)) {
                if (!run_tile(grey.data(), rw, rh, left, top, fill, feather.data(),
                            answer.data(), weight.data())) {
                    ran = false;
                    break;
                }
            }
            if (!ran) {
                break;
            }
        }
        if (!ran) {
            last_error = "The network could not run. The GPU may be out of memory.";
            return Ref<Image>();
        }

        const int64_t plane = rw * rh;
        for (int64_t y = 0; y < rh; y++) {
            const int64_t row = (ry + y) * width + rx;
            for (int64_t x = 0; x < rw; x++) {
                if (src[(row + x) * 4 + 3] == 0) {
                    continue;
                }
                const int64_t at = y * rw + x;
                const double share = iw::maxf(iw::widen(weight[static_cast<size_t>(at)]), 1e-6);
                // The network answers in 0 to 1 through a sigmoid, so this is the normal
                // already mapped rather than a raw direction. Unpacked, made unit length —
                // the averaging across a seam shortens it — and packed again.
                double v[3];
                for (int channel = 0; channel < 3; channel++) {
                    const double got = iw::widen(
                            answer[static_cast<size_t>(channel * plane + at)]) / share;
                    v[channel] = got * 2.0 - 1.0;
                }
                if (green_down) {
                    v[1] = -v[1];
                }
                const double length = iw::maxf(
                        std::sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]), 1e-6);
                uint8_t *into = dst + (row + x) * 4;
                for (int channel = 0; channel < 3; channel++) {
                    const double mapped = v[channel] / length * 0.5 + 0.5;
                    into[channel] = static_cast<uint8_t>(
                            iw::roundi(iw::clampf(mapped, 0.0, 1.0) * 255.0));
                }
            }
        }
    }

    return Image::create_from_data(width, height, false, Image::FORMAT_RGBA8, out);
}
