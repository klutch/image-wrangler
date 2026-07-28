#include "iw_pipeline_context.h"

#include "iw_pixel_math.h"

using namespace godot;

void IWPipelineContext::_bind_methods() {
#define IW_BIND_PROP(m_variant_type, m_name)                                                    \
	ClassDB::bind_method(D_METHOD("set_" #m_name, "value"), &IWPipelineContext::set_##m_name);  \
	ClassDB::bind_method(D_METHOD("get_" #m_name), &IWPipelineContext::get_##m_name);           \
	ADD_PROPERTY(PropertyInfo(m_variant_type, #m_name), "set_" #m_name, "get_" #m_name);

	IW_BIND_PROP(Variant::PACKED_BYTE_ARRAY, data)
	IW_BIND_PROP(Variant::INT, width)
	IW_BIND_PROP(Variant::INT, height)
	IW_BIND_PROP(Variant::INT, pixel_count)
	IW_BIND_PROP(Variant::ARRAY, keys)
	IW_BIND_PROP(Variant::PACKED_FLOAT64_ARRAY, key_tolerances)
	IW_BIND_PROP(Variant::PACKED_BYTE_ARRAY, key_is_island)
	IW_BIND_PROP(Variant::PACKED_FLOAT32_ARRAY, key_dist)
	IW_BIND_PROP(Variant::PACKED_BYTE_ARRAY, mask)
	IW_BIND_PROP(Variant::PACKED_INT32_ARRAY, key_of)
	IW_BIND_PROP(Variant::PACKED_INT32_ARRAY, nearest)
	IW_BIND_PROP(Variant::PACKED_FLOAT32_ARRAY, coverage)
	IW_BIND_PROP(Variant::PACKED_BYTE_ARRAY, blacked)
	IW_BIND_PROP(Variant::PACKED_BYTE_ARRAY, protect)
	IW_BIND_PROP(Variant::PACKED_BYTE_ARRAY, strayed)
	IW_BIND_PROP(Variant::PACKED_BYTE_ARRAY, force_opaque)
	IW_BIND_PROP(Variant::PACKED_FLOAT32_ARRAY, stroke_inner)
	IW_BIND_PROP(Variant::PACKED_FLOAT32_ARRAY, stroke_outer)
	IW_BIND_PROP(Variant::PACKED_FLOAT32_ARRAY, stroke_colors)
	IW_BIND_PROP(Variant::INT, edge_width)
	IW_BIND_PROP(Variant::INT, bleed_radius)
	IW_BIND_PROP(Variant::BOOL, decontaminate)
	IW_BIND_PROP(Variant::INT, search_radius)
	IW_BIND_PROP(Variant::COLOR, stroke_color)
	IW_BIND_PROP(Variant::INT, crevice_reach)
	IW_BIND_PROP(Variant::FLOAT, crevice_tolerance)
	IW_BIND_PROP(Variant::INT, flood_weak)
	IW_BIND_PROP(Variant::BOOL, has_keying)
#undef IW_BIND_PROP

	ClassDB::bind_static_method("IWPipelineContext",
			D_METHOD("from_image", "source"), &IWPipelineContext::from_image);
	ClassDB::bind_method(D_METHOD("setup", "data", "width", "height"), &IWPipelineContext::setup);

	ClassDB::bind_method(D_METHOD("distance_at", "index", "key"), &IWPipelineContext::distance_at);
	ClassDB::bind_method(D_METHOD("color_at", "index"), &IWPipelineContext::color_at);
	ClassDB::bind_method(D_METHOD("is_clear", "index"), &IWPipelineContext::is_clear);
	ClassDB::bind_method(D_METHOD("key_distance", "index", "k"), &IWPipelineContext::key_distance);
	ClassDB::bind_method(D_METHOD("claiming_key", "index"), &IWPipelineContext::claiming_key);
	ClassDB::bind_method(D_METHOD("flood_key_for", "to", "from_key", "from_weak"),
			&IWPipelineContext::flood_key_for, DEFVAL(0));
	ClassDB::bind_method(D_METHOD("local_maximum", "index", "radius", "key"),
			&IWPipelineContext::local_maximum);

	ClassDB::bind_method(D_METHOD("final_alpha"), &IWPipelineContext::final_alpha);
	ClassDB::bind_method(D_METHOD("ensure_coverage"), &IWPipelineContext::ensure_coverage);
	ClassDB::bind_method(D_METHOD("has_classification"), &IWPipelineContext::has_classification);
	ClassDB::bind_method(D_METHOD("add_key", "key", "tolerance", "island"),
			&IWPipelineContext::add_key);
	ClassDB::bind_method(D_METHOD("ensure_key_dist"), &IWPipelineContext::ensure_key_dist);
	ClassDB::bind_method(D_METHOD("grow_edge_band", "from", "band_width"),
			&IWPipelineContext::grow_edge_band);
	ClassDB::bind_method(D_METHOD("rebuild_nearest"), &IWPipelineContext::rebuild_nearest);
	ClassDB::bind_method(D_METHOD("compute_coverage", "indices"),
			&IWPipelineContext::compute_coverage);
	ClassDB::bind_method(D_METHOD("all_indices"), &IWPipelineContext::all_indices);
	ClassDB::bind_method(D_METHOD("dilate", "seeds", "radius"), &IWPipelineContext::dilate);
	ClassDB::bind_method(D_METHOD("apply_regions_to_mask"),
			&IWPipelineContext::apply_regions_to_mask);
	ClassDB::bind_method(D_METHOD("apply_regions_to_coverage"),
			&IWPipelineContext::apply_regions_to_coverage);

	BIND_CONSTANT(MASK_BACKGROUND);
	BIND_CONSTANT(MASK_EDGE);
	BIND_CONSTANT(MASK_SUBJECT);
	BIND_CONSTANT(KEY_NONE);
	BIND_CONSTANT(KEY_CLEAR);
	BIND_CONSTANT(REGION_NONE);
	BIND_CONSTANT(REGION_CUT);
	BIND_CONSTANT(REGION_KEEP);
	BIND_CONSTANT(MIN_SEARCH_RADIUS);
}

// --- Lifecycle ----------------------------------------------------------

// A context over source, decompressed and converted to RGBA8.
//
// The one place a run gets its pixels, so every entry point agrees on what a stage may
// assume about them: eight bits a channel, four channels, never compressed. The source
// itself is left untouched.
Ref<IWPipelineContext> IWPipelineContext::from_image(const Ref<Image> &source) {
	Ref<IWPipelineContext> ctx;
	ctx.instantiate();
	ERR_FAIL_COND_V(source.is_null(), ctx);

	Ref<Image> image;
	image.instantiate();
	image->copy_from(source);
	if (image->is_compressed()) {
		image->decompress();
	}
	if (image->get_format() != Image::FORMAT_RGBA8) {
		image->convert(Image::FORMAT_RGBA8);
	}
	ctx->setup(image->get_data(), image->get_width(), image->get_height());
	return ctx;
}

void IWPipelineContext::setup(
		const PackedByteArray &source_data, int64_t source_width, int64_t source_height) {
	data = source_data;
	width = source_width;
	height = source_height;
	pixel_count = source_width * source_height;
}

void IWPipelineContext::set_keys(const TypedArray<Color> &value) {
	keys = value;
	rebuild_key_caches();
}

void IWPipelineContext::set_key_tolerances(const PackedFloat64Array &value) {
	key_tolerances = value;
	rebuild_key_caches();
}

void IWPipelineContext::set_key_is_island(const PackedByteArray &value) {
	key_is_island = value;
	rebuild_key_caches();
}

// Re-derives everything the per-pixel loops read from the key list.
//
// Only reached when something outside add_key replaces one of the three arrays
// wholesale, which nothing currently does — but a cache that can go stale silently is
// worse than one that is rebuilt for nothing.
void IWPipelineContext::rebuild_key_caches() {
	_key_cache.clear();
	_tolerance_cache.clear();
	_claiming.clear();
	for (int64_t i = 0; i < keys.size(); i++) {
		_key_cache.push_back(keys[i]);
	}
	for (int64_t i = 0; i < key_tolerances.size(); i++) {
		_tolerance_cache.push_back(key_tolerances[i]);
	}
	for (int64_t i = 0; i < key_is_island.size(); i++) {
		if (key_is_island[i] == 0) {
			_claiming.push_back(static_cast<int32_t>(i));
		}
	}
}

// --- Per-pixel primitives -----------------------------------------------

// Largest per-channel distance from key for one pixel.
//
// The max-channel metric is the one that makes the coverage maths work: under
// C = a * F + (1 - a) * K every channel difference scales by the same a, so their
// maximum does too. A euclidean or luminance distance would not survive being divided
// by a neighbour's distance.
double IWPipelineContext::distance_at(int64_t index, const Color &key) const {
	const uint8_t *src = data.ptr();
	const int64_t offset = index * 4;
	const double to_unit = 1.0 / 255.0;
	return iw::maxf(
			iw::absf(src[offset] * to_unit - iw::widen(key.r)),
			iw::maxf(
					iw::absf(src[offset + 1] * to_unit - iw::widen(key.g)),
					iw::absf(src[offset + 2] * to_unit - iw::widen(key.b))));
}

Color IWPipelineContext::color_at(int64_t index) const {
	const uint8_t *src = data.ptr();
	const int64_t offset = index * 4;
	const double to_unit = 1.0 / 255.0;
	// Narrowed to float32 by the Color constructor, as it was in GDScript.
	return Color(src[offset] * to_unit, src[offset + 1] * to_unit, src[offset + 2] * to_unit);
}

// Whether a source pixel arrived fully transparent, and so is already removed.
//
// Exactly zero rather than a threshold. A partly transparent pixel is a real
// antialiased edge carrying real coverage, and treating it as empty would eat the soft
// edge of anything processed twice. Zero is what this pipeline itself writes for
// background, so a second run recognises its own first one.
bool IWPipelineContext::is_clear(int64_t index) const {
	return data.ptr()[index * 4 + 3] == 0;
}

// Distance from a pixel to key k, taking the precomputed map for the first key and
// measuring the rest on demand.
double IWPipelineContext::key_distance(int64_t index, int64_t k) const {
	if (k == 0) {
		return iw::widen(key_dist.ptr()[index]);
	}
	return distance_at(index, _key_cache[k]);
}

// Index of the first non-island key claiming index, or KEY_NONE.
//
// First match rather than closest match, so the list reads as an ordered set of rules.
// Two entries close enough to both claim a pixel are describing the same background
// twice, and which of them wins matters far less than the answer being the one the user
// can see at the top of the list.
//
// Islands are skipped by not being walked at all — see _claiming — rather than by a
// test inside the loop, which is what keeps this independent of how many pixels the
// user has picked.
int64_t IWPipelineContext::claiming_key(int64_t index) const {
	const float *dist = key_dist.ptr();
	for (size_t i = 0; i < _claiming.size(); i++) {
		const int32_t k = _claiming[i];
		const double distance = (k == 0) ? iw::widen(dist[index]) : distance_at(index, _key_cache[k]);
		if (distance <= _tolerance_cache[k]) {
			return k;
		}
	}
	return KEY_NONE;
}

// The key `to` should take for a flood arriving from from_key, or KEY_NONE to refuse it.
//
// Returns the key rather than letting the caller inherit one, because the key that
// arrives is not always the key that applies. A flood spreads through the background as
// a whole, not through one colour of it: a pixel the arriving key refuses is offered to
// the rest of the list, and takes whichever entry claims it.
//
// The crevice rule is Canny's double threshold applied to region growing. A pixel
// within its key's own tolerance is crossed freely; one merely within crevice_tolerance
// of that is still crossable, but crevice_reach of them is all any one path gets. The
// budget is spent, not lent: it is carried down the path in flood_weak and never handed
// back, so a flood cannot alternate between straying and landing on something a key
// claims outright and travel that way for as far as it likes.
int64_t IWPipelineContext::flood_key_for(int64_t to, int64_t from_key, int64_t from_weak) {
	// Carried rather than cleared: what a path has spent it has spent, and what it
	// reaches afterwards it reaches only because of it.
	flood_weak = from_weak;
	if (is_clear(to)) {
		return KEY_CLEAR;
	}
	if (from_key == KEY_CLEAR) {
		return claiming_key(to);
	}

	const double distance = key_distance(to, from_key);
	const double tolerance = _tolerance_cache[from_key];
	if (distance <= tolerance) {
		return from_key;
	}

	// The arriving key does not want it, so the rest of the list is asked before giving
	// up. Two flat backgrounds meeting — a white plate around a green stem — are one
	// region to the eye and have to be one to the flood.
	const int64_t claimed = claiming_key(to);
	if (claimed != KEY_NONE) {
		return claimed;
	}

	if (crevice_reach > 0 && from_weak < crevice_reach && distance <= tolerance + crevice_tolerance) {
		flood_weak = from_weak + 1;
		return from_key;
	}
	return KEY_NONE;
}

// Highest distance from key within radius of index.
//
// Only reached for edge pixels that have no opaque subject nearby, which means thin
// features, so the windowed search stays rare.
double IWPipelineContext::local_maximum(int64_t index, int64_t radius, const Color &key) const {
	const int64_t center_x = index % width;
	const int64_t center_y = index / width;
	const int64_t min_x = iw::maxi(center_x - radius, 0);
	const int64_t max_x = iw::mini(center_x + radius, width - 1);
	const int64_t min_y = iw::maxi(center_y - radius, 0);
	const int64_t max_y = iw::mini(center_y + radius, height - 1);
	double best = distance_at(index, key);
	for (int64_t y = min_y; y <= max_y; y++) {
		const int64_t row = y * width;
		for (int64_t x = min_x; x <= max_x; x++) {
			const double value = distance_at(row + x, key);
			if (value > best) {
				best = value;
			}
		}
	}
	return best;
}

// --- Passes -------------------------------------------------------------

// The alpha the image ends up with, 0 to 1: the source's own multiplied by the coverage
// worked out for it, forced solid where force_opaque says so.
//
// What IWCompose is about to write, ahead of it writing it, so the stroke can measure
// its silhouette from the shape that actually comes out.
PackedFloat32Array IWPipelineContext::final_alpha() const {
	PackedFloat32Array alpha;
	alpha.resize(pixel_count);
	float *out = alpha.ptrw();
	const uint8_t *src = data.ptr();
	const float *cov = coverage.ptr();
	const uint8_t *force = force_opaque.ptr();
	const double to_unit = 1.0 / 255.0;
	const bool has_coverage = !coverage.is_empty();
	const bool has_force = !force_opaque.is_empty();
	for (int64_t i = 0; i < pixel_count; i++) {
		if (has_force && force[i] != 0) {
			out[i] = 1.0f;
			continue;
		}
		double value = src[i * 4 + 3] * to_unit;
		if (has_coverage) {
			value *= iw::widen(cov[i]);
		}
		out[i] = iw::narrow(value);
	}
	return alpha;
}

// Fills coverage with full opacity, for a run where nothing has keyed anything out and
// the regions are the whole story.
void IWPipelineContext::ensure_coverage() {
	if (!coverage.is_empty()) {
		return;
	}
	coverage.resize(pixel_count);
	coverage.fill(1.0f);
}

bool IWPipelineContext::has_classification() const {
	return !mask.is_empty();
}

// Adds a key and returns its index.
//
// Appends rather than replacing, so a second keying stage adds to what the first
// established instead of overruling it. `island` flags a key that seeds one region
// rather than being matched image-wide.
int64_t IWPipelineContext::add_key(const Color &key, double tolerance, bool island) {
	keys.push_back(key);
	key_tolerances.push_back(tolerance);
	key_is_island.push_back(island ? 1 : 0);
	_key_cache.push_back(key);
	_tolerance_cache.push_back(tolerance);
	const int64_t index = keys.size() - 1;
	if (!island) {
		_claiming.push_back(static_cast<int32_t>(index));
	}
	has_keying = true;
	ensure_key_dist();
	return index;
}

// Builds key_dist against the first key, if it is not built already.
//
// Only the first key gets a map: it is the one the border flood almost always starts
// from, and a second map per key would cost a pass over the image each to serve a
// handful of pixels. It stays pointed at whichever key came first even after more are
// added.
void IWPipelineContext::ensure_key_dist() {
	if (!key_dist.is_empty() || _key_cache.empty()) {
		return;
	}
	const Color key_color = _key_cache[0];
	key_dist.resize(pixel_count);
	float *dist = key_dist.ptrw();
	const uint8_t *src = data.ptr();
	const double to_unit = 1.0 / 255.0;
	const double key_r = iw::widen(key_color.r);
	const double key_g = iw::widen(key_color.g);
	const double key_b = iw::widen(key_color.b);
	for (int64_t i = 0; i < pixel_count; i++) {
		const int64_t offset = i * 4;
		const double dr = iw::absf(src[offset] * to_unit - key_r);
		const double dg = iw::absf(src[offset + 1] * to_unit - key_g);
		const double db = iw::absf(src[offset + 2] * to_unit - key_b);
		dist[i] = iw::narrow(iw::maxf(dr, iw::maxf(dg, db)));
	}
}

// Grows the antialiased edge band inwards from `from`, up to band_width steps, and
// returns every pixel it claimed.
//
// The band is what turns a hard flood boundary into a matte: compute_coverage gives
// these pixels partial alpha from the usual coverage maths, where leaving them as
// subject would put a hard edge wherever the flood stopped.
//
// Pixels within the inherited key's tolerance are skipped, so an unpicked enclosed
// region keeps its full alpha rather than gaining a torn rim. A pixel that arrived
// transparent has no key and grows no band.
//
// Breadth-first from the whole of `from` at once, so depth is the distance from the
// nearest starting pixel rather than from whichever one happened to be visited first.
PackedInt32Array IWPipelineContext::grow_edge_band(
		const PackedInt32Array &from, int64_t band_width) {
	PackedInt32Array claimed;
	if (band_width <= 0 || from.is_empty()) {
		return claimed;
	}

	std::vector<int32_t> queue(static_cast<size_t>(pixel_count + from.size()), 0);
	std::vector<int32_t> depth(static_cast<size_t>(pixel_count), 0);
	int64_t head = 0;
	int64_t tail = 0;
	for (int64_t i = 0; i < from.size(); i++) {
		queue[tail++] = from[i];
	}

	uint8_t *mask_ptr = mask.ptrw();
	int32_t *key_of_ptr = key_of.ptrw();

	while (head < tail) {
		const int32_t index = queue[head++];
		const int32_t step = depth[index] + 1;
		if (step > band_width) {
			continue;
		}
		const int32_t claimed_by = key_of_ptr[index];
		if (claimed_by < 0) {
			continue;
		}
		// The band inherits the key it grew from, so it is that key's tolerance that
		// decides what still counts as background here.
		const double tolerance = _tolerance_cache[claimed_by];
		const int64_t x = index % width;
		const int64_t y = index / width;
		if (x > 0) {
			const int32_t left = index - 1;
			if (mask_ptr[left] == MASK_SUBJECT && key_distance(left, claimed_by) > tolerance) {
				mask_ptr[left] = MASK_EDGE;
				key_of_ptr[left] = claimed_by;
				depth[left] = step;
				claimed.push_back(left);
				queue[tail++] = left;
			}
		}
		if (x < width - 1) {
			const int32_t right = index + 1;
			if (mask_ptr[right] == MASK_SUBJECT && key_distance(right, claimed_by) > tolerance) {
				mask_ptr[right] = MASK_EDGE;
				key_of_ptr[right] = claimed_by;
				depth[right] = step;
				claimed.push_back(right);
				queue[tail++] = right;
			}
		}
		if (y > 0) {
			const int32_t up = index - static_cast<int32_t>(width);
			if (mask_ptr[up] == MASK_SUBJECT && key_distance(up, claimed_by) > tolerance) {
				mask_ptr[up] = MASK_EDGE;
				key_of_ptr[up] = claimed_by;
				depth[up] = step;
				claimed.push_back(up);
				queue[tail++] = up;
			}
		}
		if (y < height - 1) {
			const int32_t down = index + static_cast<int32_t>(width);
			if (mask_ptr[down] == MASK_SUBJECT && key_distance(down, claimed_by) > tolerance) {
				mask_ptr[down] = MASK_EDGE;
				key_of_ptr[down] = claimed_by;
				depth[down] = step;
				claimed.push_back(down);
				queue[tail++] = down;
			}
		}
	}

	return claimed;
}

// Rebuilds nearest from the current classification.
//
// Subject pixels matching any Remove Color are excluded as sources — an unpicked
// enclosed region is opaque, but keying off its colour would hand edge pixels the very
// background we are trying to remove. Island keys are deliberately not excluded: a
// colour an island keys out in one place is legitimate subject material elsewhere.
//
// Rebuilt whole rather than patched, whenever a stage moves a pixel out of subject. The
// map is one grassfire pass, and working out which entries a change invalidated costs
// more than recomputing them.
void IWPipelineContext::rebuild_nearest() {
	if (mask.is_empty()) {
		nearest = PackedInt32Array();
		return;
	}
	// Sized for the worst case and trimmed: on a normal image most pixels are subject,
	// so appending would reallocate its way up the whole buffer.
	PackedInt32Array seeds;
	seeds.resize(pixel_count);
	int32_t *seed_ptr = seeds.ptrw();
	const uint8_t *mask_ptr = mask.ptr();
	int64_t count = 0;
	for (int64_t i = 0; i < pixel_count; i++) {
		if (mask_ptr[i] == MASK_SUBJECT && claiming_key(i) == KEY_NONE) {
			seed_ptr[count++] = static_cast<int32_t>(i);
		}
	}
	seeds.resize(count);
	nearest = IWPixelMath::grassfire(seeds, width, height, search_radius);
}

// Alpha for every pixel of `indices`, from the classification and the nearest-subject
// map. Writes straight into coverage.
//
// The coverage estimate itself: a pixel's distance from the key that claimed it, over
// the nearest opaque subject pixel's distance from that same key. Under
// C = a * F + (1 - a) * K the unknown subject colour cancels and what is left is the
// coverage.
//
// Takes a list rather than running the whole image, so a stage that only opened up a
// crevice pays for the crevice.
void IWPipelineContext::compute_coverage(const PackedInt32Array &indices) {
	if (coverage.size() != pixel_count) {
		coverage.resize(pixel_count);
	}
	if (mask.is_empty()) {
		return;
	}
	float *out = coverage.ptrw();
	const uint8_t *mask_ptr = mask.ptr();
	const int32_t *key_of_ptr = key_of.ptr();
	const int32_t *nearest_ptr = nearest.ptr();
	const int32_t *index_ptr = indices.ptr();
	const bool has_nearest = !nearest.is_empty();

	for (int64_t n = 0; n < indices.size(); n++) {
		const int32_t i = index_ptr[n];
		if (mask_ptr[i] == MASK_BACKGROUND) {
			out[i] = 0.0f;
			continue;
		}
		if (mask_ptr[i] != MASK_EDGE) {
			out[i] = 1.0f;
			continue;
		}

		const int32_t k = key_of_ptr[i];
		// An edge pixel with no key has nothing to be matted against — a drawn cut or a
		// pixel that arrived transparent. Left solid; whatever declared it will settle
		// its alpha.
		if (k < 0) {
			out[i] = 1.0f;
			continue;
		}
		const Color &pixel_key = _key_cache[k];
		// Measure this pixel against the nearest opaque subject pixel, both through the
		// key that claimed this region. For a genuine antialiased edge that ratio *is*
		// the pixel's coverage.
		const double d = key_distance(i, k);
		const int32_t neighbour = has_nearest ? nearest_ptr[i] : -1;
		double reference = 0.0;
		if (neighbour >= 0) {
			reference = key_distance(neighbour, k);
		} else {
			// Nothing opaque within reach: the band has swallowed a thin feature whole.
			// Fall back to the strongest pixel nearby, which for a stroke is its own
			// core, so it keeps its shape instead of being fattened to fully opaque.
			reference = local_maximum(i, edge_width, pixel_key);
		}

		// Its own key's tolerance, so a loosely keyed region does not drag the coverage
		// of a tightly keyed one around with it.
		const double tolerance = _tolerance_cache[k];
		double value = 0.0;
		if (d > tolerance) {
			value = (d - tolerance) / iw::maxf(reference - tolerance, EPSILON);
		}
		out[i] = iw::narrow(iw::clampf(value, 0.0, 1.0));
	}
}

// Every pixel index, for a stage that has invalidated the whole image.
PackedInt32Array IWPipelineContext::all_indices() const {
	PackedInt32Array all;
	all.resize(pixel_count);
	int32_t *out = all.ptrw();
	for (int64_t i = 0; i < pixel_count; i++) {
		out[i] = static_cast<int32_t>(i);
	}
	return all;
}

// Every pixel within radius of one of `seeds`, seeds included.
//
// What a stage that changed a patch of the classification has to recompute coverage
// over: a pixel outside the patch can only have the wrong answer if its nearest subject
// moved, and that reaches exactly this far.
PackedInt32Array IWPipelineContext::dilate(const PackedInt32Array &seeds, int64_t radius) {
	if (seeds.is_empty()) {
		return seeds;
	}
	const PackedInt32Array reached =
			IWPixelMath::grassfire(seeds, width, height, iw::maxi(radius, 0));
	PackedInt32Array out;
	out.resize(pixel_count);
	int32_t *out_ptr = out.ptrw();
	const int32_t *reached_ptr = reached.ptr();
	int64_t count = 0;
	for (int64_t i = 0; i < pixel_count; i++) {
		if (reached_ptr[i] >= 0) {
			out_ptr[count++] = static_cast<int32_t>(i);
		}
	}
	out.resize(count);
	return out;
}

// Folds the drawn and picked regions into the classification.
//
// KEY_CLEAR on a cut, because the band pass skips a pixel with no key: a drawn cut is a
// hard edge and must not be matted.
//
// Cuts first and protection second, so that where the two meet the protection is what
// survives — Add wins every overlap whatever order the rows are in.
void IWPipelineContext::apply_regions_to_mask() {
	if (mask.is_empty()) {
		return;
	}
	const bool has_blacked = !blacked.is_empty();
	const bool has_protect = !protect.is_empty();
	if (!has_blacked && !has_protect) {
		return;
	}

	uint8_t *mask_ptr = mask.ptrw();
	int32_t *key_of_ptr = key_of.ptrw();
	const uint8_t *blacked_ptr = blacked.ptr();
	const uint8_t *protect_ptr = protect.ptr();

	if (has_blacked) {
		for (int64_t i = 0; i < pixel_count; i++) {
			if (blacked_ptr[i] == REGION_CUT) {
				mask_ptr[i] = MASK_BACKGROUND;
				key_of_ptr[i] = KEY_CLEAR;
			}
		}
	}
	for (int64_t i = 0; i < pixel_count; i++) {
		if ((has_protect && protect_ptr[i] != 0) || (has_blacked && blacked_ptr[i] == REGION_KEEP)) {
			mask_ptr[i] = MASK_SUBJECT;
			key_of_ptr[i] = KEY_NONE;
		}
	}
}

// Folds the drawn and picked regions into the alpha.
//
// Applied after everything that can move alpha, since a region is an instruction about
// the result rather than a suggestion to the keyer.
//
// An Add sets force_opaque rather than a coverage of 1.0, because the two differ where
// the source was already transparent: coverage is multiplied by the source's own alpha,
// and a region drawn over a hole is meant to fill it.
//
// Idempotent, so a stage may call it without knowing whether another already has.
void IWPipelineContext::apply_regions_to_coverage() {
	const bool has_blacked = !blacked.is_empty();
	const bool has_protect = !protect.is_empty();
	if (!has_blacked && !has_protect) {
		return;
	}
	ensure_coverage();

	if (force_opaque.size() != pixel_count) {
		force_opaque.resize(pixel_count);
	}
	float *out = coverage.ptrw();
	uint8_t *force = force_opaque.ptrw();
	const uint8_t *blacked_ptr = blacked.ptr();
	const uint8_t *protect_ptr = protect.ptr();

	for (int64_t i = 0; i < pixel_count; i++) {
		if (has_blacked) {
			if (blacked_ptr[i] == REGION_CUT) {
				out[i] = 0.0f;
			} else if (blacked_ptr[i] == REGION_KEEP) {
				out[i] = 1.0f;
				force[i] = 1;
			}
		}
		if (has_protect && protect_ptr[i] != 0) {
			out[i] = 1.0f;
			force[i] = 1;
		}
	}
}
