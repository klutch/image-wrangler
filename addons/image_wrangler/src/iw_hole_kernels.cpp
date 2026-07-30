#include "iw_stage_kernels.h"

#include "iw_math.h"

#include <vector>

using namespace godot;

// Fills every enclosed patch of not-quite-solid pixels small enough to be damage rather
// than picture.
//
// [b]A hole is anything short of fully opaque, with solid image all the way round it.[/b]
// Not just the clear pixels: a speck usually arrives with a soft rim of its own, and a
// hole plugged up to its rim would leave a ring of half-alpha exactly where the damage
// was. So the flood crosses anything under full alpha, the whole patch counts toward the
// area, and the whole patch comes out solid.
//
// A patch that reaches any edge of the image is the outside — the background, the margin
// round a sprite, the space a keyer opened, and the subject's own antialiasing where that
// joins it — and is never touched, whatever its size. Only what is enclosed is a hole,
// which is what lets this run on a keyed sheet without filling in the very transparency
// the keyer was asked for.
//
// [b]4-connected, where the islands in random_hsv_tiles are 8-connected.[/b] The two
// questions are duals of one another and cannot both be answered the same way: if a
// diagonal chain of pixels counts as a joined-up object, then the transparency either side
// of it cannot also count as joined-up, or a shape and the hole it encloses would leak
// through each other. Corner to corner seals a hole here for the same reason it joins an
// object there.
//
// [b]The fill colour is the plain average of the solid pixels round the rim.[/b] Every
// fully opaque pixel touching the patch — 8-connected, so the corners of a square hole get
// a vote — counts once, however many of the hole's pixels it touches, so a hole's colour
// depends on what is around it rather than on its shape. Nothing under full alpha votes at
// all, and nothing needs to: a pixel that is part-transparent is part of the hole.
//
// The filled pixels are made solid: the source alpha goes to 255, and the coverage — if a
// stage above has established one — goes to 1. The rim is read from a snapshot of the
// alpha taken before anything was filled, so one hole's fill can never become another's
// rim, and the answer does not depend on which hole the scan reached first.
//
// Returns every index it filled. This rewrites the source pixels, so the caller owes the
// run a rebuild of the distance map, and it moves pixels from background to subject, so it
// owes a rebuild_nearest as well. A drawn Cut still has the last word in IWCompose, which
// is why a hole lying under one costs a fill and changes nothing.
PackedInt32Array IWStageKernels::fill_pinholes(
        const Ref<IWPipelineContext> &ctx, int64_t max_area) {
    PackedInt32Array filled;
    ERR_FAIL_COND_V(ctx.is_null(), filled);
    if (ctx->pixel_count <= 0 || max_area <= 0) {
        return filled;
    }

    const int64_t width = ctx->width;
    const int64_t height = ctx->height;
    const int64_t pixel_count = ctx->pixel_count;

    // The alpha the run currently shows, taken once. Everything below reads holes and rims
    // out of this rather than out of the buffers it is writing, which is what makes the
    // result independent of scan order.
    const PackedFloat32Array visible = ctx->final_alpha();
    if (visible.size() != pixel_count) {
        return filled;
    }
    const float *alpha = visible.ptr();

    const bool has_coverage = ctx->coverage.size() == pixel_count;
    const bool has_mask = ctx->mask.size() == pixel_count && ctx->key_of.size() == pixel_count;
    uint8_t *data = ctx->data.ptrw();
    float *cov = has_coverage ? ctx->coverage.ptrw() : nullptr;
    uint8_t *mask = has_mask ? ctx->mask.ptrw() : nullptr;
    int32_t *key_of = has_mask ? ctx->key_of.ptrw() : nullptr;

    // Each pixel enters the queue at most once across the whole scan — `seen` sees to that
    // — so it can be sized up front and used as a plain FIFO with no wraparound. The
    // head and tail are rewound per hole, which is safe for the same reason: a hole is
    // finished with before the next one starts.
    std::vector<uint8_t> seen(static_cast<size_t>(pixel_count), 0);
    std::vector<int32_t> queue(static_cast<size_t>(pixel_count), 0);
    // Which hole last counted each rim pixel, so a pixel touching three of a hole's pixels
    // still votes once. Stamped rather than cleared, since clearing it per hole would cost
    // a pass over the image for every speck in it.
    std::vector<int32_t> counted(static_cast<size_t>(pixel_count), -1);

    const double to_unit = 1.0 / 255.0;
    int32_t hole = 0;

    for (int64_t start = 0; start < pixel_count; start++) {
        if (seen[start] != 0 || iw::widen(alpha[start]) >= 1.0) {
            continue;
        }

        // 4-connected, and written out four times in the order the floods elsewhere use.
        seen[start] = 1;
        int64_t head = 0;
        int64_t tail = 0;
        queue[tail++] = static_cast<int32_t>(start);
        bool escapes = false;

        while (head < tail) {
            const int32_t index = queue[head++];
            const int64_t x = index % width;
            const int64_t y = index / width;
            if (x == 0 || y == 0 || x == width - 1 || y == height - 1) {
                escapes = true;
            }

#define IW_HOLE_NEIGHBOUR(m_n)                                     \
    {                                                              \
        const int32_t n = (m_n);                                   \
        if (seen[n] == 0 && iw::widen(alpha[n]) < 1.0) {           \
            seen[n] = 1;                                           \
            queue[tail++] = n;                                     \
        }                                                          \
    }

            if (x > 0) {
                IW_HOLE_NEIGHBOUR(index - 1)
            }
            if (x < width - 1) {
                IW_HOLE_NEIGHBOUR(index + 1)
            }
            if (y > 0) {
                IW_HOLE_NEIGHBOUR(index - static_cast<int32_t>(width))
            }
            if (y < height - 1) {
                IW_HOLE_NEIGHBOUR(index + static_cast<int32_t>(width))
            }
#undef IW_HOLE_NEIGHBOUR
        }

        // Transparency that got out is the outside, whatever its size, and a hole bigger
        // than the budget is being read as part of the picture.
        if (escapes || tail > max_area) {
            continue;
        }

        const int32_t stamp = hole++;
        double sum_r = 0.0;
        double sum_g = 0.0;
        double sum_b = 0.0;
        int64_t votes = 0;
        for (int64_t q = 0; q < tail; q++) {
            const int32_t index = queue[q];
            const int64_t x = index % width;
            const int64_t y = index / width;
            const int64_t first_row = iw::maxi(y - 1, 0);
            const int64_t last_row = iw::mini(y + 1, height - 1);
            const int64_t first_col = iw::maxi(x - 1, 0);
            const int64_t last_col = iw::mini(x + 1, width - 1);
            for (int64_t row = first_row; row <= last_row; row++) {
                for (int64_t col = first_col; col <= last_col; col++) {
                    const int32_t n = static_cast<int32_t>(row * width + col);
                    if (iw::widen(alpha[n]) < 1.0 || counted[n] == stamp) {
                        continue;
                    }
                    counted[n] = stamp;
                    const int64_t at = static_cast<int64_t>(n) * 4;
                    sum_r += data[at] * to_unit;
                    sum_g += data[at + 1] * to_unit;
                    sum_b += data[at + 2] * to_unit;
                    votes++;
                }
            }
        }
        // A hole with no solid pixel anywhere around it is an image with nothing solid in
        // it at all, which the border test has already caught — but a colour divided by
        // nothing is not worth risking on the strength of that.
        if (votes <= 0) {
            continue;
        }

        const double inverse = 1.0 / static_cast<double>(votes);
        const uint8_t red = static_cast<uint8_t>(
                iw::roundi(iw::clampf(sum_r * inverse, 0.0, 1.0) * 255.0));
        const uint8_t green = static_cast<uint8_t>(
                iw::roundi(iw::clampf(sum_g * inverse, 0.0, 1.0) * 255.0));
        const uint8_t blue = static_cast<uint8_t>(
                iw::roundi(iw::clampf(sum_b * inverse, 0.0, 1.0) * 255.0));

        for (int64_t q = 0; q < tail; q++) {
            const int32_t index = queue[q];
            const int64_t at = static_cast<int64_t>(index) * 4;
            data[at] = red;
            data[at + 1] = green;
            data[at + 2] = blue;
            data[at + 3] = 255;
            if (has_coverage) {
                cov[index] = 1.0f;
            }
            // It is part of the subject now. Left classed as background it would be handed
            // back to the coverage maths by anything below that recomputes, and the hole
            // would open again.
            if (has_mask) {
                mask[index] = IWPipelineContext::MASK_SUBJECT;
                key_of[index] = IWPipelineContext::KEY_NONE;
            }
            filled.push_back(index);
        }
    }

    return filled;
}
