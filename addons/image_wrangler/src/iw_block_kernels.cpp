#include "iw_stage_kernels.h"

#include "iw_math.h"

#include <vector>

using namespace godot;

namespace {

// JPEG works in squares of this many pixels, counted from the top-left corner of the
// image it was encoded from.
constexpr int64_t BLOCK = 8;

// How far either side of a seam a correction reaches.
//
// Three, so the corrections belonging to one seam and the next never meet — the seams are
// eight pixels apart, and three each side of two of them is six.
constexpr int64_t REACH = 3;

// Flattens one seam, in one channel, along one row or one column.
//
// `at` is the first pixel on the far side of the seam. `step` is the distance from one
// pixel to the next across it: three for a seam running down the image, a whole row for
// one running across it.
//
// The pixels either side are p and q, counting outwards from the seam:
//
//     p2 p1 p0 | q0 q1 q2
//
// Three things have to be true before anything moves. The step across has to be small,
// or this is a real edge that happens to land on a seam. Both sides have to be nearly
// flat, or this is detail, and detail is never a seam — a block's own contents survive
// quantising far better than the level it sits at. Only when all three hold is the step
// treated as the encoder's arithmetic rather than the image's own.
//
// The correction is a ramp rather than a step of its own: half the difference at the seam
// itself, tapering to nothing by the third pixel out. Closing the gap only at the two
// pixels touching it would trade one visible line for another.
void mend(float *values, int64_t at, int64_t step, double limit, double mix) {
    double p[REACH];
    double q[REACH];
    for (int64_t i = 0; i < REACH; i++) {
        p[i] = iw::widen(values[at - step * (i + 1)]);
        q[i] = iw::widen(values[at + step * i]);
    }

    const double difference = q[0] - p[0];
    if (iw::absf(difference) > limit) {
        return;
    }
    if (iw::absf(p[0] - p[1]) + iw::absf(p[1] - p[2]) > limit) {
        return;
    }
    if (iw::absf(q[0] - q[1]) + iw::absf(q[1] - q[2]) > limit) {
        return;
    }

    for (int64_t i = 0; i < REACH; i++) {
        const double weight = 0.5 * mix * static_cast<double>(REACH - i)
                / static_cast<double>(REACH);
        const double shift = difference * weight;
        values[at - step * (i + 1)] = iw::narrow(iw::clampf(p[i] + shift, 0.0, 1.0));
        values[at + step * i] = iw::narrow(iw::clampf(q[i] - shift, 0.0, 1.0));
    }
}

} // namespace

// Flattens the seams a JPEG leaves every eight pixels.
//
// The encoder cuts an image into squares of eight by eight and rounds each one off on its
// own. Neighbouring squares end up sitting at slightly different levels, and the eye reads
// the join between them as a grid — worst on exactly the wide flat areas a key has to
// measure against, where there is nothing else for it to hide behind.
//
// Every seam in the grid is looked at in turn and flattened where the evidence says it is
// one. See mend for the three tests that decide, and for why the repair is a ramp.
//
// [b]Brightness is where this lives, which is why it is not the colour smoother.[/b] That
// one leaves brightness alone on purpose, because a JPEG gets brightness nearly right
// everywhere except at these seams. The two repair different halves of the same damage and
// neither does the other's job.
//
// Both passes run over one working copy rather than over the bytes. A correction is often
// a level or two, and rounding back to bytes between the two passes would throw most of it
// away.
//
// This rewrites the source pixels, so like the other repairs it only belongs above
// everything that keys, and the caller owes the run a rebuild of the distance map
// afterwards.
void IWStageKernels::smooth_blocks(const Ref<IWPipelineContext> &ctx, double threshold,
        double amount) {
    if (ctx.is_null() || ctx->pixel_count <= 0 || threshold <= 0.0 || amount <= 0.0) {
        return;
    }

    const int64_t width = ctx->width;
    const int64_t height = ctx->height;
    const int64_t count = ctx->pixel_count;
    const double limit = iw::clampf(threshold, 0.0, 1.0);
    const double mix = iw::clampf(amount, 0.0, 1.0);
    const double to_unit = 1.0 / 255.0;

    std::vector<float> work(static_cast<size_t>(count * 3));
    {
        const uint8_t *src = ctx->data.ptr();
        for (int64_t i = 0; i < count; i++) {
            const int64_t from = i * 4;
            const int64_t into = i * 3;
            work[static_cast<size_t>(into)] = iw::narrow(src[from] * to_unit);
            work[static_cast<size_t>(into + 1)] = iw::narrow(src[from + 1] * to_unit);
            work[static_cast<size_t>(into + 2)] = iw::narrow(src[from + 2] * to_unit);
        }
    }

    float *values = work.data();

    // Down the image first, then across, which is the order every deblocking filter uses.
    // The second pass reading what the first left is not a flaw in it: a corner belongs to
    // both seams, and correcting it once for each is what carries the repair around one.
    for (int64_t y = 0; y < height; y++) {
        const int64_t row = y * width * 3;
        for (int64_t x = BLOCK; x + REACH - 1 < width; x += BLOCK) {
            for (int64_t c = 0; c < 3; c++) {
                mend(values, row + x * 3 + c, 3, limit, mix);
            }
        }
    }

    const int64_t stride = width * 3;
    for (int64_t y = BLOCK; y + REACH - 1 < height; y += BLOCK) {
        const int64_t row = y * stride;
        for (int64_t x = 0; x < width; x++) {
            for (int64_t c = 0; c < 3; c++) {
                mend(values, row + x * 3 + c, stride, limit, mix);
            }
        }
    }

    uint8_t *out = ctx->data.ptrw();
    for (int64_t i = 0; i < count; i++) {
        const int64_t from = i * 3;
        const int64_t into = i * 4;
        out[into] = static_cast<uint8_t>(
                iw::roundi(iw::widen(values[from]) * 255.0));
        out[into + 1] = static_cast<uint8_t>(
                iw::roundi(iw::widen(values[from + 1]) * 255.0));
        out[into + 2] = static_cast<uint8_t>(
                iw::roundi(iw::widen(values[from + 2]) * 255.0));
    }
}
