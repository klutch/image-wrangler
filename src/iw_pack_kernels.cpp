#include "iw_stage_kernels.h"

#include "iw_islands.h"
#include "iw_math.h"

using namespace godot;

// Every separate object in the image, as the smallest rectangle round each.
//
// What Repack lifts its sprites out of. The labelling is iw::label_islands, which is the
// same code RandomHSVTiles finds its tiles with — see the note there for what counts as
// one object and why.
//
// [b]The alpha the run currently shows, not the source's own.[/b] So a sheet whose
// background has been keyed out gives one sprite per object, and the same sheet untouched
// gives one sprite that is the whole image. Where this is asked from decides what it
// finds, which is the same rule every other stage that reads alpha follows.
//
// Returns x, y, w, h per island, in the order they were found: top to bottom by their
// first solid pixel, then left to right. Reads nothing else and writes nothing at all.
PackedInt32Array IWStageKernels::find_islands(const Ref<IWPipelineContext> &ctx) {
    PackedInt32Array bounds;
    ERR_FAIL_COND_V(ctx.is_null(), bounds);
    const int64_t pixel_count = ctx->pixel_count;
    if (pixel_count <= 0) {
        return bounds;
    }

    const PackedFloat32Array visible = ctx->final_alpha();
    if (visible.size() != pixel_count) {
        return bounds;
    }

    const iw::Islands found = iw::label_islands(visible.ptr(), ctx->width, ctx->height);
    const int64_t count = found.count();
    if (count <= 0) {
        return bounds;
    }

    bounds.resize(count * 4);
    int32_t *out = bounds.ptrw();
    for (int64_t n = 0; n < count; n++) {
        out[n * 4] = found.min_x[n];
        out[n * 4 + 1] = found.min_y[n];
        out[n * 4 + 2] = found.max_x[n] - found.min_x[n] + 1;
        out[n * 4 + 3] = found.max_y[n] - found.min_y[n] + 1;
    }
    return bounds;
}

// Every island lifted out on its own, one image each, at the size of its own rectangle.
//
// [b]Cut to the island rather than cropped to its box.[/b] Two objects that interlock have
// overlapping bounding boxes — a claw round a branch, a leaf across a stem — so a sprite
// taken as a rectangle carries a slice of its neighbour along with it, and that slice then
// turns up somewhere else on the packed sheet with nothing to explain it. Every pixel here
// is tested against the label that claimed it, and anything belonging to another island,
// or to none, comes out transparent.
//
// The colours are the run's own; only the alpha is masked. A pixel that is part of the
// island keeps whatever alpha it had, so an antialiased fringe survives being packed —
// which is what makes the fringe worth labelling in the first place.
//
// Returns one RGBA8 image per island, in the same order as find_islands' rectangles.
TypedArray<Image> IWStageKernels::cut_islands(const Ref<IWPipelineContext> &ctx) {
    TypedArray<Image> sprites;
    ERR_FAIL_COND_V(ctx.is_null(), sprites);
    const int64_t pixel_count = ctx->pixel_count;
    if (pixel_count <= 0) {
        return sprites;
    }

    const PackedFloat32Array visible = ctx->final_alpha();
    if (visible.size() != pixel_count) {
        return sprites;
    }

    const int64_t width = ctx->width;
    const int64_t height = ctx->height;
    const iw::Islands found = iw::label_islands(visible.ptr(), width, height);
    const int64_t count = found.count();
    if (count <= 0) {
        return sprites;
    }

    const uint8_t *src = ctx->data.ptr();
    const float *alpha = visible.ptr();
    sprites.resize(count);

    for (int64_t n = 0; n < count; n++) {
        const int64_t left = found.min_x[n];
        const int64_t top = found.min_y[n];
        const int64_t span = found.max_x[n] - left + 1;
        const int64_t rows = found.max_y[n] - top + 1;

        PackedByteArray data;
        data.resize(span * rows * 4);
        data.fill(0);
        uint8_t *out = data.ptrw();

        for (int64_t y = 0; y < rows; y++) {
            const int64_t row = (top + y) * width;
            for (int64_t x = 0; x < span; x++) {
                const int64_t from = row + left + x;
                if (found.label[from] != n) {
                    continue;
                }
                const int64_t to = (y * span + x) * 4;
                out[to] = src[from * 4];
                out[to + 1] = src[from * 4 + 1];
                out[to + 2] = src[from * 4 + 2];
                // The alpha the run shows, not the source byte: a pixel the stack faded
                // has to arrive on the sheet as faded as it looked.
                out[to + 3] = static_cast<uint8_t>(
                        iw::roundi(iw::clampf(iw::widen(alpha[from]), 0.0, 1.0) * 255.0));
            }
        }

        sprites[n] = Image::create_from_data(span, rows, false, Image::FORMAT_RGBA8, data);
    }

    return sprites;
}
