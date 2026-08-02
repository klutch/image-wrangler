#include "iw_stage_kernels.h"

#include "iw_islands.h"
#include "iw_math.h"

#include <godot_cpp/classes/image.hpp>

#include <cstring>
#include <vector>

using namespace godot;

namespace {

// How far past its visible pixels a tile reaches, in pixels. Covers the keyed-out halo
// round a sprite, which is invisible when the tiles are labelled but can be lifted back
// into view by a stage below.
constexpr int64_t TILE_MARGIN = 1;

// Clears every pixel in `doomed` and retires whatever the stages above declared for it.
//
// The second half is the ordering rule: a declaration is a record of what some stage
// above said, folded into the result where that stage sits, so a stage below that settles
// these pixels has to retire the record too. clear_regions_at covers the drawn regions,
// the forced opacity and the outline in one call.
void erase_pixels(const Ref<IWPipelineContext> &ctx, const PackedInt32Array &doomed) {
    if (doomed.is_empty()) {
        return;
    }
    const int64_t pixel_count = ctx->pixel_count;
    ctx->ensure_coverage();
    float *coverage = ctx->coverage.ptrw();
    // The mask can exist without the key list, so neither is assumed from the other.
    uint8_t *mask = ctx->has_classification() && ctx->mask.size() == pixel_count
            ? ctx->mask.ptrw()
            : nullptr;
    int32_t *key_of = mask != nullptr && ctx->key_of.size() == pixel_count
            ? ctx->key_of.ptrw()
            : nullptr;

    const int32_t *index_ptr = doomed.ptr();
    for (int64_t n = 0; n < doomed.size(); n++) {
        const int32_t i = index_ptr[n];
        coverage[i] = 0.0f;
        if (mask != nullptr) {
            mask[i] = IWPipelineContext::MASK_BACKGROUND;
        }
        if (key_of != nullptr) {
            // KEY_CLEAR rather than KEY_NONE. What this removes is gone outright, with no
            // colour left to un-blend against, so it must not be handed to the matte as
            // though some entry had claimed it. Same reasoning as a drawn cut.
            key_of[i] = IWPipelineContext::KEY_CLEAR;
        }
    }
    ctx->clear_regions_at(doomed);
}

// Labels every run of visible pixels, counting anything above zero alpha.
//
// Not iw::label_islands, and the difference is the whole point of this one. That labeller
// asks which pixels are one object, so it starts from the solid part and grows outwards,
// and a speck with no solid pixel anywhere is never labelled at all. Measuring area has no
// such question in it — a faint speck is exactly the thing worth measuring — so here every
// visible pixel seeds and joins alike.
//
// 8-connected, matching the other labeller, so two parts touching corner to corner are one
// thing in both.
iw::Islands label_visible(const float *alpha, int64_t width, int64_t height) {
    iw::Islands found;
    const int64_t pixel_count = width * height;
    if (alpha == nullptr || pixel_count <= 0) {
        return found;
    }

    found.label.assign(static_cast<size_t>(pixel_count), -1);
    std::vector<int32_t> &label = found.label;
    // Every pixel enters at most once, so this is a plain queue with no wraparound.
    std::vector<int32_t> queue(static_cast<size_t>(pixel_count), 0);
    int64_t head = 0;
    int64_t tail = 0;

    const auto claim = [&](int32_t index, int32_t island) {
        label[index] = island;
        const int32_t x = static_cast<int32_t>(index % width);
        const int32_t y = static_cast<int32_t>(index / width);
        if (x < found.min_x[island]) {
            found.min_x[island] = x;
        }
        if (x > found.max_x[island]) {
            found.max_x[island] = x;
        }
        if (y < found.min_y[island]) {
            found.min_y[island] = y;
        }
        if (y > found.max_y[island]) {
            found.max_y[island] = y;
        }
        queue[tail++] = index;
    };

    for (int64_t i = 0; i < pixel_count; i++) {
        if (label[i] >= 0 || iw::widen(alpha[i]) <= 0.0) {
            continue;
        }
        const int32_t here = static_cast<int32_t>(found.min_x.size());
        found.min_x.push_back(static_cast<int32_t>(i % width));
        found.max_x.push_back(found.min_x[here]);
        found.min_y.push_back(static_cast<int32_t>(i / width));
        found.max_y.push_back(found.min_y[here]);
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
                    if (label[n] < 0 && iw::widen(alpha[n]) > 0.0) {
                        claim(n, here);
                    }
                }
            }
        }
    }

    return found;
}

} // namespace

// RemoveMinimumArea.process_context.
//
// [b]Area is summed alpha, not counted pixels.[/b] A half-covered pixel is half a pixel of
// area, which is the honest answer for a speck made mostly of fringe — counting it whole
// would let a faint smudge pass for a solid block of the same width.
//
// Returns one rectangle per island removed, as x, y, w, h, for the preview to outline.
PackedInt32Array IWStageKernels::remove_minimum_area(
        const Ref<IWPipelineContext> &ctx, int64_t min_area) {
    PackedInt32Array bounds;
    ERR_FAIL_COND_V(ctx.is_null(), bounds);
    const int64_t pixel_count = ctx->pixel_count;
    if (pixel_count <= 0 || min_area <= 0) {
        return bounds;
    }

    const PackedFloat32Array visible = ctx->final_alpha();
    if (visible.size() != pixel_count) {
        return bounds;
    }

    const iw::Islands found = label_visible(visible.ptr(), ctx->width, ctx->height);
    const int64_t count = found.count();
    if (count <= 0) {
        return bounds;
    }

    std::vector<double> area(static_cast<size_t>(count), 0.0);
    const float *alpha = visible.ptr();
    for (int64_t i = 0; i < pixel_count; i++) {
        const int32_t island = found.label[static_cast<size_t>(i)];
        if (island >= 0) {
            area[static_cast<size_t>(island)] += iw::widen(alpha[i]);
        }
    }

    std::vector<uint8_t> doomed(static_cast<size_t>(count), 0);
    bool any = false;
    for (int64_t n = 0; n < count; n++) {
        if (area[static_cast<size_t>(n)] <= static_cast<double>(min_area)) {
            doomed[static_cast<size_t>(n)] = 1;
            any = true;
        }
    }
    if (!any) {
        return bounds;
    }

    // [b]A doomed shape takes its whole rectangle, grown by TILE_MARGIN.[/b] Everything
    // inside goes, whatever it is labelled: erasing only the doomed pixels leaves behind
    // whatever else was in the box — the keyed-out halo still holding alpha in the source,
    // and any faint fringe that counted as a shape of its own — as a rim round where the
    // shape was.
    const int64_t width = ctx->width;
    const int64_t height = ctx->height;
    std::vector<uint8_t> taken(static_cast<size_t>(pixel_count), 0);
    for (int64_t n = 0; n < count; n++) {
        if (doomed[static_cast<size_t>(n)] == 0) {
            continue;
        }
        const int64_t first_row = iw::maxi(found.min_y[n] - TILE_MARGIN, 0);
        const int64_t last_row = iw::mini(found.max_y[n] + TILE_MARGIN, height - 1);
        const int64_t first_col = iw::maxi(found.min_x[n] - TILE_MARGIN, 0);
        const int64_t last_col = iw::mini(found.max_x[n] + TILE_MARGIN, width - 1);
        for (int64_t y = first_row; y <= last_row; y++) {
            const int64_t row = y * width;
            for (int64_t x = first_col; x <= last_col; x++) {
                taken[static_cast<size_t>(row + x)] = 1;
            }
        }
    }

    PackedInt32Array going;
    for (int64_t i = 0; i < pixel_count; i++) {
        if (taken[static_cast<size_t>(i)] != 0) {
            going.push_back(static_cast<int32_t>(i));
        }
    }
    erase_pixels(ctx, going);

    // The source alpha goes too, for the reason exclude_tiles takes it: a stage below that
    // rebuilds coverage wholesale would otherwise grow the speck back out of the alpha
    // still sitting here. Colour is left alone for un-blending.
    uint8_t *pixels = ctx->data.ptrw();
    for (int64_t i = 0; i < pixel_count; i++) {
        if (taken[static_cast<size_t>(i)] != 0) {
            pixels[i * 4 + 3] = 0;
        }
    }

    for (int64_t n = 0; n < count; n++) {
        if (doomed[static_cast<size_t>(n)] == 0) {
            continue;
        }
        bounds.push_back(found.min_x[n]);
        bounds.push_back(found.min_y[n]);
        bounds.push_back(found.max_x[n] - found.min_x[n] + 1);
        bounds.push_back(found.max_y[n] - found.min_y[n] + 1);
    }
    return bounds;
}

// ExcludeTiles.process_context.
//
// [b]The tiles are the packer's sprites.[/b] iw::label_islands unchanged, so anything held
// back here is exactly one sprite Packing would have lifted out — except where two of them
// interlock, which is the next note.
//
// [b]Objects whose rectangles overlap are one tile.[/b] What this stage takes is a
// rectangle, so a pair whose rectangles share pixels cannot be separated: taking either
// would cut a bite out of the other. They are joined into a single tile with a single
// rectangle round the pair, and joining repeats until no two overlap.
//
// [b]Labelled before anything is removed.[/b] That is what keeps the picks stable: a tile
// this took out is still in the alpha handed to the next run, so the point that chose it
// still lands on it and it still gets an outline to click.
//
// [b]A tile is its whole rectangle.[/b] Everything inside a doomed tile's box goes,
// whatever its alpha, which is what the outlines and the picking already mean by a tile.
// Erasing only the labelled pixels leaves the unlabelled fringe behind as a faint rim.
// A pick is answered the same way, by the rectangle it lands in rather than by the pixel
// under it, so the empty parts of a box count as the tile just as the outline says.
//
// [b]A switched-off pick is still resolved.[/b] Every point is told which tile it landed
// on whether or not `active` counts it, so the dock keeps naming the tile under it.
//
// `points` is x,y interleaved, one pair per pick. `active` is one byte per pick, zero for
// one that is switched off; empty or short means the rest count. `mode` is 0 to remove
// what was picked and 1 to remove everything else. Returns the rectangle of every tile
// found under "bounds", and under "picked" which tile's rectangle each point landed in,
// or -1.
// "hidden" and "hidden_rect" carry a picture of what was taken, for the preview to ghost
// back in.
Dictionary IWStageKernels::exclude_tiles(
        const Ref<IWPipelineContext> &ctx, const PackedInt32Array &points,
        const PackedByteArray &active, int64_t mode) {
    Dictionary out;
    ERR_FAIL_COND_V(ctx.is_null(), out);
    out["bounds"] = PackedInt32Array();
    out["picked"] = PackedInt32Array();

    const int64_t pixel_count = ctx->pixel_count;
    if (pixel_count <= 0) {
        return out;
    }
    const PackedFloat32Array visible = ctx->final_alpha();
    if (visible.size() != pixel_count) {
        return out;
    }

    const int64_t width = ctx->width;
    const int64_t height = ctx->height;
    const iw::Islands found = iw::label_islands(visible.ptr(), width, height);
    const int64_t island_count = found.count();

    // An island's rectangle grown by TILE_MARGIN. Keying above this leaves a halo of
    // zero-coverage pixels round a sprite, invisible here and so no part of the tile, but
    // a stage below that rebuilds coverage lifts them back into view as a faint rim.
    // Their alpha is still in the source, so the margin is what reaches them.
    std::vector<int32_t> min_x(static_cast<size_t>(island_count));
    std::vector<int32_t> min_y(static_cast<size_t>(island_count));
    std::vector<int32_t> max_x(static_cast<size_t>(island_count));
    std::vector<int32_t> max_y(static_cast<size_t>(island_count));
    for (int64_t n = 0; n < island_count; n++) {
        min_x[n] = static_cast<int32_t>(iw::maxi(found.min_x[n] - TILE_MARGIN, 0));
        min_y[n] = static_cast<int32_t>(iw::maxi(found.min_y[n] - TILE_MARGIN, 0));
        max_x[n] = static_cast<int32_t>(iw::mini(found.max_x[n] + TILE_MARGIN, width - 1));
        max_y[n] = static_cast<int32_t>(iw::mini(found.max_y[n] + TILE_MARGIN, height - 1));
    }

    // [b]Islands whose rectangles share a pixel are one tile.[/b] A rectangle is what this
    // stage takes, so two objects that interlock cannot be told apart by one: holding
    // either back would cut a bite out of the other, and outlining them separately would
    // draw two boxes round one thing to click. Joined, they are one outline and one
    // rectangle that can be taken whole.
    //
    // Run to a standstill rather than in a single pass. A joined rectangle is larger than
    // either of the two it replaced, so it can reach a third that neither reached alone.
    std::vector<int32_t> parent(static_cast<size_t>(island_count));
    for (int64_t n = 0; n < island_count; n++) {
        parent[static_cast<size_t>(n)] = static_cast<int32_t>(n);
    }
    const auto root_of = [&parent](int32_t n) {
        while (parent[static_cast<size_t>(n)] != n) {
            const int32_t up = parent[static_cast<size_t>(n)];
            parent[static_cast<size_t>(n)] = parent[static_cast<size_t>(up)];
            n = parent[static_cast<size_t>(n)];
        }
        return n;
    };
    bool joined = true;
    while (joined) {
        joined = false;
        for (int64_t a = 0; a < island_count; a++) {
            if (root_of(static_cast<int32_t>(a)) != static_cast<int32_t>(a)) {
                continue;
            }
            for (int64_t b = a + 1; b < island_count; b++) {
                const int32_t here = root_of(static_cast<int32_t>(a));
                const int32_t there = root_of(static_cast<int32_t>(b));
                if (here == there || there != static_cast<int32_t>(b)) {
                    continue;
                }
                if (min_x[here] > max_x[there] || min_x[there] > max_x[here]
                        || min_y[here] > max_y[there] || min_y[there] > max_y[here]) {
                    continue;
                }
                // The lower index keeps the group, so the tiles stay in the order the
                // islands were found in and a tile's number goes on meaning what it meant.
                parent[static_cast<size_t>(there)] = here;
                min_x[here] = static_cast<int32_t>(iw::mini(min_x[here], min_x[there]));
                min_y[here] = static_cast<int32_t>(iw::mini(min_y[here], min_y[there]));
                max_x[here] = static_cast<int32_t>(iw::maxi(max_x[here], max_x[there]));
                max_y[here] = static_cast<int32_t>(iw::maxi(max_y[here], max_y[there]));
                joined = true;
            }
        }
    }

    // Numbered off the islands that kept their group, which is every tile exactly once.
    std::vector<int32_t> tile_of(static_cast<size_t>(island_count), -1);
    int64_t count = 0;
    for (int64_t n = 0; n < island_count; n++) {
        if (root_of(static_cast<int32_t>(n)) == static_cast<int32_t>(n)) {
            tile_of[static_cast<size_t>(n)] = static_cast<int32_t>(count++);
        }
    }
    std::vector<int32_t> tile_min_x(static_cast<size_t>(count));
    std::vector<int32_t> tile_min_y(static_cast<size_t>(count));
    std::vector<int32_t> tile_max_x(static_cast<size_t>(count));
    std::vector<int32_t> tile_max_y(static_cast<size_t>(count));
    for (int64_t n = 0; n < island_count; n++) {
        const int32_t root = root_of(static_cast<int32_t>(n));
        tile_of[static_cast<size_t>(n)] = tile_of[static_cast<size_t>(root)];
        if (root != static_cast<int32_t>(n)) {
            continue;
        }
        const size_t tile = static_cast<size_t>(tile_of[static_cast<size_t>(n)]);
        tile_min_x[tile] = min_x[n];
        tile_min_y[tile] = min_y[n];
        tile_max_x[tile] = max_x[n];
        tile_max_y[tile] = max_y[n];
    }

    PackedInt32Array bounds;
    bounds.resize(count * 4);
    int32_t *bounds_ptr = bounds.ptrw();
    for (int64_t n = 0; n < count; n++) {
        bounds_ptr[n * 4] = tile_min_x[n];
        bounds_ptr[n * 4 + 1] = tile_min_y[n];
        bounds_ptr[n * 4 + 2] = tile_max_x[n] - tile_min_x[n] + 1;
        bounds_ptr[n * 4 + 3] = tile_max_y[n] - tile_min_y[n] + 1;
    }
    out["bounds"] = bounds;

    // Which tile each pick landed in, by rectangle rather than by labelled pixel. The
    // rectangle is what the preview outlines and what this stage takes, so a click anywhere
    // inside one means that tile — including the gaps a shape leaves in its own box, which
    // a diagonal or a joined pair has plenty of. No two rectangles overlap by now, so the
    // first that contains the point is the only one that can.
    //
    // Points off the image, and points in no rectangle, resolve to -1 and are reported as
    // such rather than dropped — the row is still the user's and the dock says so.
    PackedInt32Array picked;
    const int64_t pick_count = points.size() / 2;
    picked.resize(pick_count);
    int32_t *picked_ptr = picked.ptrw();
    const int32_t *point_ptr = points.ptr();
    for (int64_t p = 0; p < pick_count; p++) {
        const int64_t x = point_ptr[p * 2];
        const int64_t y = point_ptr[p * 2 + 1];
        picked_ptr[p] = -1;
        if (x < 0 || y < 0 || x >= width || y >= height) {
            continue;
        }
        for (int64_t n = 0; n < count; n++) {
            if (x >= tile_min_x[n] && x <= tile_max_x[n]
                    && y >= tile_min_y[n] && y <= tile_max_y[n]) {
                picked_ptr[p] = static_cast<int32_t>(n);
                break;
            }
        }
    }
    out["picked"] = picked;

    if (count <= 0) {
        return out;
    }

    // Only the switched-on picks choose a tile. The rest have already been resolved above
    // and reported, which is all they are for while they are off.
    const int64_t active_count = active.size();
    const uint8_t *active_ptr = active_count > 0 ? active.ptr() : nullptr;
    std::vector<uint8_t> chosen(static_cast<size_t>(count), 0);
    for (int64_t p = 0; p < pick_count; p++) {
        if (active_ptr != nullptr && p < active_count && active_ptr[p] == 0) {
            continue;
        }
        if (picked_ptr[p] >= 0) {
            chosen[static_cast<size_t>(picked_ptr[p])] = 1;
        }
    }

    // Exclude takes what was chosen; Include takes everything else.
    std::vector<uint8_t> doomed(static_cast<size_t>(count), 0);
    bool any = false;
    for (int64_t n = 0; n < count; n++) {
        const bool go = mode == 0 ? chosen[static_cast<size_t>(n)] != 0
                                  : chosen[static_cast<size_t>(n)] == 0;
        doomed[static_cast<size_t>(n)] = go ? 1 : 0;
        any = any || go;
    }
    if (!any) {
        return out;
    }

    // Every pixel inside a doomed tile's rectangle, whatever its alpha.
    //
    // Nothing has to be spared back out of it: no two tiles share a pixel now, so a
    // rectangle on its way out cannot be holding any part of one that is staying.
    std::vector<uint8_t> taken(static_cast<size_t>(pixel_count), 0);
    for (int64_t n = 0; n < count; n++) {
        if (doomed[static_cast<size_t>(n)] == 0) {
            continue;
        }
        for (int64_t y = tile_min_y[n]; y <= tile_max_y[n]; y++) {
            const int64_t row = y * width;
            for (int64_t x = tile_min_x[n]; x <= tile_max_x[n]; x++) {
                taken[static_cast<size_t>(row + x)] = 1;
            }
        }
    }

    // A picture of what is about to go, taken before it goes. The preview lays this back
    // over the result faintly, so a tile held back is still visible as the thing it was
    // rather than as an empty rectangle.
    //
    // Cropped to what was taken rather than kept at the size of the image: a sheet of
    // forty tiles with one held back would otherwise carry a full-size picture that is
    // transparent almost everywhere.
    int64_t hidden_min_x = width;
    int64_t hidden_min_y = height;
    int64_t hidden_max_x = -1;
    int64_t hidden_max_y = -1;
    for (int64_t n = 0; n < count; n++) {
        if (doomed[static_cast<size_t>(n)] == 0) {
            continue;
        }
        hidden_min_x = iw::mini(hidden_min_x, static_cast<int64_t>(tile_min_x[n]));
        hidden_min_y = iw::mini(hidden_min_y, static_cast<int64_t>(tile_min_y[n]));
        hidden_max_x = iw::maxi(hidden_max_x, static_cast<int64_t>(tile_max_x[n]));
        hidden_max_y = iw::maxi(hidden_max_y, static_cast<int64_t>(tile_max_y[n]));
    }
    if (hidden_max_x >= hidden_min_x && hidden_max_y >= hidden_min_y) {
        const int64_t hidden_width = hidden_max_x - hidden_min_x + 1;
        const int64_t hidden_height = hidden_max_y - hidden_min_y + 1;
        PackedByteArray pixels;
        pixels.resize(hidden_width * hidden_height * 4);
        uint8_t *dst = pixels.ptrw();
        memset(dst, 0, static_cast<size_t>(pixels.size()));
        const uint8_t *src = ctx->data.ptr();
        const float *alpha = visible.ptr();
        for (int64_t y = 0; y < hidden_height; y++) {
            for (int64_t x = 0; x < hidden_width; x++) {
                const int64_t from = (y + hidden_min_y) * width + (x + hidden_min_x);
                if (taken[static_cast<size_t>(from)] == 0) {
                    continue;
                }
                const int64_t to = (y * hidden_width + x) * 4;
                dst[to] = src[from * 4];
                dst[to + 1] = src[from * 4 + 1];
                dst[to + 2] = src[from * 4 + 2];
                dst[to + 3] = static_cast<uint8_t>(
                        iw::roundi(iw::clampf(iw::widen(alpha[from]), 0.0, 1.0) * 255.0));
            }
        }
        out["hidden"] = Image::create_from_data(
                hidden_width, hidden_height, false, Image::FORMAT_RGBA8, pixels);
        out["hidden_rect"] = Rect2i(hidden_min_x, hidden_min_y, hidden_width, hidden_height);
    }

    PackedInt32Array going;
    for (int64_t i = 0; i < pixel_count; i++) {
        if (taken[static_cast<size_t>(i)] != 0) {
            going.push_back(static_cast<int32_t>(i));
        }
    }
    erase_pixels(ctx, going);

    // The source alpha goes too, not just the coverage. A stage below that rebuilds
    // coverage wholesale — guided_refine, restore_edges — would otherwise grow the tile
    // back out of the alpha still sitting here. Colour is left alone for un-blending.
    uint8_t *pixels = ctx->data.ptrw();
    for (int64_t i = 0; i < pixel_count; i++) {
        if (taken[static_cast<size_t>(i)] != 0) {
            pixels[i * 4 + 3] = 0;
        }
    }
    return out;
}
