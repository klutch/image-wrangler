// EdgeCleanup's inner loops.
//
// Split from iw_stage_kernels.cpp because there are six of them and they share four
// helpers of their own; the other five stages are one or two functions each. Same class,
// separate translation unit.

#include "iw_stage_kernels.h"

#include "iw_math.h"
#include "iw_pixel_math.h"

#include <cmath>
#include <vector>

using namespace godot;

namespace {

// The context's own guard value, reached through the class rather than copied, so this
// file at least cannot be the one that lets the two definitions drift.
constexpr double EPSILON = IWPipelineContext::EPSILON;

// How near full or empty a pixel has to be before it counts as one extreme or the other,
// and how far inwards the restoration may walk to find uncontaminated subject.
constexpr double RESTORE_SOLID = 0.995;
constexpr double RESTORE_CLEAR = 0.005;
constexpr int64_t RESTORE_INWARD_MAX = 2;

// How far the automatic stroke colour is darkened and saturated relative to what it
// sampled. Painting a colour over itself shows nothing.
constexpr double AUTO_STROKE_DARKEN = 0.35;
constexpr double AUTO_STROKE_SATURATION = 1.3;

// Whether `index` sits at the opposite extreme to a pixel that is `solid`.
inline bool opposes(const float *coverage, int64_t index, bool solid) {
	return solid ? iw::widen(coverage[index]) <= RESTORE_CLEAR
				 : iw::widen(coverage[index]) >= RESTORE_SOLID;
}

// A pixel a step or two into the opaque shape from (x, y), or -1.
//
// The pixel being restored is itself part background — that is what makes it an edge —
// so measuring it against its own colour would ask how much of a blend a blend is and
// answer "all of it". A step inward gets past the contamination.
//
// The direction comes from the alpha around the pixel: every neighbour pulls towards
// itself in proportion to how opaque it is, so the sum points the way the shape lies.
// Walking it stops at the first pixel that is not solid, so a step can never cross a gap
// and come back with a colour from the far side.
//
// The reference allocated two three-element Arrays here per call, per edge pixel. That
// cost is simply gone.
int64_t inward(const float *coverage, int64_t x, int64_t y, int64_t width, int64_t height) {
	double dx = 0.0;
	double dy = 0.0;
	for (int64_t oy = -1; oy <= 1; oy++) {
		for (int64_t ox = -1; ox <= 1; ox++) {
			if (ox == 0 && oy == 0) {
				continue;
			}
			const int64_t nx = x + ox;
			const int64_t ny = y + oy;
			if (nx < 0 || ny < 0 || nx >= width || ny >= height) {
				continue;
			}
			const double weight = iw::widen(coverage[ny * width + nx]);
			dx += static_cast<double>(ox) * weight;
			dy += static_cast<double>(oy) * weight;
		}
	}

	const double length = std::sqrt(dx * dx + dy * dy);
	if (length <= EPSILON) {
		return -1;
	}
	dx /= length;
	dy /= length;

	int64_t found = -1;
	for (int64_t step = 1; step <= RESTORE_INWARD_MAX; step++) {
		const int64_t sx = x + iw::roundi(dx * static_cast<double>(step));
		const int64_t sy = y + iw::roundi(dy * static_cast<double>(step));
		if (sx < 0 || sy < 0 || sx >= width || sy >= height) {
			break;
		}
		const int64_t candidate = sy * width + sx;
		if (iw::widen(coverage[candidate]) < RESTORE_SOLID) {
			break;
		}
		found = candidate;
	}
	return found;
}

// Nearest seed index for every pixel within `reach` of the contour, or -1.
//
// `seed_inside` picks which side seeds: the far side from whichever band is being
// measured, since what each pixel wants is the distance to the other side.
PackedInt32Array contour_seeds(
		const PackedFloat32Array &alpha, bool seed_inside, int64_t reach,
		int64_t width, int64_t height) {
	const int64_t pixel_count = width * height;
	// Sized for the worst case and trimmed rather than grown: one side of the contour is
	// most of the image, so appending would reallocate its way up the whole buffer.
	PackedInt32Array seeds;
	seeds.resize(pixel_count);
	int32_t *seed_ptr = seeds.ptrw();
	const float *a = alpha.ptr();
	int64_t count = 0;

	// Half coverage is the line, not full transparency. The half-covered band along an
	// antialiased edge belongs to the shape's soft edge, and counting it as solid would
	// push the contour a pixel out and blunt the very gradient this measures.
	for (int64_t i = 0; i < pixel_count; i++) {
		if ((iw::widen(a[i]) >= 0.5) == seed_inside) {
			seed_ptr[count++] = static_cast<int32_t>(i);
		}
	}
	seeds.resize(count);
	if (seeds.is_empty() || seeds.size() == pixel_count) {
		// All of one side, so there is no contour anywhere to measure from. Empty rather
		// than a map of -1, since the callers treat "no contour" and "out of reach of
		// one" differently.
		return PackedInt32Array();
	}
	return IWPixelMath::grassfire(seeds, width, height, reach);
}

// How much of the stroke covers a pixel `distance` from the contour.
//
// Falls off across the requested width rather than up to it, so softening blurs the far
// edge in place instead of walking the stroke inwards. A feather of zero is a genuine
// step rather than a very narrow ramp, so the division is skipped rather than
// approximated.
inline double falloff(double distance, double stroke_width, double feather) {
	if (feather <= EPSILON) {
		return distance <= stroke_width ? 1.0 : 0.0;
	}
	return iw::clampf((stroke_width + feather * 0.5 - distance) / feather, 0.0, 1.0);
}

} // namespace

PackedFloat32Array IWStageKernels::restore_edges(const Ref<IWPipelineContext> &ctx) {
	PackedFloat32Array out;
	ERR_FAIL_COND_V(ctx.is_null(), out);

	const int64_t width = ctx->width;
	const int64_t height = ctx->height;
	const int64_t pixel_count = ctx->pixel_count;
	const bool has_regions = !ctx->blacked.is_empty();
	const bool has_nearest = !ctx->nearest.is_empty();
	const bool has_key_of = !ctx->key_of.is_empty();

	const PackedFloat32Array coverage_ref = ctx->coverage;
	const float *coverage = coverage_ref.ptr();
	const int32_t *key_of = ctx->key_of.ptr();
	const int32_t *nearest = ctx->nearest.ptr();
	const uint8_t *blacked = ctx->blacked.ptr();

	std::vector<Color> keys;
	keys.reserve(static_cast<size_t>(ctx->keys.size()));
	for (int64_t k = 0; k < ctx->keys.size(); k++) {
		keys.push_back(ctx->keys[k]);
	}
	const Color fallback_key = keys.empty() ? Color(0, 0, 0) : keys[0];

	// Written to a copy, so that a pixel restored early in the scan cannot become the
	// evidence that its neighbour needs restoring too.
	out = coverage_ref.duplicate();
	float *dst = out.ptrw();

	for (int64_t i = 0; i < pixel_count; i++) {
		if (has_regions && blacked[i] != IWPipelineContext::REGION_NONE) {
			continue;
		}
		const double here = iw::widen(coverage[i]);
		const bool solid = here >= RESTORE_SOLID;
		if (!solid && here > RESTORE_CLEAR) {
			continue;
		}

		const int64_t x = i % width;
		const int64_t y = i / width;

		// The opposite extreme, if it is right there. Anything softer between the two
		// means this edge already has its matte.
		int64_t facing = -1;
		if (x > 0 && opposes(coverage, i - 1, solid)) {
			facing = i - 1;
		} else if (x < width - 1 && opposes(coverage, i + 1, solid)) {
			facing = i + 1;
		} else if (y > 0 && opposes(coverage, i - width, solid)) {
			facing = i - width;
		} else if (y < height - 1 && opposes(coverage, i + width, solid)) {
			facing = i + width;
		}
		if (facing < 0) {
			continue;
		}
		if (has_regions && blacked[facing] != IWPipelineContext::REGION_NONE) {
			continue;
		}

		// The background this edge is against, taken from whichever of the two sides the
		// flood actually claimed, since that is the one that knows.
		int64_t claimed = -1;
		if (has_key_of) {
			claimed = key_of[facing] >= 0 ? key_of[facing] : key_of[i];
		}
		const Color &key = (claimed >= 0 && claimed < static_cast<int64_t>(keys.size()))
				? keys[claimed]
				: fallback_key;

		int64_t subject = inward(coverage, x, y, width, height);
		if (subject < 0 && has_nearest) {
			subject = nearest[i];
		}
		if (subject < 0) {
			continue;
		}

		const double reference = ctx->distance_at(subject, key);
		// Subject indistinguishable from background here: the division would amplify
		// nothing into anything, and there is no coverage to recover.
		if (reference <= EPSILON) {
			continue;
		}
		dst[i] = iw::narrow(iw::clampf(ctx->distance_at(i, key) / reference, 0.0, 1.0));
	}

	return out;
}

// Strength per pixel for the stroke inside the silhouette.
//
// The canvas edge counts as outside: rather than seeding the border, every pixel also
// measures its distance to just past the frame and takes whichever is nearer — one
// comparison, no extra seeds, and a shape running off the edge is stroked along it like
// any other contour.
//
// The inner edge is feathered and the outer one is not. The outer edge here is the
// silhouette, and its softness is already in the image's own alpha.
PackedFloat32Array IWStageKernels::inner_band(
		const PackedFloat32Array &alpha, double stroke_width, double feather,
		double strength, int64_t width, int64_t height) {
	const int64_t pixel_count = width * height;
	// Far enough to cover the whole falloff and one more, so a pixel that should still be
	// faintly stroked is never left unreached and reading as empty. The feather counts
	// here: it pushes the fade out past the requested width.
	const int64_t reach = iw::ceili(stroke_width + feather * 0.5) + 1;
	const PackedInt32Array source = contour_seeds(alpha, false, reach, width, height);
	const int32_t *src = source.ptr();
	const bool has_source = !source.is_empty();
	const float *a = alpha.ptr();

	PackedFloat32Array mask;
	mask.resize(pixel_count);
	float *out = mask.ptrw();
	bool painted = false;

	for (int64_t i = 0; i < pixel_count; i++) {
		// Nothing there to paint on, and painting anyway would put stroke colour into the
		// pixels the colour bleed is filling.
		if (iw::widen(a[i]) <= 0.0) {
			continue;
		}
		const int64_t x = i % width;
		const int64_t y = i / width;

		// Half a pixel, because the frame runs along the outer edge of the border row
		// rather than through its centre.
		const int64_t frame = iw::mini(iw::mini(x, y), iw::mini(width - 1 - x, height - 1 - y));
		double distance = static_cast<double>(frame) + 0.5;

		if (iw::widen(a[i]) < 0.5) {
			// Outside the contour but still visible: part of the shape's own soft edge.
			// Its distance is negative, so the stroke covers it outright and the pixel's
			// own alpha does the fading.
			distance = iw::minf(distance, iw::widen(a[i]) - 0.5);
		} else if (has_source) {
			const int32_t seed_index = src[i];
			if (seed_index >= 0) {
				const int64_t sx = seed_index % width;
				const int64_t sy = seed_index / width;
				const double span = std::sqrt(
						static_cast<double>((x - sx) * (x - sx) + (y - sy) * (y - sy)));
				// The seed is a pixel centre, and the contour is a fraction of a pixel
				// short of it. Adding the seed's own signed offset — negative, since a
				// seed is outside — walks the measurement back to the contour, and is
				// what makes this smooth along an edge rather than stepping with the seed
				// positions.
				distance = iw::minf(distance, span + (iw::widen(a[seed_index]) - 0.5));
			}
		}

		const double band = falloff(distance, stroke_width, feather);
		if (band <= 0.0) {
			continue;
		}
		out[i] = iw::narrow(band * strength);
		painted = true;
	}

	return painted ? mask : PackedFloat32Array();
}

// Strength per pixel for the stroke outside the silhouette.
//
// The mirror of inner_band, measuring outwards from the same contour, and with the frame
// deliberately playing no part: there is nothing beyond it to grow into, so a shape
// running off the edge simply gets clipped there.
//
// A pixel already solid is skipped. The stroke is drawn under the subject, so where the
// subject is opaque there is nothing of the stroke left to see and working it out would
// be effort spent on an invisible result.
PackedFloat32Array IWStageKernels::outer_band(
		const PackedFloat32Array &alpha, double stroke_width, double feather,
		double strength, int64_t width, int64_t height) {
	const int64_t pixel_count = width * height;
	const int64_t reach = iw::ceili(stroke_width + feather * 0.5) + 1;
	const PackedInt32Array source = contour_seeds(alpha, true, reach, width, height);
	if (source.is_empty()) {
		return PackedFloat32Array();
	}
	const int32_t *src = source.ptr();
	const float *a = alpha.ptr();

	PackedFloat32Array mask;
	mask.resize(pixel_count);
	float *out = mask.ptrw();
	bool painted = false;

	for (int64_t i = 0; i < pixel_count; i++) {
		if (iw::widen(a[i]) >= 1.0) {
			continue;
		}
		const int64_t x = i % width;
		const int64_t y = i / width;

		double distance = 0.0;
		if (iw::widen(a[i]) >= 0.5) {
			// Inside the contour but not solid: the shape's own soft edge again, seen
			// from the other side. Negative distance, so the stroke fills the whole of it
			// and is then hidden by whatever alpha the subject has.
			distance = 0.5 - iw::widen(a[i]);
		} else {
			const int32_t seed_index = src[i];
			if (seed_index < 0) {
				continue;
			}
			const int64_t sx = seed_index % width;
			const int64_t sy = seed_index / width;
			const double span = std::sqrt(
					static_cast<double>((x - sx) * (x - sx) + (y - sy) * (y - sy)));
			// Subtracted rather than added: the seed is inside this time, so its own
			// offset is how far past the contour it sits.
			distance = span - (iw::widen(a[seed_index]) - 0.5);
		}

		const double band = falloff(distance, stroke_width, feather);
		if (band <= 0.0) {
			continue;
		}
		out[i] = iw::narrow(band * strength);
		painted = true;
	}

	return painted ? mask : PackedFloat32Array();
}

// A stroke colour per pixel, taken from the image.
//
// Sampled from an alpha-weighted blur: each channel is blurred premultiplied by alpha
// and divided by a blur of the alpha itself, so the average is over subject only. That
// weighting is the whole trick — a plain blur, sampled at the silhouette edge where
// every stroke pixel sits, would average in the empty space just outside it and drag
// every stroke towards whatever the bleed left there.
//
// Then darkened, because painting a colour over itself shows nothing.
PackedFloat32Array IWStageKernels::auto_stroke_colors(
		const Ref<IWPipelineContext> &ctx,
		const PackedFloat32Array &alpha,
		const PackedFloat32Array &inner,
		const PackedFloat32Array &outer,
		int64_t radius) {
	PackedFloat32Array colors;
	ERR_FAIL_COND_V(ctx.is_null(), colors);
	const bool has_inner = !inner.is_empty();
	const bool has_outer = !outer.is_empty();
	if (!has_inner && !has_outer) {
		return colors;
	}

	const int64_t width = ctx->width;
	const int64_t height = ctx->height;
	const int64_t pixel_count = ctx->pixel_count;
	const uint8_t *data = ctx->data.ptr();
	const float *a = alpha.ptr();

	PackedFloat32Array premul_r;
	PackedFloat32Array premul_g;
	PackedFloat32Array premul_b;
	PackedFloat32Array weight;
	premul_r.resize(pixel_count);
	premul_g.resize(pixel_count);
	premul_b.resize(pixel_count);
	weight.resize(pixel_count);
	{
		float *pr = premul_r.ptrw();
		float *pg = premul_g.ptrw();
		float *pb = premul_b.ptrw();
		float *w = weight.ptrw();
		const double to_unit = 1.0 / 255.0;
		for (int64_t i = 0; i < pixel_count; i++) {
			const int64_t offset = i * 4;
			const double av = iw::widen(a[i]);
			pr[i] = iw::narrow(data[offset] * to_unit * av);
			pg[i] = iw::narrow(data[offset + 1] * to_unit * av);
			pb[i] = iw::narrow(data[offset + 2] * to_unit * av);
			w[i] = iw::narrow(av);
		}
	}

	premul_r = IWPixelMath::box_mean(premul_r, width, height, radius);
	premul_g = IWPixelMath::box_mean(premul_g, width, height, radius);
	premul_b = IWPixelMath::box_mean(premul_b, width, height, radius);
	weight = IWPixelMath::box_mean(weight, width, height, radius);

	colors.resize(pixel_count * 3);
	float *out = colors.ptrw();
	const float *pr = premul_r.ptr();
	const float *pg = premul_g.ptr();
	const float *pb = premul_b.ptr();
	const float *w = weight.ptr();
	const float *in_ptr = inner.ptr();
	const float *out_ptr = outer.ptr();

	for (int64_t i = 0; i < pixel_count; i++) {
		// Wherever either stroke paints. They share a colour, so the sample only has to
		// be worked out once per pixel.
		if ((!has_inner || iw::widen(in_ptr[i]) <= 0.0)
				&& (!has_outer || iw::widen(out_ptr[i]) <= 0.0)) {
			continue;
		}
		const double wv = iw::widen(w[i]);
		// No subject within the whole blur radius, which for a stroke pixel means
		// something has gone strange. Nothing to sample, so leave it black.
		if (wv <= EPSILON) {
			continue;
		}
		// Built as a Color, which narrows each channel to float32 before the hue and
		// saturation are read back off it — as the reference did.
		const Color sampled(
				static_cast<float>(iw::widen(pr[i]) / wv),
				static_cast<float>(iw::widen(pg[i]) / wv),
				static_cast<float>(iw::widen(pb[i]) / wv));
		const Color line = Color::from_hsv(
				sampled.get_h(),
				static_cast<float>(iw::minf(sampled.get_s() * AUTO_STROKE_SATURATION, 1.0)),
				static_cast<float>(iw::clampf(sampled.get_v() * AUTO_STROKE_DARKEN, 0.0, 1.0)));
		const int64_t slot = i * 3;
		out[slot] = line.r;
		out[slot + 1] = line.g;
		out[slot + 2] = line.b;
	}

	return colors;
}
