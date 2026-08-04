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

// A number from 0 to 1, out of the top 53 bits of a hash — the ones a double can hold
// without rounding.
double unit(uint64_t hash) {
    return static_cast<double>(hash >> 11) * (1.0 / 9007199254740992.0);
}

// The same number spread from -1 to 1, for the amounts that reach either way.
double signed_unit(uint64_t hash) {
    return unit(hash) * 2.0 - 1.0;
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

// HSL's lightness, not HSV's value. Value calls white and full red equally bright, so
// tinting by it would turn white into a flat colour; lightness puts white at 1, where no
// tint can reach it.
double to_lightness(double r, double g, double b) {
    const double highest = iw::maxf(r, iw::maxf(g, b));
    const double lowest = iw::minf(r, iw::minf(g, b));
    return (highest + lowest) * 0.5;
}

// One hue and one strength at a given lightness. Hue is a turn round the wheel, as
// everywhere else here. Black and white come out unchanged whatever hue is asked for.
void hsl_to_rgb(double hue, double sat, double light, double &r, double &g, double &b) {
    const double chroma = (1.0 - iw::absf(2.0 * light - 1.0)) * sat;
    if (chroma <= 0.0) {
        r = light;
        g = light;
        b = light;
        return;
    }
    const double sector = hue * 6.0;
    const int64_t step = static_cast<int64_t>(iw::floori(sector)) % 6;
    const double along = sector - iw::floori(sector);
    const double rising = chroma * along;
    const double falling = chroma * (1.0 - along);
    switch (step) {
        case 0: r = chroma; g = rising; b = 0.0; break;
        case 1: r = falling; g = chroma; b = 0.0; break;
        case 2: r = 0.0; g = chroma; b = rising; break;
        case 3: r = 0.0; g = falling; b = chroma; break;
        case 4: r = rising; g = 0.0; b = chroma; break;
        default: r = chroma; g = 0.0; b = falling; break;
    }
    // Chroma is a span, not a position. Lift it so its middle sits at the asked-for
    // lightness.
    const double base = light - chroma * 0.5;
    r += base;
    g += base;
    b += base;
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
// The regions arrive flattened — four numbers of rectangle and four of adjustment per
// region — for the reason every other kernel here takes flat arrays: reaching back into
// an Array of Resources once per pixel would cost more than the whole adjustment does.
//
// [b]Colorize is a second answer, crossfaded in.[/b] The first three numbers move the
// colour that is there; the fourth rebuilds the pixel from one hue at its own lightness
// and mixes towards it. At 0 the branch is skipped and costs nothing.
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
    if (count <= 0 || shifts.size() < count * 4) {
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

        const double turn = shift[n * 4];
        const double sat_scale = shift[n * 4 + 1];
        const double val_scale = shift[n * 4 + 2];
        const double tint_mix = iw::clampf(shift[n * 4 + 3], 0.0, 1.0);

        // Colorize reads the same two sliders the other way round: the turn as a place on
        // the wheel rather than a distance along it, and the scale as a strength.
        const bool tinting = tint_mix > 0.0;
        const double tint_hue = turn - iw::floori(turn);
        const double tint_sat = iw::clampf(sat_scale, 0.0, 1.0);

        for (int64_t y = top; y < bottom; y++) {
            for (int64_t x = left; x < right; x++) {
                const int64_t at = (y * width + x) * 4;
                const double src_r = data[at] * to_unit;
                const double src_g = data[at + 1] * to_unit;
                const double src_b = data[at + 2] * to_unit;
                double hue = 0.0;
                double sat = 0.0;
                double val = 0.0;
                to_hsv(src_r, src_g, src_b, hue, sat, val);

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

                if (tinting) {
                    // The value slider keeps its meaning here, scaling the lightness the
                    // tint is built at rather than the value it no longer has.
                    const double light = iw::clampf(
                            to_lightness(src_r, src_g, src_b) * val_scale, 0.0, 1.0);
                    double tr = 0.0;
                    double tg = 0.0;
                    double tb = 0.0;
                    hsl_to_rgb(tint_hue, tint_sat, light, tr, tg, tb);
                    r = iw::lerpf(r, tr, tint_mix);
                    g = iw::lerpf(g, tg, tint_mix);
                    b = iw::lerpf(b, tb, tint_mix);
                }

                data[at] = static_cast<uint8_t>(iw::roundi(iw::clampf(r, 0.0, 1.0) * 255.0));
                data[at + 1] = static_cast<uint8_t>(iw::roundi(iw::clampf(g, 0.0, 1.0) * 255.0));
                data[at + 2] = static_cast<uint8_t>(iw::roundi(iw::clampf(b, 0.0, 1.0) * 255.0));
            }
        }
    }
}

// Finds every island of visible pixels and gives each one its own random HSV shift, and
// optionally its own tint towards a flat colour.
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
        int64_t rng_seed, double hue_amount, double saturation_amount, double value_amount,
        double colorize_amount) {
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

    // Each island's numbers, drawn from the seed and its own index. Worked out once per
    // island rather than per pixel, and clamped here so a hand-edited file cannot ask for
    // a hue that wraps twice.
    //
    // Hue reaches either way from where it is. The other three reach one way, from no
    // change towards whatever end was asked for.
    const double hue_reach = iw::clampf(hue_amount, 0.0, 1.0) * 0.5;
    const double sat_end = iw::clampf(saturation_amount, 0.0, 2.0);
    const double val_end = iw::clampf(value_amount, 0.0, 3.0);
    const double tint_end = iw::clampf(colorize_amount, 0.0, 1.0);
    const uint64_t root = mix64(static_cast<uint64_t>(rng_seed));
    // Colorize draws from a stream of its own rather than widening the stride of the one
    // above, so a seed picked before this slider existed still gives the colours it did.
    const uint64_t tint_root = mix64(root + 0x9E3779B97F4A7C15ULL);
    std::vector<double> turn(static_cast<size_t>(island_count), 0.0);
    std::vector<double> sat_scale(static_cast<size_t>(island_count), 1.0);
    std::vector<double> val_scale(static_cast<size_t>(island_count), 1.0);
    std::vector<double> tint_mix(static_cast<size_t>(island_count), 0.0);
    for (int64_t n = 0; n < island_count; n++) {
        const uint64_t key = root + static_cast<uint64_t>(n) * 3;
        turn[n] = signed_unit(mix64(key)) * hue_reach;
        sat_scale[n] = 1.0 + unit(mix64(key + 1)) * (sat_end - 1.0);
        val_scale[n] = 1.0 + unit(mix64(key + 2)) * (val_end - 1.0);
        tint_mix[n] = unit(mix64(tint_root + static_cast<uint64_t>(n))) * tint_end;
    }

    const double to_unit = 1.0 / 255.0;
    uint8_t *data = ctx->data.ptrw();
    for (int64_t i = 0; i < pixel_count; i++) {
        const int32_t here = label[i];
        if (here < 0) {
            continue;
        }
        const int64_t at = i * 4;
        const double src_r = data[at] * to_unit;
        const double src_g = data[at + 1] * to_unit;
        const double src_b = data[at + 2] * to_unit;
        double hue = 0.0;
        double sat = 0.0;
        double val = 0.0;
        to_hsv(src_r, src_g, src_b, hue, sat, val);

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

        // The same tint adjust_hsv applies, with the island's own random numbers standing
        // in for a region's sliders: its turn read as a place on the wheel, its saturation
        // as the tint's strength.
        const double mix = tint_mix[here];
        if (mix > 0.0) {
            const double tint_hue = turn[here] - iw::floori(turn[here]);
            const double tint_sat = iw::clampf(sat_scale[here], 0.0, 1.0);
            const double light = iw::clampf(
                    to_lightness(src_r, src_g, src_b) * val_scale[here], 0.0, 1.0);
            double tr = 0.0;
            double tg = 0.0;
            double tb = 0.0;
            hsl_to_rgb(tint_hue, tint_sat, light, tr, tg, tb);
            r = iw::lerpf(r, tr, mix);
            g = iw::lerpf(g, tg, mix);
            b = iw::lerpf(b, tb, mix);
        }

        data[at] = static_cast<uint8_t>(iw::roundi(iw::clampf(r, 0.0, 1.0) * 255.0));
        data[at + 1] = static_cast<uint8_t>(iw::roundi(iw::clampf(g, 0.0, 1.0) * 255.0));
        data[at + 2] = static_cast<uint8_t>(iw::roundi(iw::clampf(b, 0.0, 1.0) * 255.0));
    }

    return bounds;
}
