#include "iw_realesrgan.h"

#include "iw_ncnn_instance.h"

#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/variant/variant.hpp>

// ncnn, and the class built on it. Included here and nowhere else.
#include "cpu.h"
#include "gpu.h"
#include "realesrgan.h"

#include <cstring>
#include <string>

using namespace godot;

namespace {

// Free video memory, in MB, above which each tile size is worth using. Upstream's ladder,
// and a lower one than waifu2x's — these networks are deeper and a tile costs more.
struct TileLadder {
    uint32_t budget;
    int size;
};

constexpr TileLadder TILES[] = {{1900, 200}, {550, 100}, {190, 64}, {0, 32}};

} // namespace

void IWRealESRGAN::_bind_methods() {
    ClassDB::bind_method(D_METHOD("has_gpu"), &IWRealESRGAN::has_gpu);
    ClassDB::bind_method(D_METHOD("open", "model_dir", "scale", "tta"), &IWRealESRGAN::open);
    ClassDB::bind_method(D_METHOD("close"), &IWRealESRGAN::close);
    ClassDB::bind_method(D_METHOD("is_open"), &IWRealESRGAN::is_open);
    ClassDB::bind_method(D_METHOD("process", "source"), &IWRealESRGAN::process);
    ClassDB::bind_method(D_METHOD("get_last_error"), &IWRealESRGAN::get_last_error);
    ClassDB::bind_method(D_METHOD("supported_scales", "model_dir"), &IWRealESRGAN::supported_scales);
}

IWRealESRGAN::IWRealESRGAN() {}

IWRealESRGAN::~IWRealESRGAN() {
    close();
}

bool IWRealESRGAN::has_gpu() const {
    return iw_ncnn::ensure_instance();
}

// Two naming shapes, which are upstream's own.
//
// [b]A folder that ships several ratios puts the ratio in the file name[/b] —
// `realesr-animevideov3/realesr-animevideov3-x2.param` and its x3 and x4 neighbours. A
// folder that only knows one ratio does not, and names the file after itself:
// `realesrgan-x4plus/realesrgan-x4plus.param`.
//
// The second shape has nothing in it saying what that one ratio is, so the folder name is
// what gets read — and every model of this kind is called something-x4-something. A folder
// whose name does not carry the ratio being asked for is refused rather than guessed at,
// because the failure is not a graceful one: the network would run at its own ratio into a
// buffer sized for a different one.
void IWRealESRGAN::model_files(const String &model_dir, int64_t scale, String &r_param, String &r_bin) {
    r_param = String();
    r_bin = String();

    const String name = model_dir.get_file();

    const String scaled_param = model_dir.path_join(vformat("%s-x%d.param", name, scale));
    const String scaled_bin = model_dir.path_join(vformat("%s-x%d.bin", name, scale));
    if (FileAccess::file_exists(scaled_param) && FileAccess::file_exists(scaled_bin)) {
        r_param = scaled_param;
        r_bin = scaled_bin;
        return;
    }

    if (!name.contains(vformat("x%d", scale))) {
        return;
    }
    const String plain_param = model_dir.path_join(vformat("%s.param", name));
    const String plain_bin = model_dir.path_join(vformat("%s.bin", name));
    if (FileAccess::file_exists(plain_param) && FileAccess::file_exists(plain_bin)) {
        r_param = plain_param;
        r_bin = plain_bin;
    }
}

PackedInt32Array IWRealESRGAN::supported_scales(const String &model_dir) const {
    PackedInt32Array out;
    for (int64_t scale = SCALE_MIN; scale <= SCALE_MAX; ++scale) {
        String param;
        String bin;
        model_files(model_dir, scale, param, bin);
        if (!param.is_empty()) {
            out.append(static_cast<int32_t>(scale));
        }
    }
    return out;
}

int IWRealESRGAN::tile_size() {
    if (!iw_ncnn::ensure_instance()) {
        // The CPU path has no video memory to budget against, and upstream fixes it here.
        return 200;
    }

    ncnn::VulkanDevice *device = ncnn::get_gpu_device();
    if (device == nullptr) {
        return 200;
    }
    const uint32_t budget = device->get_heap_budget();

    for (int i = 0;; ++i) {
        if (budget > TILES[i].budget || TILES[i].budget == 0) {
            return TILES[i].size;
        }
    }
}

Error IWRealESRGAN::open(const String &model_dir, int64_t scale, bool tta) {
    close();
    last_error = String();

    if (scale < SCALE_MIN || scale > SCALE_MAX) {
        last_error = vformat("Scale %dx is not one Real-ESRGAN can do.", scale);
        return ERR_INVALID_PARAMETER;
    }

    String param_path;
    String bin_path;
    model_files(model_dir, scale, param_path, bin_path);
    if (param_path.is_empty()) {
        last_error = vformat(
                "%s has no %dx network to load.", model_dir.get_file(), scale);
        return ERR_FILE_NOT_FOUND;
    }

    const bool on_gpu = iw_ncnn::ensure_instance();
    const int gpu_id = on_gpu ? ncnn::get_default_gpu_index() : -1;

    worker = new RealESRGAN(gpu_id, tta, on_gpu ? 1 : ncnn::get_big_cpu_count());
    worker->scale = static_cast<int>(scale);
    // [b]One number for every model here, where waifu2x has three.[/b] Its padding depends
    // on the model because its networks differ in how far they see; all of these were
    // exported the same way and upstream pads every one of them by ten. A folder somebody
    // dropped in themselves gets the same ten, which is the only answer available and is
    // upstream's own for anything in its models directory.
    worker->prepadding = PREPADDING;
    worker->tilesize = tile_size();

#ifdef _WIN32
    // ncnn reads the model with _wfopen on Windows, so the path has to survive being one.
    const int loaded = worker->load(std::wstring(param_path.wide_string().get_data()),
            std::wstring(bin_path.wide_string().get_data()));
#else
    const int loaded = worker->load(std::string(param_path.utf8().get_data()),
            std::string(bin_path.utf8().get_data()));
#endif
    if (loaded != 0) {
        delete worker;
        worker = nullptr;
        last_error = vformat("%s could not be read.", param_path.get_file());
        return ERR_CANT_OPEN;
    }

    scale_factor = static_cast<int>(scale);
    iw_ncnn::retain();
    return OK;
}

void IWRealESRGAN::close() {
    if (worker == nullptr) {
        return;
    }
    delete worker;
    worker = nullptr;
    iw_ncnn::release();
}

bool IWRealESRGAN::is_open() const {
    return worker != nullptr;
}

String IWRealESRGAN::get_last_error() const {
    return last_error;
}

Ref<Image> IWRealESRGAN::process(const Ref<Image> &source) {
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

    // RGBA8 throughout, as in IWWaifu2x and for the same reasons — it is what the rest of
    // this addon works in, and it is what lets the alpha ride along.
    PackedByteArray pixels = source->get_data();
    if (source->get_format() != Image::FORMAT_RGBA8) {
        Ref<Image> converted = Image::create_from_data(
                width, height, false, source->get_format(), pixels);
        converted->convert(Image::FORMAT_RGBA8);
        pixels = converted->get_data();
    }

    // Wrapped rather than copied: an ncnn::Mat built on a pointer it was handed does not
    // own it, so all that is required is that `pixels` outlive the call.
    ncnn::Mat in_mat(width, height, const_cast<uint8_t *>(pixels.ptr()), (size_t)4, 4);

    // One pass. There is no doubling and repeating here — the ratio is in the network.
    const int out_width = width * scale_factor;
    const int out_height = height * scale_factor;

    PackedByteArray out;
    out.resize(static_cast<int64_t>(out_width) * out_height * 4);
    ncnn::Mat out_mat(out_width, out_height, out.ptrw(), (size_t)4, 4);

    if (worker->process(in_mat, out_mat) != 0) {
        last_error = "Real-ESRGAN could not run. The GPU may be out of memory.";
        return Ref<Image>();
    }

    return Image::create_from_data(out_width, out_height, false, Image::FORMAT_RGBA8, out);
}
