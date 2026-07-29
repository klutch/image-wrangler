#include "iw_stage_kernels.h"

#include "iw_math.h"

#include <vector>

using namespace godot;

namespace {

// How much of a pixel has to survive for it to count as part of an object rather than
// part of its fringe. Half, matching what RemoveLines calls the solid part of a shape.
constexpr double SOLID_ALPHA = 0.5;

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
// [b]Two passes, because thickness and extent are different questions.[/b] The first
// labels the solid part, where alpha is at least a half, and that is what decides which
// pixels are one object. The second grows each label outwards through anything still
// visible, which is what brings an object's antialiased fringe along with it — a fringe
// left behind would ring every recoloured object in the colour it used to be. The same
// split RemoveLines makes, for the same reason. An island with no solid pixel anywhere is
// never labelled and is left alone.
//
// [b]8-connected, where the floods are 4-connected.[/b] Their question is whether
// background can leak through a diagonal hairline, and it must not. The question here is
// whether two parts touching corner to corner are one object, and they are — splitting
// them would hand one flower two colours.
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

    std::vector<int32_t> label(static_cast<size_t>(pixel_count), -1);
    // One queue for both passes. Every pixel enters it at most once — it is put there by
    // whichever label claimed it, and a labelled pixel is never offered again — so it can
    // be sized up front and used as a plain FIFO with no wraparound. The second pass
    // rewinds over what the first left in it, which is every solid pixel in the order it
    // was labelled, and appends the fringe to the same buffer.
    std::vector<int32_t> queue(static_cast<size_t>(pixel_count), 0);
    int64_t head = 0;
    int64_t tail = 0;

    std::vector<int32_t> min_x;
    std::vector<int32_t> min_y;
    std::vector<int32_t> max_x;
    std::vector<int32_t> max_y;

    // Marks one pixel as belonging to one island, stretches that island's rectangle round
    // it, and queues it. A lambda rather than the macro its neighbours in this file use:
    // both callers below hand it a variable of their own, and a macro declaring locals of
    // its own would shadow theirs.
    const auto claim = [&](int32_t index, int32_t island) {
        label[index] = island;
        const int32_t x = static_cast<int32_t>(index % width);
        const int32_t y = static_cast<int32_t>(index / width);
        if (x < min_x[island]) {
            min_x[island] = x;
        }
        if (x > max_x[island]) {
            max_x[island] = x;
        }
        if (y < min_y[island]) {
            min_y[island] = y;
        }
        if (y > max_y[island]) {
            max_y[island] = y;
        }
        queue[tail++] = index;
    };

    // The solid part, one island at a time. Each island's flood drains before the scan
    // moves on, so the queue holds them in the order they were found.
    for (int64_t i = 0; i < pixel_count; i++) {
        if (label[i] >= 0 || iw::widen(alpha[i]) < SOLID_ALPHA) {
            continue;
        }
        const int32_t here = static_cast<int32_t>(min_x.size());
        min_x.push_back(static_cast<int32_t>(i % width));
        max_x.push_back(min_x[here]);
        min_y.push_back(static_cast<int32_t>(i / width));
        max_y.push_back(min_y[here]);
        claim(static_cast<int32_t>(i), here);

        while (head < tail) {
            const int32_t index = queue[head++];
            const int64_t x = index % width;
            const int64_t y = index / width;
            const int64_t first_row = iw::maxi(y - 1, 0);
            const int64_t last_row = iw::mini(y + 1, height - 1);
            const int64_t first_col = iw::maxi(x - 1, 0);
            const int64_t last_col = iw::mini(x + 1, width - 1);
            for (int64_t row = first_row; row <= last_row; row++) {
                for (int64_t col = first_col; col <= last_col; col++) {
                    const int32_t n = static_cast<int32_t>(row * width + col);
                    if (label[n] < 0 && iw::widen(alpha[n]) >= SOLID_ALPHA) {
                        claim(n, here);
                    }
                }
            }
        }
    }

    const int64_t island_count = static_cast<int64_t>(min_x.size());
    if (island_count <= 0) {
        return bounds;
    }

    // The fringe, from every island at once. Rewinding rather than reseeding: what the
    // first pass left in the queue is exactly the set to grow from, and growing them
    // together is what stops the island that happened to be found first claiming the
    // whole of a fringe two objects share.
    head = 0;
    while (head < tail) {
        const int32_t index = queue[head++];
        const int32_t here = label[index];
        const int64_t x = index % width;
        const int64_t y = index / width;
        const int64_t first_row = iw::maxi(y - 1, 0);
        const int64_t last_row = iw::mini(y + 1, height - 1);
        const int64_t first_col = iw::maxi(x - 1, 0);
        const int64_t last_col = iw::mini(x + 1, width - 1);
        for (int64_t row = first_row; row <= last_row; row++) {
            for (int64_t col = first_col; col <= last_col; col++) {
                const int32_t n = static_cast<int32_t>(row * width + col);
                if (label[n] < 0 && iw::widen(alpha[n]) > 0.0) {
                    claim(n, here);
                }
            }
        }
    }

    bounds.resize(island_count * 4);
    {
        int32_t *out = bounds.ptrw();
        for (int64_t n = 0; n < island_count; n++) {
            out[n * 4] = min_x[n];
            out[n * 4 + 1] = min_y[n];
            out[n * 4 + 2] = max_x[n] - min_x[n] + 1;
            out[n * 4 + 3] = max_y[n] - min_y[n] + 1;
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
