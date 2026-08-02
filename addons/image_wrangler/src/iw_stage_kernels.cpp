#include "iw_stage_kernels.h"

#include "iw_math.h"
#include "iw_pixel_math.h"

#include <algorithm>
#include <cstring>
#include <vector>

using namespace godot;

namespace {

// Guards divisions where the denominator can legitimately collapse to zero. Mirrors
// IWStackOperation.EPSILON on the GDScript side; see IWPipelineContext::EPSILON for why
// there are two.
constexpr double EPSILON = 0.0001;

// The guided filter's regularisation: how hard an edge has to be before the filter
// follows it rather than smoothing across it. Much smaller than EPSILON and for an
// unrelated reason — this one is a parameter of the filter, not a guard.
constexpr double REFINE_EPSILON = 0.000001;

} // namespace

void IWStageKernels::_bind_methods() {
	ClassDB::bind_static_method("IWStageKernels",
			D_METHOD("rasterise_regions", "ctx", "points", "starts", "counts", "adding"),
			&IWStageKernels::rasterise_regions);
	ClassDB::bind_static_method("IWStageKernels",
			D_METHOD("clip_alpha", "ctx", "low", "high"), &IWStageKernels::clip_alpha);
    ClassDB::bind_static_method("IWStageKernels",
            D_METHOD("sharpen_alpha", "image", "amount"), &IWStageKernels::sharpen_alpha);
	ClassDB::bind_static_method("IWStageKernels",
			D_METHOD("guided_refine", "coverage", "guide", "width", "height", "radius"),
			&IWStageKernels::guided_refine);
	ClassDB::bind_static_method("IWStageKernels",
			D_METHOD("squeeze", "ctx"), &IWStageKernels::squeeze);
	ClassDB::bind_static_method("IWStageKernels",
			D_METHOD("classify", "ctx", "contiguous", "edge_width"), &IWStageKernels::classify);
    ClassDB::bind_static_method("IWStageKernels",
            D_METHOD("apply_segmentation", "ctx", "probability", "threshold", "tolerance",
                    "edge_width"),
            &IWStageKernels::apply_segmentation);
	ClassDB::bind_static_method("IWStageKernels",
			D_METHOD("flood_islands", "ctx", "seeds", "tolerances"),
			&IWStageKernels::flood_islands);
	ClassDB::bind_static_method("IWStageKernels",
			D_METHOD("flood_protect", "ctx", "seeds", "tolerances"),
			&IWStageKernels::flood_protect);
	// Defined in iw_edge_kernels.cpp; bound here so every entry point is in one list.
	ClassDB::bind_static_method("IWStageKernels",
			D_METHOD("restore_edges", "ctx"), &IWStageKernels::restore_edges);
	ClassDB::bind_static_method("IWStageKernels",
			D_METHOD("inner_band", "alpha", "stroke_width", "feather", "strength", "width", "height"),
			&IWStageKernels::inner_band);
	ClassDB::bind_static_method("IWStageKernels",
			D_METHOD("outer_band", "alpha", "stroke_width", "feather", "strength", "width", "height"),
			&IWStageKernels::outer_band);
	ClassDB::bind_static_method("IWStageKernels",
			D_METHOD("auto_stroke_colors", "ctx", "alpha", "inner", "outer", "radius"),
			&IWStageKernels::auto_stroke_colors);
	// Defined in iw_denoise_kernels.cpp, which is the only file here that includes a
	// third-party header; bound here so every entry point is in one list.
	ClassDB::bind_static_method("IWStageKernels",
			D_METHOD("denoise", "ctx", "quality", "blend"), &IWStageKernels::denoise);
	// Defined in iw_line_kernels.cpp; bound here so every entry point is in one list.
	ClassDB::bind_static_method("IWStageKernels",
			D_METHOD("remove_lines", "ctx", "thickness", "detached_only"),
			&IWStageKernels::remove_lines);
	// Defined in iw_color_kernels.cpp; bound here so every entry point is in one list.
	ClassDB::bind_static_method("IWStageKernels",
			D_METHOD("smooth_color", "ctx", "radius", "strength", "amount"),
			&IWStageKernels::smooth_color);
	// Defined in iw_block_kernels.cpp; bound here so every entry point is in one list.
	ClassDB::bind_static_method("IWStageKernels",
			D_METHOD("smooth_blocks", "ctx", "threshold", "amount"),
			&IWStageKernels::smooth_blocks);
	// Defined in iw_halo_kernels.cpp; bound here so every entry point is in one list.
	ClassDB::bind_static_method("IWStageKernels",
			D_METHOD("smooth_halos", "ctx", "threshold", "radius", "strength"),
			&IWStageKernels::smooth_halos);
	// Defined in iw_hsv_kernels.cpp; bound here so every entry point is in one list.
	ClassDB::bind_static_method("IWStageKernels",
			D_METHOD("adjust_hsv", "ctx", "rects", "shifts"), &IWStageKernels::adjust_hsv);
    ClassDB::bind_static_method("IWStageKernels",
            D_METHOD("random_hsv_tiles", "ctx", "rng_seed", "hue_amount", "saturation_amount",
                    "value_amount"),
            &IWStageKernels::random_hsv_tiles);
    // Defined in iw_hole_kernels.cpp; bound here so every entry point is in one list.
    ClassDB::bind_static_method("IWStageKernels",
            D_METHOD("fill_pinholes", "ctx", "max_area"), &IWStageKernels::fill_pinholes);
    // Defined in iw_brush_kernels.cpp; bound here so every entry point is in one list.
    ClassDB::bind_static_method("IWStageKernels",
            D_METHOD("paint_strokes", "ctx", "points", "starts", "counts", "radii", "adding",
                    "sharpness"),
            &IWStageKernels::paint_strokes);
    ClassDB::bind_static_method("IWStageKernels",
            D_METHOD("paint_patch", "base", "strength", "beneath", "origin", "from", "to",
                    "radius", "sharpness", "adding"),
            &IWStageKernels::paint_patch);
    ClassDB::bind_static_method("IWStageKernels",
            D_METHOD("stroke_overlay", "points", "radius", "sharpness", "origin", "size",
                    "color"),
            &IWStageKernels::stroke_overlay);
    ClassDB::bind_static_method("IWStageKernels",
            D_METHOD("strength_overlay", "strength", "color"),
            &IWStageKernels::strength_overlay);
    // Defined in iw_pack_kernels.cpp; bound here so every entry point is in one list.
    ClassDB::bind_static_method("IWStageKernels",
            D_METHOD("find_islands", "ctx"), &IWStageKernels::find_islands);
    ClassDB::bind_static_method("IWStageKernels",
            D_METHOD("cut_islands", "ctx"), &IWStageKernels::cut_islands);
    ClassDB::bind_static_method("IWStageKernels",
            D_METHOD("stray_pixel_count", "ctx"), &IWStageKernels::stray_pixel_count);
    // Defined in iw_island_kernels.cpp; bound here so every entry point is in one list.
    ClassDB::bind_static_method("IWStageKernels",
            D_METHOD("remove_minimum_area", "ctx", "min_area"),
            &IWStageKernels::remove_minimum_area);
    ClassDB::bind_static_method("IWStageKernels",
            D_METHOD("exclude_tiles", "ctx", "points", "active", "mode"),
            &IWStageKernels::exclude_tiles);
    // Defined in iw_normal_kernels.cpp; bound here so every entry point is in one list.
    ClassDB::bind_static_method("IWStageKernels",
            D_METHOD("normal_from_shape", "sheet", "rects", "roll_off", "curve", "strength",
                    "color_tolerance", "green_down"),
            &IWStageKernels::normal_from_shape);
    ClassDB::bind_static_method("IWStageKernels",
            D_METHOD("normal_from_brightness", "sheet", "rects", "coarse_size",
                    "coarse_strength", "fine_strength", "green_down"),
            &IWStageKernels::normal_from_brightness);
    ClassDB::bind_static_method("IWStageKernels",
            D_METHOD("combine_normals", "base", "detail", "rects", "mode", "opacity"),
            &IWStageKernels::combine_normals);
    ClassDB::bind_static_method("IWStageKernels",
            D_METHOD("normal_clean_edges", "map", "rects", "inner_reach"),
            &IWStageKernels::normal_clean_edges);
    ClassDB::bind_static_method("IWStageKernels",
            D_METHOD("normal_flip_green", "map"), &IWStageKernels::normal_flip_green);
}

// Rasterises this stage's shapes and folds them into whatever is already declared.
//
// Even-odd scanline fill, bounded by each region's own rows rather than by the image,
// because a corner watermark should not cost a pass over a sprite sheet.
void IWStageKernels::rasterise_regions(
		const Ref<IWPipelineContext> &ctx,
		const PackedInt32Array &points,
		const PackedInt32Array &starts,
		const PackedInt32Array &counts,
		const PackedByteArray &adding) {
	ERR_FAIL_COND(ctx.is_null());
	const int64_t width = ctx->width;
	const int64_t height = ctx->height;
	const int64_t pixel_count = ctx->pixel_count;

	PackedByteArray marked = ctx->blacked;
	if (marked.size() != pixel_count) {
		// Replaced rather than resized: a buffer of the wrong length belongs to another
		// image, and growing it would keep whatever it said about that one.
		marked = PackedByteArray();
		marked.resize(pixel_count);
	}
	uint8_t *out = marked.ptrw();

    // A shape retires whatever an island above it protected on the same pixels, the forced
    // opacity that protection was folded in as, and the outline an Edge Cleanup above
    // worked out for them. See IWPipelineContext::clear_regions_at for why each has to go.
    uint8_t *protect_ptr =
            ctx->protect.size() == pixel_count ? ctx->protect.ptrw() : nullptr;
    uint8_t *force_ptr =
            ctx->force_opaque.size() == pixel_count ? ctx->force_opaque.ptrw() : nullptr;
    float *inner_ptr =
            ctx->stroke_inner.size() == pixel_count ? ctx->stroke_inner.ptrw() : nullptr;
    float *outer_ptr =
            ctx->stroke_outer.size() == pixel_count ? ctx->stroke_outer.ptrw() : nullptr;

	const int32_t *point_ptr = points.ptr();
	std::vector<float> crossings;

	for (int64_t r = 0; r < starts.size(); r++) {
		const int64_t start = starts[r];
		const int64_t count = counts[r];
		if (count <= 0) {
			continue;
		}
		const bool is_adding = adding[r] != 0;
		const uint8_t value = is_adding
				? IWPipelineContext::REGION_KEEP
				: IWPipelineContext::REGION_CUT;

		// The region's own bounding rows.
		int64_t min_y = point_ptr[(start) * 2 + 1];
		int64_t max_y = min_y;
		for (int64_t e = 0; e < count; e++) {
			const int64_t py = point_ptr[(start + e) * 2 + 1];
			min_y = iw::mini(min_y, py);
			max_y = iw::maxi(max_y, py);
		}
		const int64_t first_row = iw::maxi(min_y, 0);
		const int64_t last_row = iw::mini(max_y, height - 1);

		for (int64_t y = first_row; y <= last_row; y++) {
			// Sampled at the row's centre, so a vertex landing exactly on an integer
			// row cannot be counted as a crossing twice.
			const double line = static_cast<double>(y) + 0.5;
			crossings.clear();
			for (int64_t e = 0; e < count; e++) {
				const int64_t ax = point_ptr[(start + e) * 2];
				const int64_t ay = point_ptr[(start + e) * 2 + 1];
				const int64_t next = start + ((e + 1) % count);
				const int64_t bx = point_ptr[next * 2];
				const int64_t by = point_ptr[next * 2 + 1];
				// Half-open on purpose: a vertex is counted by the edge below it and
				// not the one above, which is what stops a shared vertex registering as
				// two crossings and inverting the rest of the row.
				if ((static_cast<double>(ay) > line) == (static_cast<double>(by) > line)) {
					continue;
				}
				const double t = (line - static_cast<double>(ay)) / static_cast<double>(by - ay);
				// Narrowed, because the reference collected these in a
				// PackedFloat32Array — so the sort and every comparison below happen at
				// float32, not at double.
				crossings.push_back(iw::narrow(static_cast<double>(ax) + t * static_cast<double>(bx - ax)));
			}
			if (crossings.size() < 2) {
				continue;
			}
			std::sort(crossings.begin(), crossings.end());

			const int64_t row = y * width;
			size_t pair = 0;
			while (pair + 1 < crossings.size()) {
				// Pixel centres, so a span is filled where it actually covers the middle
				// of a pixel rather than merely touching its edge.
				const int64_t from_x = iw::maxi(iw::ceili(iw::widen(crossings[pair]) - 0.5), 0);
				const int64_t to_x = iw::mini(iw::floori(iw::widen(crossings[pair + 1]) - 0.5), width - 1);
                for (int64_t x = from_x; x <= to_x; x++) {
                    // Rows resolve in the order they are listed, a later one overwriting
                    // whatever an earlier one put down — Add and Cut alike. Subtract used
                    // to yield to an Add already written, which meant the order the user
                    // arranged the list in was not the order that settled an overlap.
                    const int64_t i = row + x;
                    out[i] = value;
                    if (protect_ptr != nullptr) {
                        protect_ptr[i] = 0;
                    }
                    if (force_ptr != nullptr) {
                        force_ptr[i] = 0;
                    }
                    if (inner_ptr != nullptr) {
                        inner_ptr[i] = 0.0f;
                    }
                    if (outer_ptr != nullptr) {
                        outer_ptr[i] = 0.0f;
                    }
                }
				pair += 2;
			}
		}
	}

	ctx->blacked = marked;
}

// Stretches alpha so `low` and below lands on clear and `high` and above on solid.
//
// Letting the ceiling sit at or under the floor is a legitimate request for a hard
// cutoff at that value, so it is honoured rather than rejected — just not by dividing
// by zero.
void IWStageKernels::clip_alpha(const Ref<IWPipelineContext> &ctx, double low, double high) {
	ERR_FAIL_COND(ctx.is_null());
	const double span = iw::maxf(high - low, EPSILON);
	float *out = ctx->coverage.ptrw();
	const int64_t count = ctx->coverage.size();
	for (int64_t i = 0; i < count; i++) {
		out[i] = iw::narrow(iw::clampf((iw::widen(out[i]) - low) / span, 0.0, 1.0));
	}
}

// Tightens the antialiased alpha ramp round an object, without moving the edge.
//
// [b]A contrast stretch of the alpha about half coverage, and of nothing else.[/b] The
// partial values between clear and solid *are* the antialiasing, so narrowing the band they
// occupy is the whole of the job — there is no neighbour to consult and nothing spatial to
// do, which is what separates this from a sharpen filter in the usual sense. Those work on
// colour and invent contrast; this one only decides how quickly the existing edge stops
// being there.
//
// [b]Pivoting on half is what keeps the silhouette still.[/b] The contour dividing "more
// than half covered" from "less" is the only one a stretch about that point cannot move, so
// an object neither swells nor shrinks as the slider is pushed — which it would under a
// threshold set anywhere else, and the swelling would be the first thing anyone noticed.
//
// At 0 nothing changes. At 1 the ramp collapses to a hard cut at half coverage: an edge
// with no antialiasing left in it, which is occasionally exactly what a sprite wants.
//
// Fully clear and fully solid pixels come out as they went in at every setting. That falls
// out of the maths rather than being special-cased — a stretch about the middle can only
// push the two ends further past the ends, where they clamp.
Ref<Image> IWStageKernels::sharpen_alpha(const Ref<Image> &image, double amount) {
    ERR_FAIL_COND_V(image.is_null(), Ref<Image>());
    const double strength = iw::clampf(amount, 0.0, 1.0);
    if (strength <= 0.0 || image->is_empty()) {
        return image;
    }

    const int width = image->get_width();
    const int height = image->get_height();

    PackedByteArray pixels = image->get_data();
    if (image->get_format() != Image::FORMAT_RGBA8) {
        Ref<Image> converted = Image::create_from_data(
                width, height, false, image->get_format(), pixels);
        converted->convert(Image::FORMAT_RGBA8);
        pixels = converted->get_data();
    }

    // [b]A table of 256, because alpha is a byte.[/b] There are only 256 questions this can
    // be asked, so every pixel would otherwise pay again for the same divide and the same
    // rounding. On a sheet upscaled to sixteen million pixels that is the difference between
    // a slider that follows the mouse and one that does not.
    uint8_t curve[256];
    const bool collapses = strength >= 1.0;
    const double gain = collapses ? 1.0 : 1.0 / (1.0 - strength);
    for (int i = 0; i < 256; i++) {
        const double coverage = i / 255.0;
        const double stretched = collapses
                ? (coverage >= 0.5 ? 1.0 : 0.0)
                : iw::clampf((coverage - 0.5) * gain + 0.5, 0.0, 1.0);
        curve[i] = static_cast<uint8_t>(iw::roundi(stretched * 255.0));
    }

    const int64_t count = static_cast<int64_t>(width) * height;
    PackedByteArray out;
    out.resize(count * 4);
    const uint8_t *src = pixels.ptr();
    uint8_t *dst = out.ptrw();
    // The colour is carried over untouched and only the alpha is rewritten, so the whole
    // buffer goes across in one move rather than a channel at a time.
    memcpy(dst, src, static_cast<size_t>(count) * 4);
    for (int64_t i = 0; i < count; i++) {
        const int64_t at = i * 4 + 3;
        dst[at] = curve[src[at]];
    }

    return Image::create_from_data(width, height, false, Image::FORMAT_RGBA8, out);
}

// The guided filter, guided by the distance-from-key map.
//
// Every intermediate here lives in a PackedFloat32Array in the reference, so every one
// of them is narrowed on store and widened on read. That matters more than usual: the
// filter runs six box means over these buffers and the rounding compounds through all
// of them, so keeping an intermediate in double "for accuracy" would walk the result
// away from the reference a little further at every step.
PackedFloat32Array IWStageKernels::guided_refine(
		const PackedFloat32Array &coverage,
		const PackedFloat32Array &guide,
		int64_t width,
		int64_t height,
		int64_t radius) {
	const int64_t pixel_count = width * height;

	PackedFloat32Array guide_squared;
	guide_squared.resize(pixel_count);
	PackedFloat32Array guide_times_alpha;
	guide_times_alpha.resize(pixel_count);
	{
		const float *g = guide.ptr();
		const float *c = coverage.ptr();
		float *gs = guide_squared.ptrw();
		float *ga = guide_times_alpha.ptrw();
		for (int64_t i = 0; i < pixel_count; i++) {
			gs[i] = iw::narrow(iw::widen(g[i]) * iw::widen(g[i]));
			ga[i] = iw::narrow(iw::widen(g[i]) * iw::widen(c[i]));
		}
	}

	const PackedFloat32Array mean_guide = IWPixelMath::box_mean(guide, width, height, radius);
	const PackedFloat32Array mean_alpha = IWPixelMath::box_mean(coverage, width, height, radius);
	const PackedFloat32Array mean_guide_squared =
			IWPixelMath::box_mean(guide_squared, width, height, radius);
	const PackedFloat32Array mean_guide_alpha =
			IWPixelMath::box_mean(guide_times_alpha, width, height, radius);

	PackedFloat32Array slope;
	slope.resize(pixel_count);
	PackedFloat32Array offset;
	offset.resize(pixel_count);
	{
		const float *mg = mean_guide.ptr();
		const float *ma = mean_alpha.ptr();
		const float *mgs = mean_guide_squared.ptr();
		const float *mga = mean_guide_alpha.ptr();
		float *sl = slope.ptrw();
		float *off = offset.ptrw();
		for (int64_t i = 0; i < pixel_count; i++) {
			const double variance = iw::widen(mgs[i]) - iw::widen(mg[i]) * iw::widen(mg[i]);
			const double covariance = iw::widen(mga[i]) - iw::widen(mg[i]) * iw::widen(ma[i]);
			const double a = covariance / (variance + REFINE_EPSILON);
			sl[i] = iw::narrow(a);
			// Reads back the narrowed slope, not the double: the reference stored `a`
			// into a float32 array and then used the local double here, so this one
			// line uses the wide value even though the neighbouring store rounded it.
			off[i] = iw::narrow(iw::widen(ma[i]) - a * iw::widen(mg[i]));
		}
	}

	const PackedFloat32Array mean_slope = IWPixelMath::box_mean(slope, width, height, radius);
	const PackedFloat32Array mean_offset = IWPixelMath::box_mean(offset, width, height, radius);

	PackedFloat32Array refined;
	refined.resize(pixel_count);
	{
		const float *ms = mean_slope.ptr();
		const float *mo = mean_offset.ptr();
		const float *g = guide.ptr();
		float *out = refined.ptrw();
		for (int64_t i = 0; i < pixel_count; i++) {
            const double q = iw::clampf(
                    iw::widen(ms[i]) * iw::widen(g[i]) + iw::widen(mo[i]), 0.0, 1.0);
            // Below half a byte step nothing survives the export, but inside the
            // pipeline it acts as connective tissue between specks and shapes.
            out[i] = q < 0.5 / 255.0 ? 0.0f : iw::narrow(q);
		}
	}
	return refined;
}

// Crosses every neck the budget allows and returns every pixel it claimed.
//
// Seeded from the background as it already stands, each seed carrying the key that
// claimed it, so every squeeze is measured on that colour's own terms. Somewhere a
// previous one of these squeezed to is a seed as well, which is what lets two in a row
// reach further than one. The rest of the edge band is not: it is the antialiasing of a
// silhouette rather than somewhere background got to, and seeding from it would walk
// this stage a pixel into the subject everywhere at once, every time it ran.
//
// A pixel that arrived transparent has no key to squeeze on and is skipped, the way it
// is skipped by the band pass for the same reason.
PackedInt32Array IWStageKernels::squeeze(const Ref<IWPipelineContext> &ctx) {
	PackedInt32Array touched;
	ERR_FAIL_COND_V(ctx.is_null(), touched);

	const int64_t width = ctx->width;
	const int64_t height = ctx->height;
	const int64_t pixel_count = ctx->pixel_count;
	constexpr uint8_t background = IWPipelineContext::MASK_BACKGROUND;
	constexpr int32_t key_none = IWPipelineContext::KEY_NONE;

	if (ctx->strayed.size() != pixel_count) {
		ctx->strayed.resize(pixel_count);
	}

	uint8_t *mask = ctx->mask.ptrw();
	int32_t *key_of = ctx->key_of.ptrw();
	uint8_t *strayed = ctx->strayed.ptrw();

	// Each pixel enters the queue at most once — a seed or a claim, never both, which is
	// what `queued` is for — so it can be sized up front and used as a plain FIFO with
	// no wraparound.
	std::vector<int32_t> queue(static_cast<size_t>(pixel_count), 0);
	std::vector<uint8_t> queued(static_cast<size_t>(pixel_count), 0);
	// How many weak pixels the path to each pixel has crossed. Fresh per stage, which is
	// exactly what gives a second one of these a budget of its own.
	std::vector<int32_t> weak_steps(static_cast<size_t>(pixel_count), 0);
	int64_t head = 0;
	int64_t tail = 0;

	for (int64_t i = 0; i < pixel_count; i++) {
		if (key_of[i] < 0) {
			continue;
		}
		if (mask[i] != background && strayed[i] == 0) {
			continue;
		}
		queued[i] = 1;
		queue[tail++] = static_cast<int32_t>(i);
	}

	// 4-connected on purpose: 8-connectivity leaks through diagonal hairlines in thin
	// subjects such as lettering or wire-frame art. Written out four times, in this
	// order, because the order decides which key claims a pixel two floods reach at the
	// same depth.
	while (head < tail) {
		const int32_t index = queue[head++];
		const int32_t claimed_by = key_of[index];
		if (claimed_by < 0) {
			continue;
		}
		const int32_t weak_here = weak_steps[index];
		const int64_t x = index % width;
		const int64_t y = index / width;

#define IW_TRY_NEIGHBOUR(m_n)                                                        \
	{                                                                                \
		const int32_t n = (m_n);                                                     \
		if (queued[n] == 0 && mask[n] != background) {                               \
			const int64_t took = ctx->flood_key_for(n, claimed_by, weak_here);       \
			if (took != key_none) {                                                  \
				queued[n] = 1;                                                       \
				mask[n] = background;                                                \
				key_of[n] = static_cast<int32_t>(took);                              \
				weak_steps[n] = static_cast<int32_t>(ctx->flood_weak);               \
				touched.push_back(n);                                                \
				queue[tail++] = n;                                                   \
			}                                                                        \
		}                                                                            \
	}

		if (x > 0) {
			IW_TRY_NEIGHBOUR(index - 1)
		}
		if (x < width - 1) {
			IW_TRY_NEIGHBOUR(index + 1)
		}
		if (y > 0) {
			IW_TRY_NEIGHBOUR(index - static_cast<int32_t>(width))
		}
		if (y < height - 1) {
			IW_TRY_NEIGHBOUR(index + static_cast<int32_t>(width))
		}
#undef IW_TRY_NEIGHBOUR
	}

	if (touched.is_empty()) {
		return touched;
	}

	// Everything here was reached by straying — a pixel beside background and inside its
	// tolerance would have been flooded already — so all of it is handed to the coverage
	// maths rather than cut out, and remembered as somewhere a squeeze got to so the
	// next one of these can carry on from it.
	const int32_t *touched_ptr = touched.ptr();
	for (int64_t t = 0; t < touched.size(); t++) {
		const int32_t i = touched_ptr[t];
		if (weak_steps[i] > 0 && key_of[i] >= 0) {
			mask[i] = IWPipelineContext::MASK_EDGE;
			strayed[i] = 1;
		}
	}

	// The band has to grow from what this opened, or a nook would have a hard rim where
	// every other edge in the image has a matte.
	touched.append_array(ctx->grow_edge_band(touched, ctx->edge_width));

    // Any stroke laid down above followed a silhouette this just changed, so what was
    // worked out for these pixels no longer describes anything. Left standing it would
    // fill the opened nook with stroke colour at compose.
    {
        float *inner = ctx->stroke_inner.size() == pixel_count ? ctx->stroke_inner.ptrw() : nullptr;
        float *outer = ctx->stroke_outer.size() == pixel_count ? ctx->stroke_outer.ptrw() : nullptr;
        if (inner != nullptr || outer != nullptr) {
            const int32_t *taken_ptr = touched.ptr();
            for (int64_t t = 0; t < touched.size(); t++) {
                const int32_t i = taken_ptr[t];
                if (inner != nullptr) {
                    inner[i] = 0.0f;
                }
                if (outer != nullptr) {
                    outer[i] = 0.0f;
                }
            }
        }
    }
	return touched;
}

// Sorts every pixel into background, antialiased edge, or subject, and records which
// background colour claimed it.
//
// Two passes over one queue. The first claims the background itself — pixels within
// their key's own tolerance, flood filled inwards from the image border when
// `contiguous` is set, which is what keeps unpicked enclosed regions opaque. The second
// walks `edge_width` steps further in from that background and calls what it touches
// the antialiased band, inheriting the key it grew from.
//
// Additive, so a second one of these narrows what is left rather than starting over: a
// pixel already claimed is left alone, and the band grows only from what this pass took.
void IWStageKernels::classify(
		const Ref<IWPipelineContext> &ctx, bool contiguous, int64_t edge_width) {
	ERR_FAIL_COND(ctx.is_null());
	const int64_t width = ctx->width;
	const int64_t height = ctx->height;
	const int64_t pixel_count = ctx->pixel_count;
	constexpr uint8_t background = IWPipelineContext::MASK_BACKGROUND;
	constexpr int32_t key_none = IWPipelineContext::KEY_NONE;
	constexpr int32_t key_clear = IWPipelineContext::KEY_CLEAR;

	const bool fresh = ctx->mask.is_empty();
	if (fresh) {
		ctx->mask.resize(pixel_count);
		ctx->mask.fill(IWPipelineContext::MASK_SUBJECT);
		ctx->key_of.resize(pixel_count);
		ctx->key_of.fill(key_none);
	}
	uint8_t *mask = ctx->mask.ptrw();
	int32_t *key_of = ctx->key_of.ptrw();

	// Each pixel is claimed at most once, so the queue can be sized up front and used as
	// a plain FIFO with no wraparound.
	PackedInt32Array queue;
	queue.resize(pixel_count);
	int32_t *queue_ptr = queue.ptrw();
	int64_t head = 0;
	int64_t tail = 0;
	// How many weak pixels in a row the flood crossed to reach each pixel; zero on
	// anything solidly background. See IWPipelineContext::flood_key_for.
	std::vector<int32_t> weak_steps(static_cast<size_t>(pixel_count), 0);

	if (contiguous) {
		// Every border pixel is offered to the whole Remove Colors list, so a frame with
		// one background down one edge and another down the opposite edge floods from
		// both without either needing to be picked as an island.
		//
		// Transparency is checked before colour, which flood_key_for does: a transparent
		// pixel's RGB is not a colour anyone chose. This stack bleeds subject colour into
		// what it makes transparent, so the border of an image it has already processed
		// is full of plant green or skin tone.
#define IW_SEED_BORDER(m_index)                                                  \
	{                                                                            \
		const int32_t seed = (m_index);                                          \
		if (mask[seed] != background) {                                          \
			const int64_t took = ctx->flood_key_for(seed, key_clear);            \
			if (took != key_none) {                                              \
				mask[seed] = background;                                         \
				key_of[seed] = static_cast<int32_t>(took);                       \
				queue_ptr[tail++] = seed;                                        \
			}                                                                    \
		}                                                                        \
	}

		for (int64_t x = 0; x < width; x++) {
			IW_SEED_BORDER(static_cast<int32_t>(x))
			IW_SEED_BORDER(static_cast<int32_t>((height - 1) * width + x))
		}
		for (int64_t y = 0; y < height; y++) {
			const int64_t row_start = y * width;
			IW_SEED_BORDER(static_cast<int32_t>(row_start))
			IW_SEED_BORDER(static_cast<int32_t>(row_start + width - 1))
		}
#undef IW_SEED_BORDER

		// 4-connected on purpose: 8-connectivity leaks through diagonal hairlines in thin
		// subjects such as lettering or wire-frame art. The neighbour order is
		// load-bearing — it decides which key claims a pixel two floods reach together.
		while (head < tail) {
			const int32_t index = queue_ptr[head++];
			const int32_t claimed_by = key_of[index];
			const int32_t weak_here = weak_steps[index];
			const int64_t x = index % width;
			const int64_t y = index / width;

#define IW_FLOOD_NEIGHBOUR(m_n)                                                  \
	{                                                                            \
		const int32_t n = (m_n);                                                 \
		if (mask[n] != background) {                                             \
			const int64_t took = ctx->flood_key_for(n, claimed_by, weak_here);   \
			if (took != key_none) {                                              \
				mask[n] = background;                                            \
				key_of[n] = static_cast<int32_t>(took);                          \
				weak_steps[n] = static_cast<int32_t>(ctx->flood_weak);           \
				queue_ptr[tail++] = n;                                           \
			}                                                                    \
		}                                                                        \
	}

			if (x > 0) {
				IW_FLOOD_NEIGHBOUR(index - 1)
			}
			if (x < width - 1) {
				IW_FLOOD_NEIGHBOUR(index + 1)
			}
			if (y > 0) {
				IW_FLOOD_NEIGHBOUR(index - static_cast<int32_t>(width))
			}
			if (y < height - 1) {
				IW_FLOOD_NEIGHBOUR(index + static_cast<int32_t>(width))
			}
#undef IW_FLOOD_NEIGHBOUR
		}
	} else {
		// Without contiguity there is nothing to flood from, so islands have no meaning
		// here: every pixel matching a Remove Color already qualifies.
		for (int64_t i = 0; i < pixel_count; i++) {
			if (mask[i] == background) {
				continue;
			}
			const int64_t claimed = ctx->claiming_key(i);
			if (claimed != key_none) {
				mask[i] = background;
				key_of[i] = static_cast<int32_t>(claimed);
				queue_ptr[tail++] = static_cast<int32_t>(i);
			}
		}
	}

	// Transparency the flood never reached is still transparent. Marked without being
	// queued: there is nothing behind a transparent pixel to make opaque, so leaving it
	// classed as subject would have coverage fill in every enclosed hole the moment an
	// image was processed a second time — but it grows no band either, since it has no
	// colour anything could be matted against.
	if (fresh) {
		for (int64_t i = 0; i < pixel_count; i++) {
			if (mask[i] != background && ctx->is_clear(i)) {
				mask[i] = background;
				key_of[i] = key_clear;
			}
		}
	}

	// A pixel the flood only squeezed through is not background — it is the antialiasing
	// of the two walls it passed between, so it is part subject. Handing it to the band
	// gives it partial alpha from the usual coverage maths, where calling it background
	// would cut a hard notch out of the crevice mouth. Everything the path reached
	// *after* that crossing goes with it, which is what makes straying as cheap as the
	// setting claims.
	//
	// Never a pixel that arrived transparent, though: it has no key to be matted
	// against, and the band pass leaves it alone for the same reason.
	if (ctx->crevice_reach > 0) {
		if (ctx->strayed.size() != pixel_count) {
			ctx->strayed.resize(pixel_count);
		}
		uint8_t *strayed = ctx->strayed.ptrw();
		for (int64_t i = 0; i < pixel_count; i++) {
			if (mask[i] == background && weak_steps[i] > 0 && key_of[i] >= 0) {
				mask[i] = IWPipelineContext::MASK_EDGE;
				strayed[i] = 1;
			}
		}
	}

	// The queue still holds every pixel this pass claimed, in the order it claimed them,
	// so growing the band from it walks outwards in lock-step and depth stays correct.
	queue.resize(tail);
	ctx->grow_edge_band(queue, edge_width);
}

// Turns a network's subject probability into the classification classify produces.
//
// One call rather than several, because the steps are circular from the outside: the key
// colour cannot be sampled until the probability says which pixels are background, and the
// mask cannot be written until the key's index is known.
//
// Exactly one key is registered, flagged as an island. The flag is load-bearing — an
// island key never claims pixels image-wide, so a Remove Crevice below cannot flood
// through the subject on it, and every subject pixel seeds rebuild_nearest. The key
// itself is what keeps compute_coverage working: a band pixel with no key gets full
// alpha, so a keyless mask would flatten into an opaque rim.
//
// Additive, the same convention as classify: a pixel already claimed is left alone, so
// this and Remove Background narrow each other in either order.
void IWStageKernels::apply_segmentation(const Ref<IWPipelineContext> &ctx,
        const Ref<Image> &probability, double threshold, double tolerance,
        int64_t edge_width) {
    ERR_FAIL_COND(ctx.is_null());
    ERR_FAIL_COND(probability.is_null());
    ERR_FAIL_COND(probability->is_empty());
    const int64_t width = ctx->width;
    const int64_t height = ctx->height;
    const int64_t pixel_count = ctx->pixel_count;
    constexpr uint8_t background = IWPipelineContext::MASK_BACKGROUND;

    // The network's answer, stretched over the image. Bilinear, so the fractional values
    // along its boundary survive the stretch rather than becoming a staircase.
    Ref<Image> scaled = probability;
    if (scaled->get_width() != width || scaled->get_height() != height) {
        scaled = scaled->duplicate();
        scaled->resize(static_cast<int32_t>(width), static_cast<int32_t>(height),
                Image::INTERPOLATE_BILINEAR);
    }
    const PackedByteArray prob = scaled->get_data();
    ERR_FAIL_COND(prob.size() < pixel_count);
    const uint8_t *p = prob.ptr();
    const double cut = threshold * 255.0;

    // 0 subject, 1 background with a colour, 2 background because it arrived clear.
    // Transparency is decided first: this stack bleeds subject colour into what it makes
    // transparent, so on a re-run the network is reading colour where there is nothing,
    // and its answer there means nothing.
    std::vector<uint8_t> wants(static_cast<size_t>(pixel_count));
    int64_t subject_count = 0;
    for (int64_t i = 0; i < pixel_count; i++) {
        const uint8_t want =
                ctx->is_clear(i) ? 2 : (static_cast<double>(p[i]) < cut ? 1 : 0);
        wants[static_cast<size_t>(i)] = want;
        if (want == 0) {
            subject_count++;
        }
    }
    // A network that saw no subject anywhere is refusing the picture, not describing it —
    // this model does that on content outside its training. Acting on the answer would
    // key the whole image out, so the pass stands down instead and the caller says why.
    if (subject_count == 0) {
        return;
    }

    // The key is the mean of the background actually touching the subject — those are the
    // pixels whose colour is blended into the antialiased edge, which is what the matte
    // un-blends against. The image-wide mean is the fallback for when the boundary is all
    // transparency.
    const uint8_t *src = ctx->data.ptr();
    double edge_sum[3] = { 0.0, 0.0, 0.0 };
    double all_sum[3] = { 0.0, 0.0, 0.0 };
    int64_t edge_count = 0;
    int64_t all_count = 0;
    for (int64_t i = 0; i < pixel_count; i++) {
        if (wants[static_cast<size_t>(i)] != 1) {
            continue;
        }
        const uint8_t *here = src + i * 4;
        for (int channel = 0; channel < 3; channel++) {
            all_sum[channel] += here[channel];
        }
        all_count++;

        const int64_t x = i % width;
        const int64_t y = i / width;
        const bool beside_subject =
                (x > 0 && wants[static_cast<size_t>(i - 1)] == 0) ||
                (x < width - 1 && wants[static_cast<size_t>(i + 1)] == 0) ||
                (y > 0 && wants[static_cast<size_t>(i - width)] == 0) ||
                (y < height - 1 && wants[static_cast<size_t>(i + width)] == 0);
        if (beside_subject) {
            for (int channel = 0; channel < 3; channel++) {
                edge_sum[channel] += here[channel];
            }
            edge_count++;
        }
    }
    // Nothing but subject and transparency: there is no background colour to matte
    // against, and nothing for this pass to do.
    if (all_count == 0) {
        return;
    }
    const double *sum = edge_count > 0 ? edge_sum : all_sum;
    const double over = static_cast<double>(edge_count > 0 ? edge_count : all_count);
    const Color key(iw::narrow(sum[0] / over / 255.0), iw::narrow(sum[1] / over / 255.0),
            iw::narrow(sum[2] / over / 255.0));
    const int64_t key_index = ctx->add_key(key, tolerance, true);

    const bool fresh = ctx->mask.is_empty();
    if (fresh) {
        ctx->mask.resize(pixel_count);
        ctx->mask.fill(IWPipelineContext::MASK_SUBJECT);
        ctx->key_of.resize(pixel_count);
        ctx->key_of.fill(IWPipelineContext::KEY_NONE);
    }
    uint8_t *mask = ctx->mask.ptrw();
    int32_t *key_of = ctx->key_of.ptrw();

    // Claimed at most once each, so the queue can be sized up front. Clear pixels are
    // marked without being queued, exactly as classify leaves them: they have no colour
    // anything could be matted against, so they grow no band.
    PackedInt32Array queue;
    queue.resize(pixel_count);
    int32_t *queue_ptr = queue.ptrw();
    int64_t tail = 0;
    for (int64_t i = 0; i < pixel_count; i++) {
        if (mask[i] == background) {
            continue;
        }
        const uint8_t want = wants[static_cast<size_t>(i)];
        if (want == 2) {
            mask[i] = background;
            key_of[i] = IWPipelineContext::KEY_CLEAR;
        } else if (want == 1) {
            mask[i] = background;
            key_of[i] = static_cast<int32_t>(key_index);
            queue_ptr[tail++] = static_cast<int32_t>(i);
        }
    }
    queue.resize(tail);
    ctx->grow_edge_band(queue, edge_width);
}

// Floods every Subtract island into the background and mattes what it opened.
PackedInt32Array IWStageKernels::flood_islands(
		const Ref<IWPipelineContext> &ctx,
		const PackedInt32Array &seeds,
		const PackedFloat32Array &tolerances) {
	PackedInt32Array touched;
	ERR_FAIL_COND_V(ctx.is_null(), touched);

	const int64_t width = ctx->width;
	const int64_t height = ctx->height;
	const int64_t pixel_count = ctx->pixel_count;
	constexpr uint8_t background = IWPipelineContext::MASK_BACKGROUND;
	constexpr int32_t key_none = IWPipelineContext::KEY_NONE;

	uint8_t *mask = ctx->mask.ptrw();
	int32_t *key_of = ctx->key_of.ptrw();
	std::vector<int32_t> queue(static_cast<size_t>(pixel_count), 0);
	// The same double threshold the border flood obeys. Not cleared between seeds,
	// though each still starts on a full budget: a pixel one seed claimed is never
	// offered to the next, so no seed can read another's count, and what it records is
	// read once at the end for every seed at once. Clearing it per seed left all but the
	// last seed's squeezed-through pixels classed as hard background.
	std::vector<int32_t> weak_steps(static_cast<size_t>(pixel_count), 0);

	const int32_t *seed_ptr = seeds.ptr();
	const float *tol_ptr = tolerances.ptr();

	for (int64_t s = 0; s < seeds.size(); s++) {
		const int32_t seed = seed_ptr[s];
		// Already swallowed by something above, or by an earlier seed of this very
		// region, so it adds nothing. This is what keeps a dragged rectangle cheap: the
		// first seed floods the region and every other seed inside it costs one test.
		// Its key is not registered either — an unused key would still be walked by
		// claiming_key if it were not flagged as an island, and flagging a key nothing
		// seeded is just clutter.
		if (mask[seed] == background) {
			continue;
		}

		// Sampled now rather than stored, so it removes exactly what was picked.
		const int64_t key = ctx->add_key(ctx->color_at(seed), iw::widen(tol_ptr[s]), true);
		int64_t head = 0;
		int64_t tail = 0;
		mask[seed] = background;
		key_of[seed] = static_cast<int32_t>(key);
		touched.push_back(seed);
		queue[tail++] = seed;

		while (head < tail) {
			const int32_t index = queue[head++];
			const int32_t claimed_by = key_of[index];
			const int32_t weak_here = weak_steps[index];
			const int64_t x = index % width;
			const int64_t y = index / width;

#define IW_ISLAND_NEIGHBOUR(m_n)                                                 \
	{                                                                            \
		const int32_t n = (m_n);                                                 \
		if (mask[n] != background) {                                             \
			const int64_t took = ctx->flood_key_for(n, claimed_by, weak_here);   \
			if (took != key_none) {                                              \
				mask[n] = background;                                            \
				key_of[n] = static_cast<int32_t>(took);                          \
				weak_steps[n] = static_cast<int32_t>(ctx->flood_weak);           \
				touched.push_back(n);                                            \
				queue[tail++] = n;                                               \
			}                                                                    \
		}                                                                        \
	}

			if (x > 0) {
				IW_ISLAND_NEIGHBOUR(index - 1)
			}
			if (x < width - 1) {
				IW_ISLAND_NEIGHBOUR(index + 1)
			}
			if (y > 0) {
				IW_ISLAND_NEIGHBOUR(index - static_cast<int32_t>(width))
			}
			if (y < height - 1) {
				IW_ISLAND_NEIGHBOUR(index + static_cast<int32_t>(width))
			}
#undef IW_ISLAND_NEIGHBOUR
		}
	}

	if (touched.is_empty()) {
		return touched;
	}

	// What the flood only squeezed through is edge, not background, along with
	// everything it reached afterwards — exactly as in the border flood, and for the
	// reason given there. Remembered on the context as well, so a RemoveCrevice below
	// this can carry on from where an island's own squeeze stopped.
	if (ctx->crevice_reach > 0) {
		if (ctx->strayed.size() != pixel_count) {
			ctx->strayed.resize(pixel_count);
		}
		uint8_t *strayed = ctx->strayed.ptrw();
		const int32_t *touched_ptr = touched.ptr();
		for (int64_t t = 0; t < touched.size(); t++) {
			const int32_t i = touched_ptr[t];
			if (mask[i] == background && weak_steps[i] > 0 && key_of[i] >= 0) {
				mask[i] = IWPipelineContext::MASK_EDGE;
				strayed[i] = 1;
			}
		}
	}

    // Removed means gone: what the flood claimed as background loses its source alpha
    // too, so a stage below that rebuilds coverage cannot grow the island back. The
    // edge pixels keep theirs — they are the matte.
    {
        uint8_t *data = ctx->data.ptrw();
        const int32_t *taken_ptr = touched.ptr();
        for (int64_t t = 0; t < touched.size(); t++) {
            const int32_t i = taken_ptr[t];
            if (mask[i] == background) {
                data[static_cast<int64_t>(i) * 4 + 3] = 0;
            }
        }
    }

	// The band has to grow from what this opened, or an island region would have a hard
	// rim where every other edge in the image has a matte.
	touched.append_array(ctx->grow_edge_band(touched, ctx->edge_width));
    // Everything this took stops being covered by whatever declared it kept — the band
    // included, since that is part of what the island changed. Without it an Add above
    // would be folded back in over the cut the moment the regions are next applied.
    ctx->clear_regions_at(touched);
	return touched;
}

// Floods every Add island and marks what it protects.
PackedInt32Array IWStageKernels::flood_protect(
		const Ref<IWPipelineContext> &ctx,
		const PackedInt32Array &seeds,
		const PackedFloat64Array &tolerances) {
	PackedInt32Array touched;
	ERR_FAIL_COND_V(ctx.is_null(), touched);
	if (seeds.is_empty()) {
		return touched;
	}

	const int64_t width = ctx->width;
	const int64_t height = ctx->height;
	const int64_t pixel_count = ctx->pixel_count;

	if (ctx->protect.size() != pixel_count) {
		ctx->protect.resize(pixel_count);
	}
	uint8_t *protect = ctx->protect.ptrw();
    // An island retires whatever a shape above it cut on the same pixels, for the reason
    // given in rasterise_regions: a declaration left standing is one the next fold-in
    // would apply over the top of this one.
    uint8_t *blacked_ptr =
            ctx->blacked.size() == pixel_count ? ctx->blacked.ptrw() : nullptr;
	std::vector<int32_t> queue(static_cast<size_t>(pixel_count), 0);

	const int32_t *seed_ptr = seeds.ptr();
	const double *tol_ptr = tolerances.ptr();

	for (int64_t s = 0; s < seeds.size(); s++) {
		// Sampled here rather than carried in, which is the same answer: the source
		// pixels do not change while a stage is running, so reading one now and reading
		// it before the first flood started cannot differ. Only Denoise rewrites them,
		// and it is a stage of its own — it cannot run in the middle of this one.
		const Color key = ctx->color_at(seed_ptr[s]);
		const double tolerance = tol_ptr[s];
		int64_t head = 0;
		int64_t tail = 0;
		if (protect[seed_ptr[s]] == 0) {
			protect[seed_ptr[s]] = 1;
            if (blacked_ptr != nullptr) {
                blacked_ptr[seed_ptr[s]] = IWPipelineContext::REGION_NONE;
            }
			touched.push_back(seed_ptr[s]);
			queue[tail++] = seed_ptr[s];
		}

		// 4-connected, matching the background flood, so a diagonal hairline is no more
		// of a bridge here than it is there.
		while (head < tail) {
			const int32_t index = queue[head++];
			const int64_t x = index % width;
			const int64_t y = index / width;

#define IW_PROTECT_NEIGHBOUR(m_n)                                                \
	{                                                                            \
		const int32_t n = (m_n);                                                 \
		if (protect[n] == 0 && ctx->distance_at(n, key) <= tolerance) {          \
			protect[n] = 1;                                                      \
			if (blacked_ptr != nullptr) {                                        \
				blacked_ptr[n] = IWPipelineContext::REGION_NONE;                 \
			}                                                                    \
			touched.push_back(n);                                                \
			queue[tail++] = n;                                                   \
		}                                                                        \
	}

			if (x > 0) {
				IW_PROTECT_NEIGHBOUR(index - 1)
			}
			if (x < width - 1) {
				IW_PROTECT_NEIGHBOUR(index + 1)
			}
			if (y > 0) {
				IW_PROTECT_NEIGHBOUR(index - static_cast<int32_t>(width))
			}
			if (y < height - 1) {
				IW_PROTECT_NEIGHBOUR(index + static_cast<int32_t>(width))
			}
#undef IW_PROTECT_NEIGHBOUR
		}
	}

    // The outline an Edge Cleanup above worked out for these pixels, dropped in one pass
    // at the end rather than inside the flood. Not through clear_regions_at, which would
    // take the protection this just wrote with it.
    float *inner_ptr =
            ctx->stroke_inner.size() == pixel_count ? ctx->stroke_inner.ptrw() : nullptr;
    float *outer_ptr =
            ctx->stroke_outer.size() == pixel_count ? ctx->stroke_outer.ptrw() : nullptr;
    if (inner_ptr != nullptr || outer_ptr != nullptr) {
        const int32_t *touched_ptr = touched.ptr();
        for (int64_t t = 0; t < touched.size(); t++) {
            const int32_t i = touched_ptr[t];
            if (inner_ptr != nullptr) {
                inner_ptr[i] = 0.0f;
            }
            if (outer_ptr != nullptr) {
                outer_ptr[i] = 0.0f;
            }
        }
    }

	return touched;
}
