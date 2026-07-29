#include "iw_stage_kernels.h"

#include "iw_math.h"

#include <cmath>
#include <vector>

using namespace godot;

namespace {

// Guards the divide that turns a distance into a strength, for the one setting where
// the denominator legitimately collapses: at a sharpness of 1 the feather has no width
// at all. The branch above it already handles that case, so this only has to stop the
// unreachable arm being a division by zero.
constexpr double FEATHER_EPSILON = 0.0001;

// Where a stroke's stamps land, and how strongly.
//
// A pixel is inside the brush when its centre is within `reach` of the stamp's, and
// `reach` is half a pixel short of the radius on purpose: it makes a radius of 1 a
// single pixel rather than a five-pixel cross, so the smallest brush is the pencil
// everybody expects it to be. Radius 2 is then 3 across, radius 3 is 5, and so on.
//
// Inside `inner` the brush is solid; from there out to `reach` it ramps linearly to
// nothing. Sharpness is what sets `inner` as a share of `reach` — at 1 the two meet and
// the edge is hard, at 0 the ramp runs the whole way from the centre. The centre pixel
// is solid at every setting, which is what keeps a one-pixel brush usable at any
// sharpness.
struct Stamp {
    double reach = 0.5;
    double inner = 0.5;

    double strength_at(double distance) const {
        if (distance > reach) {
            return 0.0;
        }
        if (distance <= inner) {
            return 1.0;
        }
        return (reach - distance) / iw::maxf(reach - inner, FEATHER_EPSILON);
    }
};

} // namespace

// Lays down every stroke, in the order they were drawn.
//
// [b]The strokes arrive flattened[/b] — `points` is x,y interleaved across every stroke,
// `starts` and `counts` say where each one's samples begin and how many there are, and
// `radii`, `adding` and `sharpness` carry one value per stroke. The usual reason: reading
// a BrushStroke Resource once per pixel would cost more than the painting does.
//
// [b]The samples are the path, not the pixels.[/b] What the dock records is wherever the
// pointer was seen, which on a fast drag skips: the gap between two samples is walked a
// pixel at a time here and the brush is stamped at every step, so a stroke is continuous
// however quickly it was made. Bresenham, so each pixel of the line is visited once.
//
// [b]Within one stroke the stamps combine by taking the strongest[/b], rather than adding
// up. A stroke has one opacity, and dragging slowly — which lands twenty overlapping
// stamps on the same pixel instead of two — must not come out darker than dragging fast.
// Between strokes it is the opposite: each one is applied to whatever the ones above it
// left, so a Subtract stroke bites into an earlier Add exactly as a brush should.
//
// [b]What a stroke does to a pixel is a lerp of the alpha it found there.[/b] Add moves it
// towards solid by the stamp's strength, Subtract towards clear by the same amount, so the
// soft rim of a stroke is a partial move rather than a partial choice. At full strength
// both are absolute, which is what makes the middle of a hard-edged stroke either wholly
// there or wholly gone.
//
// The result is written as the coverage, with the source alpha forced to 255 under it, so
// that what the pixel ends up showing is exactly what was painted — the source's own
// transparency can no longer scale it down. force_opaque is cleared where a stroke lands,
// since a region declared solid elsewhere would otherwise overrule the paint.
//
// Returns every index it touched. Colour is never read and never written; the caller owes
// the run a rebuild_nearest, and deliberately not a distance-map rebuild, because the keys
// are measured against RGB and this moves none of it.
PackedInt32Array IWStageKernels::paint_strokes(
        const Ref<IWPipelineContext> &ctx,
        const PackedInt32Array &points,
        const PackedInt32Array &starts,
        const PackedInt32Array &counts,
        const PackedInt32Array &radii,
        const PackedByteArray &adding,
        const PackedFloat64Array &sharpness) {
    PackedInt32Array touched;
    ERR_FAIL_COND_V(ctx.is_null(), touched);
    const int64_t stroke_count = starts.size();
    if (ctx->pixel_count <= 0 || stroke_count <= 0) {
        return touched;
    }
    if (counts.size() < stroke_count || radii.size() < stroke_count
            || adding.size() < stroke_count || sharpness.size() < stroke_count) {
        return touched;
    }

    const int64_t width = ctx->width;
    const int64_t height = ctx->height;
    const int64_t pixel_count = ctx->pixel_count;

    // The alpha the run currently shows, taken once and then painted into. Every stroke
    // reads what the ones above it left here rather than reaching back into the buffers,
    // which is what lets them stack in order without a write-back between each.
    PackedFloat32Array alpha = ctx->final_alpha();
    if (alpha.size() != pixel_count) {
        return touched;
    }
    float *shown = alpha.ptrw();

    // The current stroke's strength per pixel, with a stamp saying which stroke last
    // wrote each one. Stamped rather than cleared, since clearing it per stroke would
    // cost a pass over the image for every dab in a sketch.
    std::vector<float> strength(static_cast<size_t>(pixel_count), 0.0f);
    std::vector<int32_t> stroke_of(static_cast<size_t>(pixel_count), -1);
    // Which pixels any stroke has reached, so the write-back at the end visits each once.
    std::vector<uint8_t> painted(static_cast<size_t>(pixel_count), 0);
    std::vector<int32_t> reached;

    const int32_t *point_ptr = points.ptr();
    const int32_t *start_ptr = starts.ptr();
    const int32_t *count_ptr = counts.ptr();
    const int32_t *radius_ptr = radii.ptr();
    const uint8_t *adding_ptr = adding.ptr();
    const double *sharp_ptr = sharpness.ptr();

    for (int64_t s = 0; s < stroke_count; s++) {
        const int64_t first = start_ptr[s];
        const int64_t sample_count = count_ptr[s];
        if (sample_count <= 0 || first < 0 || (first + sample_count) * 2 > points.size()) {
            continue;
        }

        Stamp stamp;
        stamp.reach = static_cast<double>(iw::maxi(radius_ptr[s], 1)) - 0.5;
        stamp.inner = stamp.reach * iw::clampf(sharp_ptr[s], 0.0, 1.0);
        const bool is_adding = adding_ptr[s] != 0;
        const int32_t here = static_cast<int32_t>(s);
        const int64_t radius = iw::maxi(radius_ptr[s], 1);
        reached.clear();

        // Marks one pixel as reached by this stroke and keeps the strongest stamp that
        // has landed on it. A lambda rather than the macro its neighbours in this port
        // use, because the stamping loop below already owns names it would shadow.
        const auto mark = [&](int64_t index, double value) {
            if (value <= 0.0) {
                return;
            }
            const int32_t at = static_cast<int32_t>(index);
            if (stroke_of[at] != here) {
                stroke_of[at] = here;
                strength[at] = 0.0f;
                reached.push_back(at);
            }
            if (value > iw::widen(strength[at])) {
                strength[at] = iw::narrow(value);
            }
        };

        // One dab of the brush, centred on a pixel. Bounded by its own box rather than
        // by the image, so a small brush on a large sheet costs what it looks like.
        const auto dab = [&](int64_t cx, int64_t cy) {
            const int64_t first_col = iw::maxi(cx - radius, 0);
            const int64_t last_col = iw::mini(cx + radius, width - 1);
            const int64_t first_row = iw::maxi(cy - radius, 0);
            const int64_t last_row = iw::mini(cy + radius, height - 1);
            for (int64_t y = first_row; y <= last_row; y++) {
                const double dy = static_cast<double>(y - cy);
                for (int64_t x = first_col; x <= last_col; x++) {
                    const double dx = static_cast<double>(x - cx);
                    mark(y * width + x, stamp.strength_at(std::sqrt(dx * dx + dy * dy)));
                }
            }
        };

        // A one-sample stroke is a click, and a click is one dab. Everything longer is
        // walked segment by segment.
        int64_t from_x = point_ptr[first * 2];
        int64_t from_y = point_ptr[first * 2 + 1];
        dab(from_x, from_y);
        for (int64_t n = 1; n < sample_count; n++) {
            const int64_t to_x = point_ptr[(first + n) * 2];
            const int64_t to_y = point_ptr[(first + n) * 2 + 1];

            // Bresenham, in the form that handles every octant without a special case.
            // The starting pixel is skipped rather than re-dabbed: the previous segment
            // already laid it down, and a dab is idempotent anyway since stamps combine
            // by taking the strongest.
            int64_t x = from_x;
            int64_t y = from_y;
            const int64_t step_x = to_x >= x ? 1 : -1;
            const int64_t step_y = to_y >= y ? 1 : -1;
            const int64_t span_x = (to_x >= x ? to_x - x : x - to_x);
            const int64_t span_y = -(to_y >= y ? to_y - y : y - to_y);
            int64_t error = span_x + span_y;
            while (x != to_x || y != to_y) {
                const int64_t doubled = error * 2;
                if (doubled >= span_y) {
                    error += span_y;
                    x += step_x;
                }
                if (doubled <= span_x) {
                    error += span_x;
                    y += step_y;
                }
                dab(x, y);
            }
            from_x = to_x;
            from_y = to_y;
        }

        // Applied once the whole stroke is known, so that what a pixel gets is the
        // stroke's strongest stamp rather than each dab in turn.
        for (size_t r = 0; r < reached.size(); r++) {
            const int32_t index = reached[r];
            const double value = iw::widen(strength[index]);
            if (value <= 0.0) {
                continue;
            }
            const double was = iw::widen(shown[index]);
            shown[index] = iw::narrow(iw::clampf(
                    iw::lerpf(was, is_adding ? 1.0 : 0.0, value), 0.0, 1.0));
            if (painted[index] == 0) {
                painted[index] = 1;
                touched.push_back(index);
            }
        }
    }

    if (touched.is_empty()) {
        return touched;
    }

    // One write-back for every stroke at once. The coverage carries the answer and the
    // source alpha is forced solid under it, so nothing left of the original transparency
    // can scale down what was painted.
    ctx->ensure_coverage();
    float *cov = ctx->coverage.ptrw();
    uint8_t *data = ctx->data.ptrw();
    const bool has_force = ctx->force_opaque.size() == pixel_count;
    uint8_t *force = has_force ? ctx->force_opaque.ptrw() : nullptr;
    const bool has_mask = ctx->mask.size() == pixel_count && ctx->key_of.size() == pixel_count;
    uint8_t *mask = has_mask ? ctx->mask.ptrw() : nullptr;
    int32_t *key_of = has_mask ? ctx->key_of.ptrw() : nullptr;

    const int32_t *touched_ptr = touched.ptr();
    for (int64_t t = 0; t < touched.size(); t++) {
        const int32_t index = touched_ptr[t];
        const double value = iw::widen(shown[index]);
        cov[index] = iw::narrow(value);
        if (value > 0.0) {
            data[static_cast<int64_t>(index) * 4 + 3] = 255;
        }
        // A region declared solid elsewhere would otherwise overrule the paint, and a
        // stroke the user has just drawn is the more recent instruction of the two.
        if (has_force) {
            force[index] = 0;
        }
        // Left classed as it was, a painted pixel would be handed back to the coverage
        // maths by anything below that recomputes, and the stroke would come undone.
        if (has_mask) {
            if (value >= 1.0) {
                mask[index] = IWPipelineContext::MASK_SUBJECT;
                key_of[index] = IWPipelineContext::KEY_NONE;
            } else if (value <= 0.0) {
                mask[index] = IWPipelineContext::MASK_BACKGROUND;
                key_of[index] = IWPipelineContext::KEY_CLEAR;
            } else {
                mask[index] = IWPipelineContext::MASK_EDGE;
            }
        }
    }

    return touched;
}
