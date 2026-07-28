#include "iw_stage_kernels.h"

#include "iw_math.h"

using namespace godot;

namespace {

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
