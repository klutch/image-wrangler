#pragma once

// Everything one run of the pipeline knows about the image, shared by every stage.
//
// A RefCounted rather than a Resource, deliberately: IWSettingsIO walks anything with
// storage flags, and a context reachable from a settings object would be serialised
// into a sidecar.
//
// The stages are still GDScript and read these buffers the way they always have —
// `var mask := ctx.mask`, mutate, `ctx.mask = mask`.
//
// [b]That pattern means something different now, and the difference is the one real
// hazard in this port.[/b] Reading a Packed array off a *GDScript* object handed back a
// live reference into the object's own storage: mutating the local mutated the member,
// and the write-back at the end was belt-and-braces. A native property getter cannot do
// that — it returns a value, the first write copies, and the mutation only counts if it
// is handed back. Measured, not assumed:
//
//     GDScript member, started EMPTY -> member size after local resize: 8
//     native member,   started EMPTY -> member size after local resize: 0
//
// So a stage that mutates a buffer and writes it back on every path is unaffected,
// which is nearly all of them. A stage that mutates one and then returns early without
// writing it back used to get away with it, and no longer does. RemoveCrevice._squeeze
// was the one place that did; see the note there.
//
// Anything ported after this should check its write-back paths before trusting a green
// run on one fixture, because the failure is silent and shape-dependent.

#include "iw_math.h"

#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/color.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/typed_array.hpp>

#include <vector>

namespace godot {

class IWPipelineContext : public RefCounted {
	GDCLASS(IWPipelineContext, RefCounted)

protected:
	static void _bind_methods();

public:
	// Pixel classes in mask.
	enum {
		MASK_BACKGROUND = 0,
		MASK_EDGE = 1,
		MASK_SUBJECT = 2,
	};

	// Values of key_of that are not indices into keys.
	//
	// KEY_CLEAR marks a pixel that arrived fully transparent. It is background, but it
	// was not keyed out by anything and has no colour to un-blend against, so it must
	// not be confused with a pixel some entry claimed.
	enum {
		KEY_NONE = -1,
		KEY_CLEAR = -2,
	};

	// Values in blacked.
	enum {
		REGION_NONE = 0,
		REGION_CUT = 1,
		REGION_KEEP = 2,
	};

	// Minimum reach for the nearest-subject map. Coverage estimation needs a couple of
	// pixels of reach even when colour bleed is switched off.
	enum {
		MIN_SEARCH_RADIUS = 2,
	};

	// Guards divisions where the denominator can legitimately collapse to zero.
	//
	// Not a bound constant: ClassDB carries integer constants only, so the GDScript
	// stages that need this one keep their own copy on IWStackOperation. The two are
	// held together by the parity harness rather than by the compiler.
	static constexpr double EPSILON = 0.0001;

	// --- Buffers ---------------------------------------------------------

	// The source image, RGBA8, four bytes per pixel. Read-only to every stage but one:
	// Denoise replaces it, and everything below it in the stack then measures what it
	// left. A stage that does that owes the run one thing — key_dist is derived from
	// these bytes and is built once rather than on demand, so it has to be rebuilt
	// rather than left describing pixels that are gone. See IWStageKernels::denoise.
	PackedByteArray data;

	int64_t width = 0;
	int64_t height = 0;
	int64_t pixel_count = 0;

	// Every background colour in play this run, and the tolerance belonging to each.
	TypedArray<Color> keys;
	PackedFloat64Array key_tolerances;

	// Which of keys came from a picked island rather than from a Remove Colors list.
	// The distinction matters because an island's key is the colour of one spot the
	// user pointed at, which is a licence to remove that region rather than every pixel
	// of that colour in the image. See claiming_key.
	PackedByteArray key_is_island;

	// Largest per-channel distance from keys[0], per pixel. Empty until a stage builds
	// it.
	PackedFloat32Array key_dist;

	// One MASK_* per pixel, and the key that claimed each. Empty until a stage
	// classifies.
	PackedByteArray mask;
	PackedInt32Array key_of;

	// For every pixel, the index of the closest opaque subject pixel, or -1 if none
	// lies within search_radius.
	PackedInt32Array nearest;

	// Alpha per pixel, 0 to 1, before it is multiplied by the source's own.
	PackedFloat32Array coverage;

	PackedByteArray blacked;
	PackedByteArray protect;
	PackedByteArray strayed;
	PackedByteArray force_opaque;

	PackedFloat32Array stroke_inner;
	PackedFloat32Array stroke_outer;
	// Three floats per pixel when the stroke takes its colour from the image.
	PackedFloat32Array stroke_colors;

	int64_t edge_width = 0;
	int64_t bleed_radius = 0;
	bool decontaminate = false;
	int64_t search_radius = MIN_SEARCH_RADIUS;
	// Alpha zero, which is what the GDScript declared and not what Color's own default
	// is. Edge Cleanup overwrites it before anything reads it, so the value never
	// reaches an image — but it is recorded by the parity harness, and a default that
	// drifts is a default worth pinning.
	Color stroke_color = Color(0, 0, 0, 0);

	int64_t crevice_reach = 0;
	double crevice_tolerance = 0.0;

	// The weak-step count to record, left here as an out-parameter by flood_key_for
	// because returning it alongside the key would mean allocating an Array four times
	// per background pixel.
	int64_t flood_weak = 0;

	bool has_keying = false;

	// --- Lifecycle -------------------------------------------------------

	static Ref<IWPipelineContext> from_image(const Ref<Image> &source);
	void setup(const PackedByteArray &source_data, int64_t source_width, int64_t source_height);

	// --- Per-pixel primitives --------------------------------------------

	double distance_at(int64_t index, const Color &key) const;
	Color color_at(int64_t index) const;
	bool is_clear(int64_t index) const;
	double key_distance(int64_t index, int64_t k) const;
	int64_t claiming_key(int64_t index) const;
	int64_t flood_key_for(int64_t to, int64_t from_key, int64_t from_weak = 0);
	double local_maximum(int64_t index, int64_t radius, const Color &key) const;

	// --- Passes ----------------------------------------------------------

	PackedFloat32Array final_alpha() const;
	void ensure_coverage();
	bool has_classification() const;
	int64_t add_key(const Color &key, double tolerance, bool island);
	void ensure_key_dist();
	PackedInt32Array grow_edge_band(const PackedInt32Array &from, int64_t band_width);
	void rebuild_nearest();
	void compute_coverage(const PackedInt32Array &indices);
	PackedInt32Array all_indices() const;
	PackedInt32Array dilate(const PackedInt32Array &seeds, int64_t radius);
	void apply_regions_to_mask();
	void apply_regions_to_coverage();

	// --- Property plumbing -----------------------------------------------
	//
	// Godot needs a getter and a setter per exposed member, so the plain ones are
	// generated. The key list is the exception: it keeps a std::vector mirror alongside
	// the Array, because claiming_key and compute_coverage index it per pixel and
	// reaching through a Variant that many times would cost more than everything else
	// those loops do.

#define IW_ACCESSORS(m_type, m_name)                                 \
	void set_##m_name(const m_type &value) { m_name = value; }       \
	m_type get_##m_name() const { return m_name; }

	IW_ACCESSORS(PackedByteArray, data)
	IW_ACCESSORS(int64_t, width)
	IW_ACCESSORS(int64_t, height)
	IW_ACCESSORS(int64_t, pixel_count)
	IW_ACCESSORS(PackedFloat32Array, key_dist)
	IW_ACCESSORS(PackedByteArray, mask)
	IW_ACCESSORS(PackedInt32Array, key_of)
	IW_ACCESSORS(PackedInt32Array, nearest)
	IW_ACCESSORS(PackedFloat32Array, coverage)
	IW_ACCESSORS(PackedByteArray, blacked)
	IW_ACCESSORS(PackedByteArray, protect)
	IW_ACCESSORS(PackedByteArray, strayed)
	IW_ACCESSORS(PackedByteArray, force_opaque)
	IW_ACCESSORS(PackedFloat32Array, stroke_inner)
	IW_ACCESSORS(PackedFloat32Array, stroke_outer)
	IW_ACCESSORS(PackedFloat32Array, stroke_colors)
	IW_ACCESSORS(int64_t, edge_width)
	IW_ACCESSORS(int64_t, bleed_radius)
	IW_ACCESSORS(bool, decontaminate)
	IW_ACCESSORS(int64_t, search_radius)
	IW_ACCESSORS(Color, stroke_color)
	IW_ACCESSORS(int64_t, crevice_reach)
	IW_ACCESSORS(double, crevice_tolerance)
	IW_ACCESSORS(int64_t, flood_weak)
	IW_ACCESSORS(bool, has_keying)

#undef IW_ACCESSORS

	void set_keys(const TypedArray<Color> &value);
	TypedArray<Color> get_keys() const { return keys; }
	void set_key_tolerances(const PackedFloat64Array &value);
	PackedFloat64Array get_key_tolerances() const { return key_tolerances; }
	void set_key_is_island(const PackedByteArray &value);
	PackedByteArray get_key_is_island() const { return key_is_island; }

private:
	std::vector<Color> _key_cache;
	std::vector<double> _tolerance_cache;
	// Indices into keys of everything claiming_key may answer with, in the order they
	// were added — which is to say every key that is not an island. Kept alongside the
	// flag rather than derived from it because the flag would otherwise be tested per
	// key per pixel, and one picked region contributes a key per pixel it seeds.
	std::vector<int32_t> _claiming;

	void rebuild_key_caches();
};

} // namespace godot
