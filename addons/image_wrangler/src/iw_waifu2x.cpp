#include "iw_waifu2x.h"

#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/variant/variant.hpp>

// ncnn, and the upstream class built on it. Included here and nowhere else.
#include "cpu.h"
#include "gpu.h"
#include "waifu2x.h"

#include <cstring>
#include <string>

using namespace godot;

namespace {

// The three model directories upstream ships, and the only ones it knows the padding for.
//
// [b]Matched on the name, which is upstream's own test and not a good one.[/b] The padding
// is a property of the network's receptive field: get it wrong and every tile boundary
// comes back with a seam, and nothing about the .param file says what the right number is.
// So an unfamiliar directory is refused rather than guessed at — see prepadding_for.
constexpr const char *MODEL_CUNET = "models-cunet";
constexpr const char *MODEL_UPCONV_ANIME = "models-upconv_7_anime_style_art_rgb";
constexpr const char *MODEL_UPCONV_PHOTO = "models-upconv_7_photo";

// Free video memory, in MB, above which each tile size is worth using. Upstream's ladder,
// kept as a table because the two model families want different rungs.
struct TileLadder {
    uint32_t budget;
    int size;
};

constexpr TileLadder CUNET_TILES[] = {{2600, 400}, {740, 200}, {250, 100}, {0, 32}};
constexpr TileLadder UPCONV_TILES[] = {{1900, 400}, {550, 200}, {190, 100}, {0, 32}};

// Whether the Vulkan instance has been asked for, and whether it came.
//
// Process-wide because ncnn's is: create_gpu_instance enumerates the physical devices once
// and every VulkanDevice handed out afterwards points into that enumeration.
bool s_instance_tried = false;
bool s_instance_ok = false;

// How many upscalers are open. The instance must outlive every one of them.
int s_open_count = 0;

// Whether [param model_dir] ends in [param name], which is how upstream tells its three
// model directories apart.
bool model_is(const String &model_dir, const char *name) {
    return model_dir.get_file() == String(name);
}

// The model files for a given noise level and ratio, as upstream names them.
//
// Only three shapes exist. No denoising is a model of its own rather than a strength of
// zero; a ratio of 1 is a denoise-only model; everything else is the 2x model, run more
// than once for the larger ratios.
void model_files(int64_t noise, int64_t scale, String &r_param, String &r_bin) {
    if (noise == IWWaifu2x::NOISE_NONE) {
        r_param = "scale2.0x_model.param";
        r_bin = "scale2.0x_model.bin";
    } else if (scale == 1) {
        r_param = vformat("noise%d_model.param", noise);
        r_bin = vformat("noise%d_model.bin", noise);
    } else {
        r_param = vformat("noise%d_scale2.0x_model.param", noise);
        r_bin = vformat("noise%d_scale2.0x_model.bin", noise);
    }
}

// How many times the 2x network runs to reach [param scale]. Zero for a ratio of 1, which
// is the denoise-only case and does not resize at all.
int scale_run_count(int64_t scale) {
    switch (scale) {
        case 2: return 1;
        case 4: return 2;
        case 8: return 3;
        case 16: return 4;
        case 32: return 5;
        default: return 0;
    }
}

} // namespace

void IWWaifu2x::_bind_methods() {
    ClassDB::bind_method(D_METHOD("has_gpu"), &IWWaifu2x::has_gpu);
    ClassDB::bind_method(D_METHOD("open", "model_dir", "noise", "scale", "tta"), &IWWaifu2x::open);
    ClassDB::bind_method(D_METHOD("close"), &IWWaifu2x::close);
    ClassDB::bind_method(D_METHOD("is_open"), &IWWaifu2x::is_open);
    ClassDB::bind_method(D_METHOD("process", "source"), &IWWaifu2x::process);
    ClassDB::bind_method(D_METHOD("get_last_error"), &IWWaifu2x::get_last_error);
}

IWWaifu2x::IWWaifu2x() {}

IWWaifu2x::~IWWaifu2x() {
    close();
}

bool IWWaifu2x::ensure_gpu_instance() {
    if (s_instance_tried) {
        return s_instance_ok;
    }
    s_instance_tried = true;
    // Zero is ncnn's success. A machine with no Vulkan driver reports the failure on
    // stderr itself, which is why nothing is pushed here — the caller turns this into a
    // line on the dock instead.
    s_instance_ok = ncnn::create_gpu_instance() == 0 && ncnn::get_gpu_count() > 0;
    return s_instance_ok;
}

void IWWaifu2x::shutdown() {
    // See the header: freeing the instance out from under a live device is a crash, and
    // the process is ending anyway.
    if (s_instance_ok && s_open_count == 0) {
        ncnn::destroy_gpu_instance();
        s_instance_ok = false;
        s_instance_tried = false;
    }
}

bool IWWaifu2x::has_gpu() const {
    return ensure_gpu_instance();
}

bool IWWaifu2x::is_supported_scale(int64_t scale) {
    return scale == 1 || scale_run_count(scale) > 0;
}

int IWWaifu2x::prepadding_for(const String &model_dir, int64_t noise, int64_t scale) {
    if (model_is(model_dir, MODEL_CUNET)) {
        // The denoise-only model sees further than the others, so its tiles need more
        // context around them. Upstream's numbers, and not ones to derive.
        if (noise != NOISE_NONE && scale == 1) {
            return 28;
        }
        return 18;
    }
    if (model_is(model_dir, MODEL_UPCONV_ANIME) || model_is(model_dir, MODEL_UPCONV_PHOTO)) {
        return 7;
    }
    // Refused rather than guessed. A wrong padding does not fail — it returns an image
    // with a seam at every tile boundary, which is the worst way for this to go wrong
    // because it looks like the network is simply bad.
    return -1;
}

int IWWaifu2x::tile_size_for(const String &model_dir) {
    if (!s_instance_ok) {
        // The CPU path has no video memory to budget against, and upstream fixes it here.
        return 400;
    }

    ncnn::VulkanDevice *device = ncnn::get_gpu_device();
    if (device == nullptr) {
        return 400;
    }
    const uint32_t budget = device->get_heap_budget();

    const TileLadder *ladder = model_is(model_dir, MODEL_CUNET) ? CUNET_TILES : UPCONV_TILES;
    for (int i = 0;; ++i) {
        if (budget > ladder[i].budget || ladder[i].budget == 0) {
            return ladder[i].size;
        }
    }
}

Error IWWaifu2x::open(const String &model_dir, int64_t noise, int64_t scale, bool tta) {
    close();
    last_error = String();

    if (noise < NOISE_MIN || noise > NOISE_MAX) {
        last_error = vformat("Denoise level %d is not one this model understands.", noise);
        return ERR_INVALID_PARAMETER;
    }
    if (!is_supported_scale(scale)) {
        last_error = vformat("Scale %dx is not one waifu2x can do.", scale);
        return ERR_INVALID_PARAMETER;
    }

    const int prepadding = prepadding_for(model_dir, noise, scale);
    if (prepadding < 0) {
        last_error = vformat(
                "%s is not a model folder waifu2x recognises. It knows %s, %s and %s.",
                model_dir.get_file(), MODEL_CUNET, MODEL_UPCONV_ANIME, MODEL_UPCONV_PHOTO);
        return ERR_FILE_UNRECOGNIZED;
    }

    String param_name;
    String bin_name;
    model_files(noise, scale, param_name, bin_name);
    const String param_path = model_dir.path_join(param_name);
    const String bin_path = model_dir.path_join(bin_name);

    // [b]Checked here because upstream does not check at all.[/b] Its loader prints a line
    // to stderr for a file it could not open and then hands the null file handle to ncnn,
    // which reads through it. A missing model has to stop before it gets that far.
    if (!FileAccess::file_exists(param_path) || !FileAccess::file_exists(bin_path)) {
        last_error = vformat("%s has no %s to load.", model_dir.get_file(), param_name);
        return ERR_FILE_NOT_FOUND;
    }

    const bool on_gpu = ensure_gpu_instance();
    const int gpu_id = on_gpu ? ncnn::get_default_gpu_index() : -1;

    // Constructed only now, and only because everything above passed. Upstream's
    // destructor unconditionally dereferences a pipeline that its loader is what creates,
    // so an instance that never got as far as loading cannot be destroyed — the one
    // arrangement this class has to keep out of.
    worker = new Waifu2x(gpu_id, tta, on_gpu ? 1 : ncnn::get_big_cpu_count());
    worker->noise = static_cast<int>(noise);
    // The network only ever does 1x or 2x. Everything above 2 is that same 2x model run
    // again on its own output; see process.
    worker->scale = scale >= 2 ? 2 : 1;
    worker->prepadding = prepadding;
    worker->tilesize = tile_size_for(model_dir);

#ifdef _WIN32
    // ncnn reads the model with _wfopen on Windows, so the path has to survive being one
    // — a project under a folder with a non-ASCII name would otherwise fail to load with
    // nothing on screen to say why.
    worker->load(std::wstring(param_path.wide_string().get_data()),
            std::wstring(bin_path.wide_string().get_data()));
#else
    worker->load(std::string(param_path.utf8().get_data()),
            std::string(bin_path.utf8().get_data()));
#endif

    scale_factor = static_cast<int>(scale);
    s_open_count += 1;
    return OK;
}

void IWWaifu2x::close() {
    if (worker == nullptr) {
        return;
    }
    delete worker;
    worker = nullptr;
    s_open_count -= 1;
}

bool IWWaifu2x::is_open() const {
    return worker != nullptr;
}

String IWWaifu2x::get_last_error() const {
    return last_error;
}

Ref<Image> IWWaifu2x::process(const Ref<Image> &source) {
    last_error = String();
    if (worker == nullptr) {
        last_error = "The upscaler is not open.";
        return Ref<Image>();
    }
    if (source.is_null() || source->is_empty()) {
        last_error = "There is no image to upscale.";
        return Ref<Image>();
    }

    const int width = source->get_width();
    const int height = source->get_height();

    // RGBA8 throughout, which is what the rest of this addon works in and what lets the
    // alpha ride along. Converted through a copy rather than in place: the image handed in
    // is very likely the one on the preview.
    PackedByteArray pixels = source->get_data();
    if (source->get_format() != Image::FORMAT_RGBA8) {
        Ref<Image> converted = Image::create_from_data(
                width, height, false, source->get_format(), pixels);
        converted->convert(Image::FORMAT_RGBA8);
        pixels = converted->get_data();
    }

    // Wrapped rather than copied. An ncnn::Mat built on a pointer it was handed does not
    // own it and will not free it, so the only requirement is that `pixels` outlive the
    // call — which it does.
    ncnn::Mat in_mat(width, height, const_cast<uint8_t *>(pixels.ptr()), (size_t)4, 4);

    const int runs = scale_run_count(scale_factor);
    if (runs == 0) {
        // A ratio of 1: denoise in place, at the size it came in.
        ncnn::Mat out_mat(width, height, (size_t)4, 4);
        if (worker->process(in_mat, out_mat) != 0) {
            last_error = "waifu2x could not run. The GPU may be out of memory.";
            return Ref<Image>();
        }
        PackedByteArray out;
        out.resize(static_cast<int64_t>(width) * height * 4);
        memcpy(out.ptrw(), out_mat.data, out.size());
        return Image::create_from_data(width, height, false, Image::FORMAT_RGBA8, out);
    }

    // Doubled a run at a time, because there is no 4x model — 32x is the 2x network five
    // times over. The denoising is in the model, so it happens on the first pass and every
    // pass after it is a plain 2x of an already-clean picture, which is upstream's own
    // arrangement.
    ncnn::Mat out_mat(width * 2, height * 2, (size_t)4, 4);
    if (worker->process(in_mat, out_mat) != 0) {
        last_error = "waifu2x could not run. The GPU may be out of memory.";
        return Ref<Image>();
    }
    for (int i = 1; i < runs; ++i) {
        ncnn::Mat previous = out_mat;
        out_mat = ncnn::Mat(previous.w * 2, previous.h * 2, (size_t)4, 4);
        if (worker->process(previous, out_mat) != 0) {
            last_error = vformat(
                    "waifu2x ran out of room at %dx. Try a smaller scale.", 1 << (i + 1));
            return Ref<Image>();
        }
    }

    PackedByteArray out;
    out.resize(static_cast<int64_t>(out_mat.w) * out_mat.h * 4);
    memcpy(out.ptrw(), out_mat.data, out.size());
    return Image::create_from_data(out_mat.w, out_mat.h, false, Image::FORMAT_RGBA8, out);
}
