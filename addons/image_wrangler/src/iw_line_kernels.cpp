#include "iw_stage_kernels.h"

#include "iw_math.h"

#include <vector>

using namespace godot;

namespace {

// The sub-pixel contour: at or above this a pixel is inside the shape, below it the pixel
// is that shape's antialiasing.
//
// The same half the stroke measures its silhouette against — see contour_seeds in
// iw_edge_kernels.cpp — and deliberately not a setting. Thickness is a number the user
// reads off something they can see, and what they can see is where the edge appears to
// fall. That is the half, not the first byte above zero: a one-pixel antialiased line has
// a *support* three pixels wide, and measuring it there would make every thickness mean
// something other than it says.
constexpr float SOLID_ALPHA = 0.5f;

// Membership in any of the working sets below. One rather than 255 so the sweeps can
// compare them as plain numbers.
constexpr uint8_t IN = 1;

// Running minimum or maximum over `span` consecutive values along one axis, by van Herk
// and Gil-Werman.
//
// Each block of `span` values gets a forward scan, giving the extreme from the block's
// start to each position, and a backward scan giving it from each position to the block's
// end. Every window of length `span` straddles exactly one block boundary, so its extreme
// is one combine of a suffix and a prefix. Three touches per value however wide the
// window — which is what makes the cost of this stage the same at thickness 16 as at 1,
// and is worth the indexing over a windowed scan that would be quadratic in the setting.
//
// [b]Out of bounds reads as zero, in both directions, and the single rule means two
// different things.[/b] For the minimum it says the image is surrounded by background, so
// a hairline lying along the image edge has nothing propping it up and is removable. For
// the maximum it says nothing at all — every value here is 0 or 1, so a zero can never win
// a maximum — which is exactly the clipped window the opening needs out there. That pair
// is what stops a subject bleeding off-frame from losing a strip: its border pixels are
// still covered by a block sitting inward. Replicating the edge instead would look tidier
// and would quietly cost the first of those.
//
// `lead` is how far the window starts ahead of the pixel it answers for: the window for
// output `i` is `[i - lead, i - lead + span - 1]`. The erosion and the dilation must use
// *mirrored* leads or the whole result shifts by a pixel, which only shows up when `span`
// is even — so it is a parameter rather than something the loop bounds imply.
template <bool TAKE_MAX>
void sweep(const uint8_t *src, uint8_t *dst, int64_t count, int64_t stride, int64_t span,
		int64_t lead, std::vector<uint8_t> &prefix, std::vector<uint8_t> &suffix) {
	// One window-start slot per output, plus the tail the last window reaches into.
	const int64_t reach = count + span - 1;
	const int64_t blocks = (reach + span - 1) / span;
	const int64_t total = blocks * span;
	if (static_cast<int64_t>(prefix.size()) < total) {
		prefix.resize(static_cast<size_t>(total));
		suffix.resize(static_cast<size_t>(total));
	}

	for (int64_t base = 0; base < total; base += span) {
		uint8_t run = 0;
		for (int64_t k = base; k < base + span; k++) {
			const int64_t s = k - lead;
			const uint8_t value = (s >= 0 && s < count) ? src[s * stride] : uint8_t(0);
			run = (k == base) ? value : (TAKE_MAX ? (run > value ? run : value)
											      : (run < value ? run : value));
			prefix[static_cast<size_t>(k)] = run;
		}
		for (int64_t k = base + span - 1; k >= base; k--) {
			const int64_t s = k - lead;
			const uint8_t value = (s >= 0 && s < count) ? src[s * stride] : uint8_t(0);
			run = (k == base + span - 1) ? value : (TAKE_MAX ? (run > value ? run : value)
															 : (run < value ? run : value));
			suffix[static_cast<size_t>(k)] = run;
		}
	}

	for (int64_t i = 0; i < count; i++) {
		const uint8_t a = suffix[static_cast<size_t>(i)];
		const uint8_t b = prefix[static_cast<size_t>(i + span - 1)];
		dst[i * stride] = TAKE_MAX ? (a > b ? a : b) : (a < b ? a : b);
	}
}

// The separable pass: a square structuring element is the same as one sweep along each
// axis, which is the whole reason the element is a square. At the sizes this stage is
// actually used at — a side of 2 or 3, for thickness 1 or 2 — the inscribed disk *is* the
// full square, so there is nothing to choose between them; above that a square is very
// slightly kinder to axis-aligned debris than to diagonal, which is not worth a
// non-separable kernel to fix.
template <bool TAKE_MAX>
void sweep_2d(std::vector<uint8_t> &buffer, std::vector<uint8_t> &scratch, int64_t width,
		int64_t height, int64_t span, int64_t lead) {
	std::vector<uint8_t> prefix;
	std::vector<uint8_t> suffix;
	for (int64_t y = 0; y < height; y++) {
		const int64_t row = y * width;
		sweep<TAKE_MAX>(&buffer[static_cast<size_t>(row)], &scratch[static_cast<size_t>(row)],
				width, 1, span, lead, prefix, suffix);
	}
	for (int64_t x = 0; x < width; x++) {
		sweep<TAKE_MAX>(&scratch[static_cast<size_t>(x)], &buffer[static_cast<size_t>(x)],
				height, width, span, lead, prefix, suffix);
	}
}

// Every pixel reachable from a seed without leaving `domain`, 4-connected and unbounded.
//
// The shape of IWPixelMath::grassfire minus its radius: this one has nowhere to stop but
// the domain's own edge, and it wants membership rather than provenance, so both the step
// counts and the seed indices go. 4-connected like every other flood here, and for the
// reason stated at the top of IWStageKernels::classify — an 8-connected one walks straight
// through the diagonal hairlines this stage exists to remove.
//
// The queue is sized for the image alone, unlike grassfire's: a seed outside the domain is
// dropped and a seed offered twice is pushed once, because `reached` guards the way in
// rather than only the way on. `reached` is an in-out parameter, and pixels already marked
// in it on the way in are treated as already claimed — which is how the skirt pass below
// starts from a set it must not revisit.
void flood(const std::vector<uint8_t> &domain, const std::vector<int32_t> &seeds,
		std::vector<uint8_t> &reached, int64_t width, int64_t height) {
	const int64_t pixel_count = width * height;
	std::vector<int32_t> queue(static_cast<size_t>(pixel_count), 0);
	int64_t head = 0;
	int64_t tail = 0;

	for (size_t n = 0; n < seeds.size(); n++) {
		const int32_t seed = seeds[n];
		if (seed < 0 || seed >= pixel_count) {
			continue;
		}
		if (domain[static_cast<size_t>(seed)] == 0 || reached[static_cast<size_t>(seed)] != 0) {
			continue;
		}
		reached[static_cast<size_t>(seed)] = 1;
		queue[static_cast<size_t>(tail++)] = seed;
	}

	while (head < tail) {
		const int64_t index = queue[static_cast<size_t>(head++)];
		const int64_t x = index % width;
		const int64_t y = index / width;
		// Left, right, up, down, matching every other flood here. Nothing about a
		// reachability answer depends on the order, but a reader comparing this with its
		// neighbours should not have to work out whether the difference is meaningful.
		if (x > 0) {
			const int64_t left = index - 1;
			if (reached[static_cast<size_t>(left)] == 0 && domain[static_cast<size_t>(left)] != 0) {
				reached[static_cast<size_t>(left)] = 1;
				queue[static_cast<size_t>(tail++)] = static_cast<int32_t>(left);
			}
		}
		if (x < width - 1) {
			const int64_t right = index + 1;
			if (reached[static_cast<size_t>(right)] == 0 && domain[static_cast<size_t>(right)] != 0) {
				reached[static_cast<size_t>(right)] = 1;
				queue[static_cast<size_t>(tail++)] = static_cast<int32_t>(right);
			}
		}
		if (y > 0) {
			const int64_t up = index - width;
			if (reached[static_cast<size_t>(up)] == 0 && domain[static_cast<size_t>(up)] != 0) {
				reached[static_cast<size_t>(up)] = 1;
				queue[static_cast<size_t>(tail++)] = static_cast<int32_t>(up);
			}
		}
		if (y < height - 1) {
			const int64_t down = index + width;
			if (reached[static_cast<size_t>(down)] == 0 && domain[static_cast<size_t>(down)] != 0) {
				reached[static_cast<size_t>(down)] = 1;
				queue[static_cast<size_t>(tail++)] = static_cast<int32_t>(down);
			}
		}
	}
}

} // namespace

// Erases every structure the silhouette is too thin to have earned, and returns what it
// took.
//
// The whole thing is one morphological opening. `span` is the side of a square that has to
// fit inside a shape for that shape to count as thick enough — one wider than the setting,
// so a structure of `thickness` pixels or fewer has nowhere to put it. Erode by that
// square to get the places it fits, then either put the square back (every thin part goes,
// wherever it is) or flood the whole shape back from those places (a shape survives whole
// if any part of it was thick enough). That second one is opening by reconstruction, and
// it is what `detached_only` selects.
//
// [b]Thickness is measured on the solid set and the erase is applied to the support
// set.[/b] Those are two different sets on purpose: measuring on the support would make a
// one-pixel antialiased line read as three wide, and erasing only the solid would leave
// the line's skirt behind as exactly the faint ghost this stage exists to avoid. So what
// survives is grown back out through its own antialiasing by a flood that may cross
// nothing but partly-transparent pixels — bounded by the skirt rather than by a number,
// which is the only way a kept shape comes out with its edge untouched however soft that
// edge is. A fixed reclaim of a pixel or two would harden every edge in the image.
//
// [b]A shape that is wide but faint everywhere is thin.[/b] Peak alpha below the half
// means no solid pixel, so no square fits anywhere in it, so it goes — unless it touches
// something kept, in which case the skirt flood brings it back. That is usually what is
// wanted from a line remover pointed at a matte, and it is the one place the answer will
// surprise someone, so the tooltip says it.
//
// [b]An explicit square rather than a threshold on a distance transform.[/b] The largest
// distance to background across a structure of width w is ceil(w / 2), so a distance
// threshold cannot tell one pixel from two — the case this stage is for by default. An
// erosion separates them exactly. Opening does not depend on where the square is anchored,
// so an even side needs no special case, but the erosion and the dilation must use
// mirrored windows; see `sweep`.
//
// Considered and not taken: a grayscale opening straight on the alpha, which would drop
// the solid/support split and handle antialiasing natively. It is more elegant and it has
// no clean analogue for `detached_only == false` — every kept boundary would be eroded by
// the same square that measures the debris — and a binary answer is far easier to hold a
// property test against.
PackedInt32Array IWStageKernels::remove_lines(
		const Ref<IWPipelineContext> &ctx, int64_t thickness, bool detached_only) {
	PackedInt32Array touched;
	if (ctx.is_null() || ctx->pixel_count <= 0 || thickness <= 0) {
		return touched;
	}

	const int64_t width = ctx->width;
	const int64_t height = ctx->height;
	const int64_t pixel_count = ctx->pixel_count;
	const int64_t span = thickness + 1;
	// Mirrored windows. For an odd span these are equal and the distinction is invisible;
	// for an even one they are not, and swapping them shifts the result a pixel.
	const int64_t lead_erode = (span - 1) / 2;
	const int64_t lead_dilate = (span - 1) - lead_erode;

	// An image narrower or shorter than the square has no room for one anywhere, so
	// everything in it is thin and everything goes. Left to happen rather than guarded
	// against: a three-pixel-wide image asked to lose everything three pixels wide has
	// been asked for exactly that, and an early return here would be the definition
	// contradicting itself on one shape.

	const PackedFloat32Array alpha = ctx->final_alpha();
	const float *alpha_ptr = alpha.ptr();
	const uint8_t *protect_ptr =
			ctx->protect.size() == pixel_count ? ctx->protect.ptr() : nullptr;
	const uint8_t *blacked_ptr =
			ctx->blacked.size() == pixel_count ? ctx->blacked.ptr() : nullptr;

	std::vector<uint8_t> solid(static_cast<size_t>(pixel_count), 0);
	std::vector<uint8_t> support(static_cast<size_t>(pixel_count), 0);
	// Pixels an Add put there, which are inside the shape because the user said so
	// whatever their alpha currently reads. They are counted as solid so a block of them
	// earns its own squares, and seeded into the flood as well so a protected sliver
	// thinner than the square still brings its shape with it — otherwise painting Add over
	// part of a hairline keeps the painted part and erases the rest, which looks arbitrary.
	std::vector<int32_t> anchors;
    for (int64_t i = 0; i < pixel_count; i++) {
        // Only declarations still standing when this runs. A cut needs no test of its
        // own any more: every region is folded into the coverage by the operation that
        // declared it, so a cut pixel already reads clear in the alpha taken above. It
        // used to be folded in at the very end, which left a cut reading opaque here.
        const bool added = (protect_ptr != nullptr && protect_ptr[i] != 0)
                || (blacked_ptr != nullptr && blacked_ptr[i] == IWPipelineContext::REGION_KEEP);
        const float a = alpha_ptr[i];
        if (added) {
            anchors.push_back(static_cast<int32_t>(i));
        }
        solid[static_cast<size_t>(i)] = (added || a >= SOLID_ALPHA) ? IN : 0;
        support[static_cast<size_t>(i)] = (added || a > 0.0f) ? IN : 0;
    }

	// Where a full span x span block of solid sits.
	std::vector<uint8_t> cores = solid;
	std::vector<uint8_t> scratch(static_cast<size_t>(pixel_count), 0);
	sweep_2d<false>(cores, scratch, width, height, span, lead_erode);

	std::vector<uint8_t> kept(static_cast<size_t>(pixel_count), 0);
	if (detached_only) {
		std::vector<int32_t> seeds = anchors;
		for (int64_t i = 0; i < pixel_count; i++) {
			if (cores[static_cast<size_t>(i)] != 0) {
				seeds.push_back(static_cast<int32_t>(i));
			}
		}
		flood(solid, seeds, kept, width, height);
	} else {
		// Put the square back. The result is contained in solid by construction, so the
		// intersection below is an assertion of that rather than a correction — but it is
		// the invariant the whole stage rests on and it costs one pass.
		kept = cores;
		sweep_2d<true>(kept, scratch, width, height, span, lead_dilate);
		for (int64_t i = 0; i < pixel_count; i++) {
			kept[static_cast<size_t>(i)] &= solid[static_cast<size_t>(i)];
		}
		for (size_t n = 0; n < anchors.size(); n++) {
			kept[static_cast<size_t>(anchors[n])] = IN;
		}
	}

	// Grow what survived back out through its own antialiasing, and no further: the domain
	// is the support minus the solid, so the flood travels only over partly-transparent
	// pixels and halts against any solid pixel it did not already keep.
	std::vector<uint8_t> skirt(static_cast<size_t>(pixel_count), 0);
	for (int64_t i = 0; i < pixel_count; i++) {
		skirt[static_cast<size_t>(i)] =
				(support[static_cast<size_t>(i)] != 0 && solid[static_cast<size_t>(i)] == 0)
				? IN
				: 0;
	}
	// Deduplicated as it is built rather than left to the flood's own guard: a kept pixel
	// offers up to four neighbours, and a list four times the size of the image is worth
	// avoiding on anything large.
	std::vector<uint8_t> offered(static_cast<size_t>(pixel_count), 0);
	std::vector<int32_t> fringe;
	for (int64_t i = 0; i < pixel_count; i++) {
		if (kept[static_cast<size_t>(i)] == 0) {
			continue;
		}
		const int64_t x = i % width;
		const int64_t y = i / width;
		const int64_t neighbours[4] = { i - 1, i + 1, i - width, i + width };
		const bool exists[4] = { x > 0, x < width - 1, y > 0, y < height - 1 };
		for (int n = 0; n < 4; n++) {
			if (!exists[n]) {
				continue;
			}
			const size_t at = static_cast<size_t>(neighbours[n]);
			if (skirt[at] == 0 || offered[at] != 0) {
				continue;
			}
			offered[at] = IN;
			fringe.push_back(static_cast<int32_t>(neighbours[n]));
		}
	}
	flood(skirt, fringe, kept, width, height);

	// --- The erase -------------------------------------------------------

	ctx->ensure_coverage();
	float *coverage_ptr = ctx->coverage.ptrw();
	// The mask can exist without the key list — nothing produces that today, and
	// compute_coverage would read straight past the end of it if anything did.
	uint8_t *mask_ptr = ctx->has_classification() && ctx->mask.size() == pixel_count
			? ctx->mask.ptrw()
			: nullptr;
	int32_t *key_of_ptr = mask_ptr != nullptr && ctx->key_of.size() == pixel_count
			? ctx->key_of.ptrw()
			: nullptr;
	// Zeroed where they exist, which is only a partial defence: an outer stroke reaches
	// past the shape that cast it, and the part beyond the erase survives. The real answer
	// is to run above Edge Cleanup, which is what the stage's note says.
	float *inner_ptr = ctx->stroke_inner.size() == pixel_count ? ctx->stroke_inner.ptrw() : nullptr;
	float *outer_ptr = ctx->stroke_outer.size() == pixel_count ? ctx->stroke_outer.ptrw() : nullptr;
    uint8_t *data_ptr = ctx->data.ptrw();

	for (int64_t i = 0; i < pixel_count; i++) {
		if (support[static_cast<size_t>(i)] == 0 || kept[static_cast<size_t>(i)] != 0) {
			continue;
		}
		coverage_ptr[i] = 0.0f;
        // The source alpha goes too, so a stage below that rebuilds coverage cannot
        // grow the line back out of the alpha still sitting here.
        data_ptr[i * 4 + 3] = 0;
		if (mask_ptr != nullptr) {
			mask_ptr[i] = IWPipelineContext::MASK_BACKGROUND;
		}
		if (key_of_ptr != nullptr) {
			// KEY_CLEAR rather than KEY_NONE, and the difference is load-bearing: an
			// erased line is a hard removal with no colour to un-blend against, so it must
			// not be handed to the matte as though some entry had claimed it. Same
			// reasoning as a drawn cut; see apply_regions_to_mask.
			key_of_ptr[i] = IWPipelineContext::KEY_CLEAR;
		}
		if (inner_ptr != nullptr) {
			inner_ptr[i] = 0.0f;
		}
		if (outer_ptr != nullptr) {
			outer_ptr[i] = 0.0f;
		}
		touched.push_back(static_cast<int32_t>(i));
	}
	return touched;
}
