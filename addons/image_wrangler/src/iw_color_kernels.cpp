#include "iw_stage_kernels.h"

#include "iw_math.h"

#include <cmath>
#include <vector>

using namespace godot;

namespace {

// The split JPEG itself uses, so the brightness this pulls out is the same brightness the
// file was written against. Colour is centred on a half so both parts land in 0 to 1.
inline void to_parts(double r, double g, double b, double &light, double &blue, double &red) {
    light = 0.299 * r + 0.587 * g + 0.114 * b;
    blue = 0.5 - 0.168736 * r - 0.331264 * g + 0.5 * b;
    red = 0.5 + 0.5 * r - 0.418688 * g - 0.081312 * b;
}

inline void to_rgb(double light, double blue, double red, double &r, double &g, double &b) {
    const double cb = blue - 0.5;
    const double cr = red - 0.5;
    r = light + 1.402 * cr;
    g = light - 0.344136 * cb - 0.714136 * cr;
    b = light + 1.772 * cb;
}

// How many steps the brightness-difference weights are looked up in. Fine enough that the
// steps are invisible, small enough to stay in cache.
constexpr int64_t WEIGHT_STEPS = 1024;

// How different two pixels' brightness may be and still count as the same surface, from
// the tightest setting to the loosest.
constexpr double NEAREST_MATCH = 0.02;
constexpr double LOOSEST_MATCH = 0.25;

} // namespace

// Flattens the colour of an image while leaving its brightness alone.
//
// A JPEG stores colour at half the width and half the height of the brightness, then
// stretches it back out on the way in. Colour ends up smeared sideways past every edge, so
// a flat background stops being flat next to a subject — which is what pushes those pixels
// outside a key's tolerance and leaves the halos the stages below spend their time
// chasing.
//
// Every pixel takes the average colour of its neighbours, but only counts a neighbour that
// is about as bright as it is. A background pixel beside a dark subject therefore averages
// with the background alone and lands back on the background's own colour, and the subject
// never gets a say. Brightness is not touched, so nothing sharp is lost, and alpha is not
// colour and comes through byte for byte.
//
// [b]Weighing each neighbour on its own is the whole point, and is why this is not the
// guided filter already in this file.[/b] That one fits a line to a window and then
// averages the fits, and averaging the fits is what carries a colour across an edge — it
// pushed a subject's colour a whole radius out into the background here, which is worse
// than the smear it was asked to remove. Nothing is averaged but the colour itself.
//
// This rewrites the source pixels, so like the denoiser it only belongs above everything
// that keys, and the caller owes the run a rebuild of the distance map afterwards.
void IWStageKernels::smooth_color(const Ref<IWPipelineContext> &ctx, int64_t radius,
        double strength, double amount) {
    if (ctx.is_null() || ctx->pixel_count <= 0 || radius <= 0 || amount <= 0.0) {
        return;
    }

    const int64_t width = ctx->width;
    const int64_t height = ctx->height;
    const int64_t count = ctx->pixel_count;
    const double mix = iw::clampf(amount, 0.0, 1.0);
    const double to_unit = 1.0 / 255.0;

    std::vector<float> light(static_cast<size_t>(count));
    std::vector<float> blue(static_cast<size_t>(count));
    std::vector<float> red(static_cast<size_t>(count));
    {
        const uint8_t *src = ctx->data.ptr();
        for (int64_t i = 0; i < count; i++) {
            const int64_t at = i * 4;
            double y = 0.0;
            double cb = 0.0;
            double cr = 0.0;
            to_parts(src[at] * to_unit, src[at + 1] * to_unit, src[at + 2] * to_unit, y, cb, cr);
            light[static_cast<size_t>(i)] = iw::narrow(y);
            blue[static_cast<size_t>(i)] = iw::narrow(cb);
            red[static_cast<size_t>(i)] = iw::narrow(cr);
        }
    }

    // Both weight tables are built once. The alternative is an exp() per neighbour per
    // pixel, which on a window of any size is most of the work this does.
    const int64_t span = radius * 2 + 1;
    std::vector<double> nearness(static_cast<size_t>(span * span));
    const double spread = iw::maxf(static_cast<double>(radius) * 0.5, 0.5);
    for (int64_t dy = -radius; dy <= radius; dy++) {
        for (int64_t dx = -radius; dx <= radius; dx++) {
            const double away = static_cast<double>(dx * dx + dy * dy);
            nearness[static_cast<size_t>((dy + radius) * span + (dx + radius))] =
                    std::exp(-away / (2.0 * spread * spread));
        }
    }

    const double match = iw::lerpf(NEAREST_MATCH, LOOSEST_MATCH, iw::clampf(strength, 0.0, 1.0));
    std::vector<double> sameness(static_cast<size_t>(WEIGHT_STEPS));
    for (int64_t i = 0; i < WEIGHT_STEPS; i++) {
        const double difference = static_cast<double>(i) / static_cast<double>(WEIGHT_STEPS - 1);
        sameness[static_cast<size_t>(i)] =
                std::exp(-(difference * difference) / (2.0 * match * match));
    }
    const double to_step = static_cast<double>(WEIGHT_STEPS - 1);

    uint8_t *out = ctx->data.ptrw();
    for (int64_t y = 0; y < height; y++) {
        const int64_t top = iw::maxi(y - radius, 0);
        const int64_t bottom = iw::mini(y + radius, height - 1);
        for (int64_t x = 0; x < width; x++) {
            const int64_t here = y * width + x;
            const double own_light = iw::widen(light[static_cast<size_t>(here)]);
            const int64_t left = iw::maxi(x - radius, 0);
            const int64_t right = iw::mini(x + radius, width - 1);

            double weight_total = 0.0;
            double blue_total = 0.0;
            double red_total = 0.0;
            for (int64_t ny = top; ny <= bottom; ny++) {
                const int64_t row = ny * width;
                const int64_t table_row = (ny - y + radius) * span + radius;
                for (int64_t nx = left; nx <= right; nx++) {
                    const int64_t there = row + nx;
                    const double difference = iw::absf(
                            iw::widen(light[static_cast<size_t>(there)]) - own_light);
                    const int64_t step = iw::mini(
                            iw::roundi(difference * to_step), WEIGHT_STEPS - 1);
                    const double weight =
                            nearness[static_cast<size_t>(table_row + (nx - x))]
                            * sameness[static_cast<size_t>(step)];
                    weight_total += weight;
                    blue_total += weight * iw::widen(blue[static_cast<size_t>(there)]);
                    red_total += weight * iw::widen(red[static_cast<size_t>(there)]);
                }
            }

            // A pixel always counts itself at full weight, so the total can never be zero.
            const double cb = iw::lerpf(iw::widen(blue[static_cast<size_t>(here)]),
                    blue_total / weight_total, mix);
            const double cr = iw::lerpf(iw::widen(red[static_cast<size_t>(here)]),
                    red_total / weight_total, mix);
            double r = 0.0;
            double g = 0.0;
            double b = 0.0;
            to_rgb(own_light, cb, cr, r, g, b);
            const int64_t at = here * 4;
            out[at] = static_cast<uint8_t>(iw::roundi(iw::clampf(r, 0.0, 1.0) * 255.0));
            out[at + 1] = static_cast<uint8_t>(iw::roundi(iw::clampf(g, 0.0, 1.0) * 255.0));
            out[at + 2] = static_cast<uint8_t>(iw::roundi(iw::clampf(b, 0.0, 1.0) * 255.0));
        }
    }
}
