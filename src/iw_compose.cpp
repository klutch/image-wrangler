#include "iw_compose.h"

#include "iw_math.h"

#include <godot_cpp/variant/color.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>

#include <vector>

using namespace godot;

namespace {

// Below this coverage the un-blend divides by such a small number that it amplifies
// source noise into confetti, so its result is faded into the nearest known subject
// colour instead.
constexpr double DECONTAMINATE_FADE = 0.25;

// Guards divisions where the denominator can legitimately collapse to zero.
constexpr double EPSILON = 0.0001;

// Values of key_of that are not indices into keys.
constexpr int32_t KEY_NONE = -1;

} // namespace

void IWCompose::_bind_methods() {
	ClassDB::bind_static_method("IWCompose", D_METHOD("compose", "ctx"), &IWCompose::compose);
}

// The finished image.
//
// Every buffer but the source data is optional. A context nothing keyed still composes:
// coverage falls back to fully opaque, the fringe removal and the bleed both stand down
// for want of a key to measure against, and what comes out is the source with whatever
// the drawn regions and the stroke did to it.
Ref<Image> IWCompose::compose(const Ref<IWPipelineContext> &ctx) {
	ERR_FAIL_COND_V(ctx.is_null(), Ref<Image>());

	ctx->ensure_coverage();
	// A safety net, not the usual route. Whichever stage draws the stroke folds these
	// in first, because the stroke has to follow the silhouette they produce — but a
	// stack with nothing stroking it would otherwise leave a drawn shape undone. The
	// call is idempotent, so doing it twice costs a pass and changes nothing.
	ctx->apply_regions_to_coverage();

	const PackedByteArray &data = ctx->data;
	const PackedFloat32Array &coverage = ctx->coverage;
	const PackedInt32Array &key_of = ctx->key_of;
	const PackedInt32Array &nearest = ctx->nearest;
	const PackedFloat32Array &inner = ctx->stroke_inner;
	const PackedFloat32Array &outer = ctx->stroke_outer;
	const PackedFloat32Array &stroke_colors = ctx->stroke_colors;
	const PackedByteArray &force_opaque = ctx->force_opaque;
	const TypedArray<Color> &key_list = ctx->keys;

	const int64_t width = ctx->width;
	const int64_t height = ctx->height;
	const int64_t pixel_count = ctx->pixel_count;
	const int64_t bleed_radius = ctx->bleed_radius;
	const Color stroke_color = ctx->stroke_color;

	const bool has_inner = !inner.is_empty();
	const bool has_outer = !outer.is_empty();
	const bool auto_colors = !stroke_colors.is_empty();
	const bool has_keys = !key_list.is_empty();
	const bool has_key_of = !key_of.is_empty();
	const bool has_nearest = !nearest.is_empty();
	const bool has_force = !force_opaque.is_empty();
	// Nothing to un-blend against without a key. The setting stays on; it simply
	// describes work that cannot be done here, the same way it describes no work for a
	// pixel that came out fully covered.
	const bool decontaminate = ctx->decontaminate && has_keys;

	// Pulled out of the Array once. Indexing a Variant per pixel to reach a Color would
	// dominate the loop.
	std::vector<Color> keys;
	keys.reserve(static_cast<size_t>(key_list.size()));
	for (int64_t i = 0; i < key_list.size(); i++) {
		keys.push_back(key_list[i]);
	}
	// Stand-in for a pixel no flood ever claimed. Only reachable once refinement or the
	// alpha clip has pulled a subject pixel below full coverage, since nothing else
	// leaves an unclaimed pixel needing to be un-blended.
	const Color fallback_key = has_keys ? keys[0] : Color(0, 0, 0);

	PackedByteArray out;
	out.resize(pixel_count * 4);
	uint8_t *dst = out.ptrw();
	const uint8_t *src = data.ptr();
	const float *cov = coverage.ptr();
	const int32_t *key_of_ptr = key_of.ptr();
	const int32_t *nearest_ptr = nearest.ptr();
	const float *inner_ptr = inner.ptr();
	const float *outer_ptr = outer.ptr();
	const float *stroke_ptr = stroke_colors.ptr();
	const uint8_t *force_ptr = force_opaque.ptr();

	const double to_unit = 1.0 / 255.0;
	const int64_t key_count = static_cast<int64_t>(keys.size());

	for (int64_t i = 0; i < pixel_count; i++) {
		const int64_t offset = i * 4;
		double r = src[offset] * to_unit;
		double g = src[offset + 1] * to_unit;
		double b = src[offset + 2] * to_unit;
		const double source_alpha = src[offset + 3] * to_unit;
		const int32_t neighbour = has_nearest ? nearest_ptr[i] : -1;
		double alpha = iw::widen(cov[i]);
		// Whichever background claimed this pixel is the one to un-blend.
		const int32_t k = has_key_of ? key_of_ptr[i] : KEY_NONE;
		const Color &pixel_key = (k >= 0 && k < key_count) ? keys[k] : fallback_key;

		if (alpha <= 0.0) {
			alpha = 0.0;
			if (bleed_radius > 0 && neighbour >= 0) {
				const int64_t bleed_offset = static_cast<int64_t>(neighbour) * 4;
				r = src[bleed_offset] * to_unit;
				g = src[bleed_offset + 1] * to_unit;
				b = src[bleed_offset + 2] * to_unit;
			}
		} else if (alpha < 1.0 && decontaminate) {
			const double inverse = 1.0 / alpha;
			const double rest = 1.0 - alpha;
			const double pure_r = iw::clampf((r - rest * iw::widen(pixel_key.r)) * inverse, 0.0, 1.0);
			const double pure_g = iw::clampf((g - rest * iw::widen(pixel_key.g)) * inverse, 0.0, 1.0);
			const double pure_b = iw::clampf((b - rest * iw::widen(pixel_key.b)) * inverse, 0.0, 1.0);
			if (alpha < DECONTAMINATE_FADE && neighbour >= 0) {
				const double weight = alpha / DECONTAMINATE_FADE;
				const int64_t bleed_offset = static_cast<int64_t>(neighbour) * 4;
				r = iw::lerpf(src[bleed_offset] * to_unit, pure_r, weight);
				g = iw::lerpf(src[bleed_offset + 1] * to_unit, pure_g, weight);
				b = iw::lerpf(src[bleed_offset + 2] * to_unit, pure_b, weight);
			} else {
				r = pure_r;
				g = pure_g;
				b = pure_b;
			}
		}

		// Last, and on the colour only. Everything above is still working out what the
		// subject's own colour was; the stroke is paint going on top of the answer, and
		// it must not be un-blended or bled as if it were part of the image. Alpha is
		// untouched — an inside stroke draws on the silhouette rather than adding to it.
		//
		// Held as floats because that is what a Color is: the GDScript builds one from
		// the stroke buffer, which narrows to float32 and reads back out again.
		float paint_r = stroke_color.r;
		float paint_g = stroke_color.g;
		float paint_b = stroke_color.b;
		if (auto_colors) {
			const int64_t slot = i * 3;
			paint_r = stroke_ptr[slot];
			paint_g = stroke_ptr[slot + 1];
			paint_b = stroke_ptr[slot + 2];
		}

		if (has_inner) {
			const double over = iw::widen(inner_ptr[i]);
			if (over > 0.0) {
				r = iw::lerpf(r, iw::widen(paint_r), over);
				g = iw::lerpf(g, iw::widen(paint_g), over);
				b = iw::lerpf(b, iw::widen(paint_b), over);
			}
		}

		double out_alpha = (has_force && force_ptr[i] != 0)
				? 1.0
				: iw::clampf(source_alpha * alpha, 0.0, 1.0);

		// The outer stroke goes *under* what is already here, which is what keeps it
		// from eating the soft edge it is meant to sit behind. Standard over-
		// compositing with the subject on top, so where the subject is solid the stroke
		// contributes nothing and where there is nothing it contributes all.
		if (has_outer) {
			const double behind = iw::widen(outer_ptr[i]);
			if (behind > 0.0) {
				const double combined = out_alpha + behind * (1.0 - out_alpha);
				if (combined > EPSILON) {
					const double share = behind * (1.0 - out_alpha);
					r = (r * out_alpha + iw::widen(paint_r) * share) / combined;
					g = (g * out_alpha + iw::widen(paint_g) * share) / combined;
					b = (b * out_alpha + iw::widen(paint_b) * share) / combined;
				}
				out_alpha = combined;
			}
		}

		dst[offset] = static_cast<uint8_t>(iw::roundi(iw::clampf(r, 0.0, 1.0) * 255.0));
		dst[offset + 1] = static_cast<uint8_t>(iw::roundi(iw::clampf(g, 0.0, 1.0) * 255.0));
		dst[offset + 2] = static_cast<uint8_t>(iw::roundi(iw::clampf(b, 0.0, 1.0) * 255.0));
		dst[offset + 3] = static_cast<uint8_t>(iw::roundi(iw::clampf(out_alpha, 0.0, 1.0) * 255.0));
	}

	return Image::create_from_data(width, height, false, Image::FORMAT_RGBA8, out);
}
