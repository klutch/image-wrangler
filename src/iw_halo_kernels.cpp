#include "iw_stage_kernels.h"

#include "iw_math.h"

#include <cmath>
#include <vector>

using namespace godot;

namespace {

// JPEG works in squares of this many pixels, counted from the top-left corner of the
// image it was encoded from.
constexpr int64_t BLOCK = 8;

} // namespace

// Flattens the ripples a JPEG leaves beside a hard edge.
//
// A sharp edge needs a great deal of fine detail to describe, and the encoder throws the
// finest of it away. What is left overshoots and undershoots as it crosses the edge, so
// the ground either side comes out rippled rather than flat.
//
// [b]Only squares that hold an edge are touched at all.[/b] The ripples come from an edge
// and cannot exist without one, so a square whose lightest and darkest pixel are close
// together has nothing here to repair and is left exactly as it arrived. That is what
// keeps this from being a blur over the whole image.
//
// [b]A pixel is only ever averaged with neighbours on its own side of the edge.[/b] Every
// pixel in a square is sorted against the square's midpoint, and neighbours on the far
// side are skipped rather than weighted down — so the average cannot reach across the
// boundary however wide the reach is set. That is what makes the reach safe to raise,
// and raising it is the only thing that makes this work harder: the ripple is several
// pixels across, and a filter that can only see one pixel either way barely dents it.
//
// Read from one copy and written to another, because a pixel that has just been smoothed
// must not become the evidence that its neighbour needs smoothing too.
//
// This rewrites the source pixels, so like the other repairs it only belongs above
// everything that keys, and the caller owes the run a rebuild of the distance map
// afterwards.
void IWStageKernels::smooth_halos(const Ref<IWPipelineContext> &ctx, double threshold,
        int64_t radius, double strength) {
    if (ctx.is_null() || ctx->pixel_count <= 0 || threshold <= 0.0 || radius <= 0
            || strength <= 0.0) {
        return;
    }

    const int64_t width = ctx->width;
    const int64_t height = ctx->height;
    const int64_t count = ctx->pixel_count;
    const double edge = iw::clampf(threshold, 0.0, 1.0);
    const double mix = iw::clampf(strength, 0.0, 1.0);
    const double to_unit = 1.0 / 255.0;

    std::vector<float> src(static_cast<size_t>(count * 3));
    {
        const uint8_t *data = ctx->data.ptr();
        for (int64_t i = 0; i < count; i++) {
            const int64_t from = i * 4;
            const int64_t into = i * 3;
            src[static_cast<size_t>(into)] = iw::narrow(data[from] * to_unit);
            src[static_cast<size_t>(into + 1)] = iw::narrow(data[from + 1] * to_unit);
            src[static_cast<size_t>(into + 2)] = iw::narrow(data[from + 2] * to_unit);
        }
    }
    std::vector<float> out = src;

    // Falloff by distance, worked out once. An exp() per neighbour per pixel is most of
    // what this would otherwise spend its time doing.
    const int64_t span = radius * 2 + 1;
    std::vector<double> falloff(static_cast<size_t>(span * span));
    const double spread = iw::maxf(static_cast<double>(radius) * 0.6, 0.5);
    for (int64_t dy = -radius; dy <= radius; dy++) {
        for (int64_t dx = -radius; dx <= radius; dx++) {
            const double away = static_cast<double>(dx * dx + dy * dy);
            falloff[static_cast<size_t>((dy + radius) * span + (dx + radius))] =
                    std::exp(-away / (2.0 * spread * spread));
        }
    }

    for (int64_t top = 0; top < height; top += BLOCK) {
        const int64_t bottom = iw::mini(top + BLOCK, height);
        for (int64_t left = 0; left < width; left += BLOCK) {
            const int64_t right = iw::mini(left + BLOCK, width);

            for (int64_t c = 0; c < 3; c++) {
                double lowest = 1.0;
                double highest = 0.0;
                for (int64_t y = top; y < bottom; y++) {
                    for (int64_t x = left; x < right; x++) {
                        const double v = iw::widen(
                                src[static_cast<size_t>((y * width + x) * 3 + c)]);
                        lowest = iw::minf(lowest, v);
                        highest = iw::maxf(highest, v);
                    }
                }
                // No edge in this square, so nothing here rang in the first place.
                if (highest - lowest < edge) {
                    continue;
                }
                const double middle = (lowest + highest) * 0.5;

                for (int64_t y = top; y < bottom; y++) {
                    const int64_t up = iw::maxi(y - radius, 0);
                    const int64_t down = iw::mini(y + radius, height - 1);
                    for (int64_t x = left; x < right; x++) {
                        const int64_t at = (y * width + x) * 3 + c;
                        const double here = iw::widen(src[static_cast<size_t>(at)]);
                        const bool above = here >= middle;
                        const int64_t from = iw::maxi(x - radius, 0);
                        const int64_t to = iw::mini(x + radius, width - 1);

                        double weight_total = 0.0;
                        double value_total = 0.0;
                        for (int64_t ny = up; ny <= down; ny++) {
                            const int64_t row = ny * width;
                            const int64_t table = (ny - y + radius) * span + radius;
                            for (int64_t nx = from; nx <= to; nx++) {
                                const double v = iw::widen(
                                        src[static_cast<size_t>((row + nx) * 3 + c)]);
                                // The far side of the edge is not this pixel's business.
                                if ((v >= middle) != above) {
                                    continue;
                                }
                                const double w =
                                        falloff[static_cast<size_t>(table + (nx - x))];
                                weight_total += w;
                                value_total += w * v;
                            }
                        }

                        // A pixel always counts itself, so the total can never be zero.
                        const double settled = iw::lerpf(here, value_total / weight_total, mix);
                        out[static_cast<size_t>(at)] = iw::narrow(
                                iw::clampf(settled, 0.0, 1.0));
                    }
                }
            }
        }
    }

    uint8_t *data = ctx->data.ptrw();
    for (int64_t i = 0; i < count; i++) {
        const int64_t from = i * 3;
        const int64_t into = i * 4;
        data[into] = static_cast<uint8_t>(iw::roundi(iw::widen(out[from]) * 255.0));
        data[into + 1] = static_cast<uint8_t>(iw::roundi(iw::widen(out[from + 1]) * 255.0));
        data[into + 2] = static_cast<uint8_t>(iw::roundi(iw::widen(out[from + 2]) * 255.0));
    }
}
