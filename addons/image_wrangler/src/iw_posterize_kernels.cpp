#include "iw_stage_kernels.h"

#include "iw_islands.h"
#include "iw_math.h"

#include <vector>

using namespace godot;

namespace {

// Five bits per channel, which is Wu's own resolution. Fine enough that two colors a
// person can tell apart land in different cells, coarse enough that the tables stay small.
constexpr int64_t GRID_SIZE = 32;

// The tables carry a zero plane on each axis, so a box's total is the difference of eight
// corners with no bounds test.
constexpr int64_t MOMENT_SIZE = GRID_SIZE + 1;
constexpr int64_t MOMENT_COUNT = MOMENT_SIZE * MOMENT_SIZE * MOMENT_SIZE;

constexpr int64_t MIN_COLORS = 2;
constexpr int64_t MAX_COLORS = 256;
constexpr int64_t MIN_LEVELS = 2;
constexpr int64_t MAX_LEVELS = 32;

// At or above this a pixel counts toward the palette. Anything visible at all is
// recolored, but a half-covered fringe pixel is a blend of two colors and has no business
// voting on what the colors are. The same half iw::label_islands calls solid, so a tile's
// palette is built from exactly the pixels that decided the tile was a tile.
constexpr double SOLID = iw::SOLID_ALPHA;

// A region holding more pixels than the cube holds cells is quicker served by a lookup
// table than by asking the palette directly for each one. Below that the table costs more
// to fill than it ever saves.
//
// Every table together can never come to more than one byte per pixel of the image, since
// a region only earns one by holding at least as many pixels as the table has entries.
constexpr int64_t TABLE_WORTH_IT = GRID_SIZE * GRID_SIZE * GRID_SIZE;

// Further apart than two colors can be, which is 3 * 255 * 255.
constexpr int64_t FAR_APART = 1 << 30;

enum { PALETTE_EVEN = 0, PALETTE_BEST = 1 };
enum { DITHER_NONE = 0, DITHER_FLOYD = 1 };
enum { AXIS_R = 0, AXIS_G = 1, AXIS_B = 2 };

int64_t at3(int64_t r, int64_t g, int64_t b) {
    return (r * MOMENT_SIZE + g) * MOMENT_SIZE + b;
}

// A corner of the color cube, in table indices rather than in bytes. The low bound names
// the plane below the box rather than its first cell, which is what lets the eight-corner
// difference work at the edges.
struct Box {
    int64_t r0 = 0;
    int64_t r1 = 0;
    int64_t g0 = 0;
    int64_t g1 = 0;
    int64_t b0 = 0;
    int64_t b1 = 0;
    int64_t volume = 0;
};

// How many pixels fell in each cell, their channel totals, and the total of
// r*r + g*g + b*b. Everything but the last is an integer so the running sums stay exact.
// The last is only ever divided, and on a sheet of any size it stays well inside the range
// a double still counts one by one.
struct Moments {
    std::vector<int64_t> count;
    std::vector<int64_t> sum_r;
    std::vector<int64_t> sum_g;
    std::vector<int64_t> sum_b;
    std::vector<double> sum_sq;
};

int64_t vol_i(const std::vector<int64_t> &m, const Box &box) {
    return m[at3(box.r1, box.g1, box.b1)] - m[at3(box.r1, box.g1, box.b0)]
            - m[at3(box.r1, box.g0, box.b1)] + m[at3(box.r1, box.g0, box.b0)]
            - m[at3(box.r0, box.g1, box.b1)] + m[at3(box.r0, box.g1, box.b0)]
            + m[at3(box.r0, box.g0, box.b1)] - m[at3(box.r0, box.g0, box.b0)];
}

double vol_d(const std::vector<double> &m, const Box &box) {
    return m[at3(box.r1, box.g1, box.b1)] - m[at3(box.r1, box.g1, box.b0)]
            - m[at3(box.r1, box.g0, box.b1)] + m[at3(box.r1, box.g0, box.b0)]
            - m[at3(box.r0, box.g1, box.b1)] + m[at3(box.r0, box.g1, box.b0)]
            + m[at3(box.r0, box.g0, box.b1)] - m[at3(box.r0, box.g0, box.b0)];
}

// The part of a box's total that sits below every cut on one axis, and the part a cut at
// `pos` adds to it. Together they let one walk along an axis price every cut position
// without re-totalling the box each time.
int64_t bottom(const std::vector<int64_t> &m, const Box &box, int axis) {
    switch (axis) {
        case AXIS_R:
            return -m[at3(box.r0, box.g1, box.b1)] + m[at3(box.r0, box.g1, box.b0)]
                    + m[at3(box.r0, box.g0, box.b1)] - m[at3(box.r0, box.g0, box.b0)];
        case AXIS_G:
            return -m[at3(box.r1, box.g0, box.b1)] + m[at3(box.r1, box.g0, box.b0)]
                    + m[at3(box.r0, box.g0, box.b1)] - m[at3(box.r0, box.g0, box.b0)];
        default:
            return -m[at3(box.r1, box.g1, box.b0)] + m[at3(box.r1, box.g0, box.b0)]
                    + m[at3(box.r0, box.g1, box.b0)] - m[at3(box.r0, box.g0, box.b0)];
    }
}

int64_t top(const std::vector<int64_t> &m, const Box &box, int axis, int64_t pos) {
    switch (axis) {
        case AXIS_R:
            return m[at3(pos, box.g1, box.b1)] - m[at3(pos, box.g1, box.b0)]
                    - m[at3(pos, box.g0, box.b1)] + m[at3(pos, box.g0, box.b0)];
        case AXIS_G:
            return m[at3(box.r1, pos, box.b1)] - m[at3(box.r1, pos, box.b0)]
                    - m[at3(box.r0, pos, box.b1)] + m[at3(box.r0, pos, box.b0)];
        default:
            return m[at3(box.r1, box.g1, pos)] - m[at3(box.r1, box.g0, pos)]
                    - m[at3(box.r0, box.g1, pos)] + m[at3(box.r0, box.g0, pos)];
    }
}

// How much color error a box still holds: the total of the squares less the square of the
// total, which is what splitting it could win back.
double variance(const Moments &m, const Box &box) {
    const double weight = static_cast<double>(vol_i(m.count, box));
    if (weight <= 0.0) {
        return 0.0;
    }
    const double dr = static_cast<double>(vol_i(m.sum_r, box));
    const double dg = static_cast<double>(vol_i(m.sum_g, box));
    const double db = static_cast<double>(vol_i(m.sum_b, box));
    return vol_d(m.sum_sq, box) - (dr * dr + dg * dg + db * db) / weight;
}

// Walks every cut position on one axis and answers with the most error a cut there could
// remove, leaving that position in `cut`. A negative `cut` means the axis has no legal
// cut, which is what happens once a box is one cell wide or holds one color.
//
// The channel totals are widened before they are squared. On a large sheet a total reaches
// four thousand million, and its square does not fit in an integer.
double maximize(const Moments &m, const Box &box, int axis, int64_t first, int64_t last,
        int64_t &cut, int64_t whole_r, int64_t whole_g, int64_t whole_b, int64_t whole_w) {
    const int64_t base_r = bottom(m.sum_r, box, axis);
    const int64_t base_g = bottom(m.sum_g, box, axis);
    const int64_t base_b = bottom(m.sum_b, box, axis);
    const int64_t base_w = bottom(m.count, box, axis);

    double best = 0.0;
    cut = -1;
    for (int64_t i = first; i < last; i++) {
        int64_t half_r = base_r + top(m.sum_r, box, axis, i);
        int64_t half_g = base_g + top(m.sum_g, box, axis, i);
        int64_t half_b = base_b + top(m.sum_b, box, axis, i);
        int64_t half_w = base_w + top(m.count, box, axis, i);
        if (half_w == 0) {
            continue;
        }
        double dr = static_cast<double>(half_r);
        double dg = static_cast<double>(half_g);
        double db = static_cast<double>(half_b);
        double gain = (dr * dr + dg * dg + db * db) / static_cast<double>(half_w);

        half_r = whole_r - half_r;
        half_g = whole_g - half_g;
        half_b = whole_b - half_b;
        half_w = whole_w - half_w;
        if (half_w == 0) {
            continue;
        }
        dr = static_cast<double>(half_r);
        dg = static_cast<double>(half_g);
        db = static_cast<double>(half_b);
        gain += (dr * dr + dg * dg + db * db) / static_cast<double>(half_w);

        if (gain > best) {
            best = gain;
            cut = i;
        }
    }
    return best;
}

// Splits `one` in two, putting the far half in `two`. False when there is nothing left to
// split, which is the caller's signal to stop asking about this box.
bool cut_box(const Moments &m, Box &one, Box &two) {
    const int64_t whole_r = vol_i(m.sum_r, one);
    const int64_t whole_g = vol_i(m.sum_g, one);
    const int64_t whole_b = vol_i(m.sum_b, one);
    const int64_t whole_w = vol_i(m.count, one);

    int64_t cut_r = -1;
    int64_t cut_g = -1;
    int64_t cut_b = -1;
    const double max_r = maximize(m, one, AXIS_R, one.r0 + 1, one.r1, cut_r,
            whole_r, whole_g, whole_b, whole_w);
    const double max_g = maximize(m, one, AXIS_G, one.g0 + 1, one.g1, cut_g,
            whole_r, whole_g, whole_b, whole_w);
    const double max_b = maximize(m, one, AXIS_B, one.b0 + 1, one.b1, cut_b,
            whole_r, whole_g, whole_b, whole_w);

    int axis = AXIS_B;
    int64_t cut = cut_b;
    if (max_r >= max_g && max_r >= max_b) {
        axis = AXIS_R;
        cut = cut_r;
    } else if (max_g >= max_r && max_g >= max_b) {
        axis = AXIS_G;
        cut = cut_g;
    }
    if (cut < 0) {
        return false;
    }

    two.r1 = one.r1;
    two.g1 = one.g1;
    two.b1 = one.b1;
    switch (axis) {
        case AXIS_R:
            two.r0 = cut;
            one.r1 = cut;
            two.g0 = one.g0;
            two.b0 = one.b0;
            break;
        case AXIS_G:
            two.g0 = cut;
            one.g1 = cut;
            two.r0 = one.r0;
            two.b0 = one.b0;
            break;
        default:
            two.b0 = cut;
            one.b1 = cut;
            two.r0 = one.r0;
            two.g0 = one.g0;
            break;
    }
    one.volume = (one.r1 - one.r0) * (one.g1 - one.g0) * (one.b1 - one.b0);
    two.volume = (two.r1 - two.r0) * (two.g1 - two.g0) * (two.b1 - two.b0);
    return true;
}

// Counts the colors of every solid pixel inside one rectangle, then turns those counts
// into running totals so any box in the cube can be totalled from its eight corners.
//
// `label` null counts the whole rectangle; otherwise only the pixels carrying `want`, so
// one tile can be counted without its neighbours. The rectangle is inclusive on both
// corners, matching what iw::label_islands hands back.
//
// Answers with how many pixels it counted, which is what decides whether a lookup table is
// worth building for this region.
int64_t build_moments(const uint8_t *data, const float *alpha, const int32_t *label,
        int32_t want, int64_t width, int64_t x0, int64_t y0, int64_t x1, int64_t y1,
        Moments &m) {
    m.count.assign(static_cast<size_t>(MOMENT_COUNT), 0);
    m.sum_r.assign(static_cast<size_t>(MOMENT_COUNT), 0);
    m.sum_g.assign(static_cast<size_t>(MOMENT_COUNT), 0);
    m.sum_b.assign(static_cast<size_t>(MOMENT_COUNT), 0);
    m.sum_sq.assign(static_cast<size_t>(MOMENT_COUNT), 0.0);

    int64_t counted = 0;
    for (int64_t y = y0; y <= y1; y++) {
        for (int64_t x = x0; x <= x1; x++) {
            const int64_t i = y * width + x;
            if (iw::widen(alpha[i]) < SOLID) {
                continue;
            }
            if (label != nullptr && label[i] != want) {
                continue;
            }
            const int64_t at = i * 4;
            const int64_t r = data[at];
            const int64_t g = data[at + 1];
            const int64_t b = data[at + 2];
            const int64_t cell = at3((r >> 3) + 1, (g >> 3) + 1, (b >> 3) + 1);
            m.count[cell]++;
            m.sum_r[cell] += r;
            m.sum_g[cell] += g;
            m.sum_b[cell] += b;
            m.sum_sq[cell] += static_cast<double>(r * r + g * g + b * b);
            counted++;
        }
    }
    if (counted == 0) {
        return 0;
    }

    std::vector<int64_t> area(static_cast<size_t>(MOMENT_SIZE), 0);
    std::vector<int64_t> area_r(static_cast<size_t>(MOMENT_SIZE), 0);
    std::vector<int64_t> area_g(static_cast<size_t>(MOMENT_SIZE), 0);
    std::vector<int64_t> area_b(static_cast<size_t>(MOMENT_SIZE), 0);
    std::vector<double> area_sq(static_cast<size_t>(MOMENT_SIZE), 0.0);
    for (int64_t r = 1; r < MOMENT_SIZE; r++) {
        for (int64_t i = 0; i < MOMENT_SIZE; i++) {
            area[i] = 0;
            area_r[i] = 0;
            area_g[i] = 0;
            area_b[i] = 0;
            area_sq[i] = 0.0;
        }
        for (int64_t g = 1; g < MOMENT_SIZE; g++) {
            int64_t line = 0;
            int64_t line_r = 0;
            int64_t line_g = 0;
            int64_t line_b = 0;
            double line_sq = 0.0;
            for (int64_t b = 1; b < MOMENT_SIZE; b++) {
                const int64_t here = at3(r, g, b);
                line += m.count[here];
                line_r += m.sum_r[here];
                line_g += m.sum_g[here];
                line_b += m.sum_b[here];
                line_sq += m.sum_sq[here];
                area[b] += line;
                area_r[b] += line_r;
                area_g[b] += line_g;
                area_b[b] += line_b;
                area_sq[b] += line_sq;
                const int64_t below = at3(r - 1, g, b);
                m.count[here] = m.count[below] + area[b];
                m.sum_r[here] = m.sum_r[below] + area_r[b];
                m.sum_g[here] = m.sum_g[below] + area_g[b];
                m.sum_b[here] = m.sum_b[below] + area_b[b];
                m.sum_sq[here] = m.sum_sq[below] + area_sq[b];
            }
        }
    }
    return counted;
}

// Starts with one box holding every color and repeatedly splits whichever still holds the
// most error, until there are as many boxes as colors asked for. Each box's mean is one
// palette entry.
//
// Answers with the number of colors actually made, which can be fewer than asked for: an
// image holding three colors cannot be given sixteen.
int64_t build_palette(const Moments &m, int64_t wanted, uint8_t *out_r, uint8_t *out_g,
        uint8_t *out_b) {
    std::vector<Box> cube(static_cast<size_t>(wanted));
    std::vector<double> left(static_cast<size_t>(wanted), 0.0);

    cube[0].r1 = GRID_SIZE;
    cube[0].g1 = GRID_SIZE;
    cube[0].b1 = GRID_SIZE;
    cube[0].volume = GRID_SIZE * GRID_SIZE * GRID_SIZE;

    int64_t made = 1;
    int64_t next = 0;
    while (made < wanted) {
        if (cut_box(m, cube[next], cube[made])) {
            left[next] = cube[next].volume > 1 ? variance(m, cube[next]) : 0.0;
            left[made] = cube[made].volume > 1 ? variance(m, cube[made]) : 0.0;
            made++;
        } else {
            // Nothing in it left to split, so zero keeps it from being picked again.
            left[next] = 0.0;
        }

        next = 0;
        double most = left[0];
        for (int64_t k = 1; k < made; k++) {
            if (left[k] > most) {
                most = left[k];
                next = k;
            }
        }
        if (most <= 0.0) {
            break;
        }
    }

    for (int64_t k = 0; k < made; k++) {
        const int64_t weight = vol_i(m.count, cube[k]);
        if (weight <= 0) {
            out_r[k] = 0;
            out_g[k] = 0;
            out_b[k] = 0;
            continue;
        }
        const double share = 1.0 / static_cast<double>(weight);
        out_r[k] = static_cast<uint8_t>(iw::clampf(
                static_cast<double>(iw::roundi(vol_i(m.sum_r, cube[k]) * share)), 0.0, 255.0));
        out_g[k] = static_cast<uint8_t>(iw::clampf(
                static_cast<double>(iw::roundi(vol_i(m.sum_g, cube[k]) * share)), 0.0, 255.0));
        out_b[k] = static_cast<uint8_t>(iw::clampf(
                static_cast<double>(iw::roundi(vol_i(m.sum_b, cube[k]) * share)), 0.0, 255.0));
    }
    return made;
}

// The fixed ladder, one entry per byte, so no pixel pays for the divide. 0 lands on 0 and
// 255 lands on 255 at every setting, which is what keeps black black and white white.
void build_ladder(int64_t levels, std::vector<uint8_t> &ladder) {
    ladder.assign(256, 0);
    const double top_step = static_cast<double>(levels - 1);
    for (int64_t v = 0; v < 256; v++) {
        const int64_t step = iw::roundi(static_cast<double>(v) / 255.0 * top_step);
        ladder[static_cast<size_t>(v)] = static_cast<uint8_t>(
                iw::roundi(static_cast<double>(step) / top_step * 255.0));
    }
}

// Which palette entry is closest to one color, asked directly.
int64_t nearest(const uint8_t *pr, const uint8_t *pg, const uint8_t *pb, int64_t size,
        int64_t r, int64_t g, int64_t b) {
    int64_t best = 0;
    int64_t apart = FAR_APART;
    for (int64_t k = 0; k < size; k++) {
        const int64_t dr = r - pr[k];
        const int64_t dg = g - pg[k];
        const int64_t db = b - pb[k];
        const int64_t away = dr * dr + dg * dg + db * db;
        if (away < apart) {
            apart = away;
            best = k;
        }
    }
    return best;
}

// The nearest palette color for every cell of the same cube the counting used, measured at
// the cell's middle. That is one search per cell rather than per pixel: at 256 colors,
// eight million comparisons once instead of 256 for every pixel in the region.
void build_inverse(const uint8_t *pr, const uint8_t *pg, const uint8_t *pb,
        int64_t palette_size, std::vector<uint8_t> &inverse) {
    inverse.assign(static_cast<size_t>(GRID_SIZE * GRID_SIZE * GRID_SIZE), 0);
    for (int64_t r = 0; r < GRID_SIZE; r++) {
        for (int64_t g = 0; g < GRID_SIZE; g++) {
            for (int64_t b = 0; b < GRID_SIZE; b++) {
                inverse[static_cast<size_t>((r * GRID_SIZE + g) * GRID_SIZE + b)] =
                        static_cast<uint8_t>(nearest(pr, pg, pb, palette_size,
                                r * 8 + 4, g * 8 + 4, b * 8 + 4));
            }
        }
    }
}

// One set of colors and, when the region was big enough to earn one, the table that finds
// the nearest of them quickly. Per tile there is one of these per tile.
struct Palette {
    uint8_t r[MAX_COLORS] = {};
    uint8_t g[MAX_COLORS] = {};
    uint8_t b[MAX_COLORS] = {};
    int64_t size = 0;
    std::vector<uint8_t> inverse;
};

// One place a color is turned into the color that replaces it, whichever palette is in
// play. The dither loop is the only loop, so every pairing of palette, dither and per-tile
// comes out as one code path.
struct Snapper {
    const uint8_t *ladder = nullptr;
    const Palette *palette = nullptr;

    void snap(double r, double g, double b, int64_t out[3]) const {
        const int64_t ir = iw::roundi(iw::clampf(r, 0.0, 255.0));
        const int64_t ig = iw::roundi(iw::clampf(g, 0.0, 255.0));
        const int64_t ib = iw::roundi(iw::clampf(b, 0.0, 255.0));
        if (ladder != nullptr) {
            out[0] = ladder[ir];
            out[1] = ladder[ig];
            out[2] = ladder[ib];
            return;
        }
        int64_t k = 0;
        if (!palette->inverse.empty()) {
            k = palette->inverse[static_cast<size_t>(
                    ((ir >> 3) * GRID_SIZE + (ig >> 3)) * GRID_SIZE + (ib >> 3))];
        } else {
            k = nearest(palette->r, palette->g, palette->b, palette->size, ir, ig, ib);
        }
        out[0] = palette->r[k];
        out[1] = palette->g[k];
        out[2] = palette->b[k];
    }
};

void add_error(double *row, int64_t x, double share, double er, double eg, double eb) {
    const int64_t to = x * 3;
    row[to] += er * share;
    row[to + 1] += eg * share;
    row[to + 2] += eb * share;
}

} // namespace

// Cuts the image down to a small set of colors.
//
// See the declaration in iw_stage_kernels.h for what the modes mean and what is left
// alone. The palettes are built up front and the pixels are written in one pass, which is
// why the caller owes the run a full rebuild of the distance map.
void IWStageKernels::posterize(const Ref<IWPipelineContext> &ctx, int64_t palette_mode,
        int64_t levels, int64_t color_count, bool per_tile, int64_t dither_mode,
        double dither_strength) {
    ERR_FAIL_COND(ctx.is_null());
    if (ctx->pixel_count <= 0) {
        return;
    }

    const int64_t width = ctx->width;
    const int64_t height = ctx->height;
    const int64_t pixel_count = ctx->pixel_count;
    if (width <= 0 || height <= 0) {
        return;
    }

    const PackedFloat32Array visible = ctx->final_alpha();
    if (visible.size() != pixel_count) {
        return;
    }
    const float *alpha = visible.ptr();

    // The two modes arrive as plain integers and nothing clamps them on the way in: the
    // schema only pulls numbers back into range, so a hand-edited file can carry anything.
    // Whatever is not recognised falls through to the safe answer.
    const bool best_colors = palette_mode == PALETTE_BEST;
    const bool floyd = dither_mode == DITHER_FLOYD;
    levels = iw::mini(iw::maxi(levels, MIN_LEVELS), MAX_LEVELS);
    color_count = iw::mini(iw::maxi(color_count, MIN_COLORS), MAX_COLORS);

    // A fixed ladder is the same everywhere by definition, so asking for it per tile is
    // asking for nothing. Only a palette read off the image can differ from tile to tile.
    const bool by_tile = best_colors && per_tile;

    uint8_t *data = ctx->data.ptrw();

    std::vector<uint8_t> ladder;
    std::vector<Palette> palettes;
    std::vector<Snapper> snappers;
    const int32_t *label = nullptr;
    iw::Islands found;

    if (!best_colors) {
        build_ladder(levels, ladder);
        snappers.resize(1);
        snappers[0].ladder = ladder.data();
    } else {
        Moments moments;
        if (by_tile) {
            found = iw::label_islands(alpha, width, height);
            const int64_t island_count = found.count();
            if (island_count <= 0) {
                // Not one object anywhere, so there is nothing to give a palette to.
                return;
            }
            label = found.label.data();
            palettes.resize(static_cast<size_t>(island_count));
            for (int64_t n = 0; n < island_count; n++) {
                const int64_t counted = build_moments(data, alpha, label,
                        static_cast<int32_t>(n), width, found.min_x[n], found.min_y[n],
                        found.max_x[n], found.max_y[n], moments);
                if (counted <= 0) {
                    continue;
                }
                Palette &palette = palettes[static_cast<size_t>(n)];
                palette.size = build_palette(moments, color_count, palette.r, palette.g,
                        palette.b);
                if (counted > TABLE_WORTH_IT) {
                    build_inverse(palette.r, palette.g, palette.b, palette.size,
                            palette.inverse);
                }
            }
        } else {
            palettes.resize(1);
            Palette &palette = palettes[0];
            const int64_t counted = build_moments(data, alpha, nullptr, 0, width,
                    0, 0, width - 1, height - 1, moments);
            if (counted <= 0) {
                // Not one solid pixel anywhere, so there is no palette to build and
                // nothing worth guessing at.
                return;
            }
            palette.size = build_palette(moments, color_count, palette.r, palette.g,
                    palette.b);
            if (counted > TABLE_WORTH_IT) {
                build_inverse(palette.r, palette.g, palette.b, palette.size,
                        palette.inverse);
            }
        }

        snappers.resize(palettes.size());
        for (size_t n = 0; n < palettes.size(); n++) {
            snappers[n].palette = &palettes[n];
        }
    }

    const double spread = floyd ? iw::clampf(dither_strength, 0.0, 1.0) : 0.0;

    // Two rows of leftover color rather than one for the whole image: at four thousand
    // pixels wide a row is under a hundred kilobytes, where a whole-image buffer on a large
    // sheet would run to hundreds of megabytes. Nothing writes to them while `spread` is
    // zero, so they stay zero and the reads below cost nothing.
    std::vector<double> row_here(static_cast<size_t>(width * 3), 0.0);
    std::vector<double> row_next(static_cast<size_t>(width * 3), 0.0);
    double *here = row_here.data();
    double *below_row = row_next.data();

    for (int64_t y = 0; y < height; y++) {
        if (spread > 0.0) {
            for (int64_t i = 0; i < width * 3; i++) {
                below_row[i] = 0.0;
            }
        }

        // Alternate rows run backwards. It costs one sign and it clears the diagonal worm
        // pattern that always going left to right leaves across a smooth gradient, which is
        // the one thing dithering is reached for.
        const bool leftward = (y & 1) != 0;
        const int64_t step = leftward ? -1 : 1;
        const int64_t start = leftward ? width - 1 : 0;

        for (int64_t n = 0; n < width; n++) {
            const int64_t x = start + n * step;
            const int64_t i = y * width + x;
            if (iw::widen(alpha[i]) <= 0.0) {
                continue;
            }

            // Per tile, a pixel is coloured out of its own object's palette. A visible
            // pixel no object claimed is a speck too faint to have a solid middle
            // anywhere, so there is no palette it belongs to and it is left as it is —
            // the same answer RandomHSVTiles gives the same pixels.
            int64_t which = 0;
            if (label != nullptr) {
                if (label[i] < 0 || palettes[static_cast<size_t>(label[i])].size <= 0) {
                    continue;
                }
                which = label[i];
            }
            const Snapper &snapper = snappers[static_cast<size_t>(which)];

            const int64_t at = i * 4;
            const int64_t e = x * 3;
            const double r = static_cast<double>(data[at]) + here[e];
            const double g = static_cast<double>(data[at + 1]) + here[e + 1];
            const double b = static_cast<double>(data[at + 2]) + here[e + 2];

            int64_t out[3] = { 0, 0, 0 };
            snapper.snap(r, g, b, out);
            data[at] = static_cast<uint8_t>(out[0]);
            data[at + 1] = static_cast<uint8_t>(out[1]);
            data[at + 2] = static_cast<uint8_t>(out[2]);

            if (spread <= 0.0) {
                continue;
            }
            const double er = (r - static_cast<double>(out[0])) * spread;
            const double eg = (g - static_cast<double>(out[1])) * spread;
            const double eb = (b - static_cast<double>(out[2])) * spread;

            // A share that would land on a pixel nobody can see is dropped rather than
            // handed to someone else. Passing it on would keep the total right but pile it
            // up along every outline, which shows as a bright or dark rim.
            const int64_t ahead_x = x + step;
            const bool ahead_in = ahead_x >= 0 && ahead_x < width;
            if (ahead_in && iw::widen(alpha[i + step]) > 0.0) {
                add_error(here, ahead_x, 7.0 / 16.0, er, eg, eb);
            }
            if (y + 1 < height) {
                const int64_t below = i + width;
                const int64_t back_x = x - step;
                if (back_x >= 0 && back_x < width && iw::widen(alpha[below - step]) > 0.0) {
                    add_error(below_row, back_x, 3.0 / 16.0, er, eg, eb);
                }
                if (iw::widen(alpha[below]) > 0.0) {
                    add_error(below_row, x, 5.0 / 16.0, er, eg, eb);
                }
                if (ahead_in && iw::widen(alpha[below + step]) > 0.0) {
                    add_error(below_row, ahead_x, 1.0 / 16.0, er, eg, eb);
                }
            }
        }

        double *swap = here;
        here = below_row;
        below_row = swap;
    }
}
