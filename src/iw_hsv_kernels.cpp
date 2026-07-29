#include "iw_stage_kernels.h"

#include "iw_islands.h"
#include "iw_math.h"

#include <vector>

using namespace godot;

namespace {

// SplitMix64's finaliser: a hash rather than a stream.
//
// Every random number this file draws is a hash of the seed and what it is for, so an
// island's colour depends on nothing but which island it is. A stream would make each
// island's colour depend on how many islands came before it, and one extra speck
// somewhere in the corner of a sheet would then recolour everything after it.
uint64_t mix64(uint64_t value) {
    value += 0x9E3779B97F4A7C15ULL;
    value = (value ^ (value >> 30)) * 0xBF58476D1CE4E5B9ULL;
    value = (value ^ (value >> 27)) * 0x94D049BB133111EBULL;
    return value ^ (value >> 31);
}

// A number from -1 to 1, out of the top 53 bits of a hash — the ones a double can hold
// without rounding.
double signed_unit(uint64_t hash) {
    const double unit = static_cast<double>(hash >> 11) * (1.0 / 9007199254740992.0);
    return unit * 2.0 - 1.0;
}

// Colour as hue, how colourful it is, and how light it is.
//
// Hue comes back as a turn round the wheel rather than degrees, so shifting it is an add
// and a wrap rather than a divide.
void to_hsv(double r, double g, double b, double &hue, double &sat, double &val) {
    const double highest = iw::maxf(r, iw::maxf(g, b));
    const double lowest = iw::minf(r, iw::minf(g, b));
    const double span = highest - lowest;

    val = highest;
    sat = highest <= 0.0 ? 0.0 : span / highest;

    if (span <= 0.0) {
        // Grey has no hue. Zero rather than anything else, so a shift on a grey pixel
        // stays grey instead of inventing a colour out of rounding.
        hue = 0.0;
        return;
    }
    if (highest == r) {
        hue = (g - b) / span;
    } else if (highest == g) {
        hue = 2.0 + (b - r) / span;
    } else {
        hue = 4.0 + (r - g) / span;
    }
    hue /= 6.0;
    if (hue < 0.0) {
        hue += 1.0;
    }
}

void to_rgb(double hue, double sat, double val, double &r, double &g, double &b) {
    if (sat <= 0.0) {
        r = val;
        g = val;
        b = val;
        return;
    }
    const double sector = hue * 6.0;
    const int64_t step = static_cast<int64_t>(iw::floori(sector)) % 6;
    const double along = sector - iw::floori(sector);
    const double dim = val * (1.0 - sat);
    const double falling = val * (1.0 - sat * along);
    const double rising = val * (1.0 - sat * (1.0 - along));
    switch (step) {
        case 0: r = val; g = rising; b = dim; break;
        case 1: r = falling; g = val; b = dim; break;
        case 2: r = dim; g = val; b = rising; break;
        case 3: r = dim; g = falling; b = val; break;
        case 4: r = rising; g = dim; b = val; break;
        default: r = val; g = dim; b = falling; break;
    }
}

} // namespace

// Turns the hue, and scales how colourful and how light the pixels are, inside each
// rectangle it is given.
//
// The regions arrive flattened — four numbers of rectangle and three of adjustment per
// region — for the reason every other kernel here takes flat arrays: reaching back into
// an Array of Resources once per pixel would cost more than the whole adjustment does.
//
// Regions are applied in the order they were picked, and they are allowed to overlap. Two
// covering the same pixel both act on it, the second working on what the first left,
// which is what makes a broad correction with a local one on top of it possible.
//
// [b]Alpha is not colour and is never touched.[/b] Neither is any pixel outside every
// rectangle. This rewrites the source pixels, so it belongs above everything that keys —
// and the caller owes the run a rebuild of the distance map afterwards, since what the
// keys are measured against has moved.
void IWStageKernels::adjust_hsv(const Ref<IWPipelineContext> &ctx,
        const PackedInt32Array &rects, const PackedFloat64Array &shifts) {
    if (ctx.is_null() || ctx->pixel_count <= 0) {
        return;
    }
    const int64_t count = rects.size() / 4;
    if (count <= 0 || shifts.size() < count * 3) {
        return;
    }

    const int64_t width = ctx->width;
    const int64_t height = ctx->height;
    const double to_unit = 1.0 / 255.0;
    const int32_t *box = rects.ptr();
    const double *shift = shifts.ptr();
    uint8_t *data = ctx->data.ptrw();

    for (int64_t n = 0; n < count; n++) {
        const int64_t left = iw::maxi(box[n * 4], 0);
        const int64_t top = iw::maxi(box[n * 4 + 1], 0);
        const int64_t right = iw::mini(box[n * 4] + box[n * 4 + 2], width);
        const int64_t bottom = iw::mini(box[n * 4 + 1] + box[n * 4 + 3], height);
        if (left >= right || top >= bottom) {
            continue;
        }

        const double turn = shift[n * 3];
        const double sat_scale = shift[n * 3 + 1];
        const double val_scale = shift[n * 3 + 2];

        for (int64_t y = top; y < bottom; y++) {
            for (int64_t x = left; x < right; x++) {
                const int64_t at = (y * width + x) * 4;
                double hue = 0.0;
                double sat = 0.0;
                double val = 0.0;
                to_hsv(data[at] * to_unit, data[at + 1] * to_unit, data[at + 2] * to_unit,
                        hue, sat, val);

                // Hue wraps rather than clamping: the wheel has no ends, and a turn that
                // stopped at red would bunch every shifted colour up against it.
                hue += turn;
                hue -= iw::floori(hue);
                sat = iw::clampf(sat * sat_scale, 0.0, 1.0);
                val = iw::clampf(val * val_scale, 0.0, 1.0);

                double r = 0.0;
                double g = 0.0;
                double b = 0.0;
                to_rgb(hue, sat, val, r, g, b);
                data[at] = static_cast<uint8_t>(iw::roundi(iw::clampf(r, 0.0, 1.0) * 255.0));
                data[at + 1] = static_cast<uint8_t>(iw::roundi(iw::clampf(g, 0.0, 1.0) * 255.0));
                data[at + 2] = static_cast<uint8_t>(iw::roundi(iw::clampf(b, 0.0, 1.0) * 255.0));
            }
        }
    }
}

// Finds every island of visible pixels and gives each one its own random HSV shift.
//
// Islands are read off what the run currently shows — the source's alpha times whatever
// the stages above have keyed out — so the same stage finds one island in an untouched
// sheet with an opaque background and one per object in the same sheet with that
// background removed. Nothing here decides what an object is; the alpha already did.
//
// What counts as one island — two passes for the solid part and its fringe, 8-connected —
// is decided by iw::label_islands and explained there. Packing asks the same question of
// the same code, so a sheet coloured by this stage and packed by that one cannot disagree
// about where one object ends and the next begins.
//
// Returns x, y, w, h per island: the smallest rectangle containing each one, in the order
// they were found. Alpha is never touched, and nor is any pixel outside every island. This
// rewrites the source pixels, so the caller owes the run a rebuild of the distance map
// afterwards.
PackedInt32Array IWStageKernels::random_hsv_tiles(const Ref<IWPipelineContext> &ctx,
        int64_t rng_seed, double hue_amount, double saturation_amount, double value_amount) {
    PackedInt32Array bounds;
    ERR_FAIL_COND_V(ctx.is_null(), bounds);
    if (ctx->pixel_count <= 0) {
        return bounds;
    }

    const int64_t width = ctx->width;
    const int64_t height = ctx->height;
    const int64_t pixel_count = ctx->pixel_count;

    const PackedFloat32Array visible = ctx->final_alpha();
    if (visible.size() != pixel_count) {
        return bounds;
    }
    const float *alpha = visible.ptr();

    const iw::Islands found = iw::label_islands(alpha, width, height);
    const int64_t island_count = found.count();
    if (island_count <= 0) {
        return bounds;
    }
    const std::vector<int32_t> &label = found.label;

    bounds.resize(island_count * 4);
    {
        int32_t *out = bounds.ptrw();
        for (int64_t n = 0; n < island_count; n++) {
            out[n * 4] = found.min_x[n];
            out[n * 4 + 1] = found.min_y[n];
            out[n * 4 + 2] = found.max_x[n] - found.min_x[n] + 1;
            out[n * 4 + 3] = found.max_y[n] - found.min_y[n] + 1;
        }
    }

    // Each island's three numbers, drawn from the seed and its own index. Worked out once
    // per island rather than per pixel, and clamped here so a hand-edited file cannot ask
    // for a hue that wraps twice.
    const double hue_reach = iw::clampf(hue_amount, 0.0, 1.0) * 0.5;
    const double sat_reach = iw::clampf(saturation_amount, 0.0, 1.0);
    const double val_reach = iw::clampf(value_amount, 0.0, 1.0);
    const uint64_t root = mix64(static_cast<uint64_t>(rng_seed));
    std::vector<double> turn(static_cast<size_t>(island_count), 0.0);
    std::vector<double> sat_scale(static_cast<size_t>(island_count), 1.0);
    std::vector<double> val_scale(static_cast<size_t>(island_count), 1.0);
    for (int64_t n = 0; n < island_count; n++) {
        const uint64_t key = root + static_cast<uint64_t>(n) * 3;
        turn[n] = signed_unit(mix64(key)) * hue_reach;
        sat_scale[n] = 1.0 + signed_unit(mix64(key + 1)) * sat_reach;
        val_scale[n] = 1.0 + signed_unit(mix64(key + 2)) * val_reach;
    }

    const double to_unit = 1.0 / 255.0;
    uint8_t *data = ctx->data.ptrw();
    for (int64_t i = 0; i < pixel_count; i++) {
        const int32_t here = label[i];
        if (here < 0) {
            continue;
        }
        const int64_t at = i * 4;
        double hue = 0.0;
        double sat = 0.0;
        double val = 0.0;
        to_hsv(data[at] * to_unit, data[at + 1] * to_unit, data[at + 2] * to_unit,
                hue, sat, val);

        // Hue wraps rather than clamping, exactly as it does in adjust_hsv: the wheel has
        // no ends, and a turn that stopped at red would bunch every shifted island up
        // against it.
        hue += turn[here];
        hue -= iw::floori(hue);
        sat = iw::clampf(sat * sat_scale[here], 0.0, 1.0);
        val = iw::clampf(val * val_scale[here], 0.0, 1.0);

        double r = 0.0;
        double g = 0.0;
        double b = 0.0;
        to_rgb(hue, sat, val, r, g, b);
        data[at] = static_cast<uint8_t>(iw::roundi(iw::clampf(r, 0.0, 1.0) * 255.0));
        data[at + 1] = static_cast<uint8_t>(iw::roundi(iw::clampf(g, 0.0, 1.0) * 255.0));
        data[at + 2] = static_cast<uint8_t>(iw::roundi(iw::clampf(b, 0.0, 1.0) * 255.0));
    }

    return bounds;
}
