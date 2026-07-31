#include "iw_ncnn_instance.h"

#include "gpu.h"

namespace {

// Whether the instance has been asked for, and whether it came.
bool s_tried = false;
bool s_ok = false;

// How many upscalers are open, across both classes that use one.
int s_open_count = 0;

} // namespace

namespace iw_ncnn {

bool ensure_instance() {
    if (s_tried) {
        return s_ok;
    }
    s_tried = true;
    // Zero is ncnn's success.
    s_ok = ncnn::create_gpu_instance() == 0 && ncnn::get_gpu_count() > 0;
    return s_ok;
}

void retain() {
    s_open_count += 1;
}

void release() {
    s_open_count -= 1;
}

void shutdown() {
    // See the header: freeing the instance out from under a live device is a crash, and
    // the process is ending anyway.
    if (s_ok && s_open_count == 0) {
        ncnn::destroy_gpu_instance();
        s_ok = false;
        s_tried = false;
    }
}

} // namespace iw_ncnn
