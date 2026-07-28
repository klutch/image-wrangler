#pragma once

// The stages' inner loops, native.
//
// The operations themselves stay in GDScript, and deliberately: they own the settings
// Resources, the schema the dock builds its form from, the progress reporting and the
// prerequisite notes, and every one of those would fight the engine if it moved. The
// sidecar codec filters on PROPERTY_USAGE_SCRIPT_VARIABLE, which a GDExtension property
// never carries; the dock's worker snapshot rebuilds each stage through
// `stage.get_script().new()`, which returns null for a native class and would silently
// drop the stage from the preview. Neither is worth fighting for a class that does no
// per-pixel work.
//
// So the seam is one call deep. A stage reads its settings, flattens whatever lists it
// holds into packed arrays — which it already did, because a Resource property lookup
// in a per-pixel loop was never affordable either — reports progress, and hands the
// flat arrays down here.

#include "iw_pipeline_context.h"

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>

namespace godot {

class IWStageKernels : public RefCounted {
	GDCLASS(IWStageKernels, RefCounted)

protected:
	static void _bind_methods();

public:
	// PolygonEditOp._merge_into_blacked.
	//
	// The regions arrive flattened: `points` is x,y interleaved across every region,
	// `starts` and `counts` say where each region's vertices begin and how many there
	// are, and `adding` is one byte per region. Rasterising from an Array of Resources
	// would mean a Variant hop per vertex per row.
	static void rasterise_regions(
			const Ref<IWPipelineContext> &ctx,
			const PackedInt32Array &points,
			const PackedInt32Array &starts,
			const PackedInt32Array &counts,
			const PackedByteArray &adding);

	// RefineEdges._clip_alpha. Stretches coverage so `low` and below lands on clear and
	// `high` and above on solid, in place.
	static void clip_alpha(const Ref<IWPipelineContext> &ctx, double low, double high);

	// RefineEdges._guided_refine: the He/Sun/Tang guided filter, with the
	// distance-from-key map as the guide. Returns the refined alpha rather than writing
	// it, because the caller decides whether the filter ran at all.
	static PackedFloat32Array guided_refine(
			const PackedFloat32Array &coverage,
			const PackedFloat32Array &guide,
			int64_t width,
			int64_t height,
			int64_t radius);

	// RemoveCrevice._squeeze: crosses every neck the budget allows and returns every
	// pixel it claimed.
	static PackedInt32Array squeeze(const Ref<IWPipelineContext> &ctx);

	// RemoveBackground._classify: sorts every pixel into background, antialiased edge,
	// or subject, and records which background colour claimed each.
	static void classify(const Ref<IWPipelineContext> &ctx, bool contiguous, int64_t edge_width);

	// IslandPickerOp._subtract: floods every Subtract island into the background and
	// mattes what it opened.
	//
	// The tolerances arrive float32 because the caller collects them in a
	// PackedFloat32Array, and flood_protect's arrive float64 because that one collects
	// them in an Array[float]. The difference is not decorative — it is the last bit of
	// every tolerance comparison in each flood — so the two signatures keep it.
	static PackedInt32Array flood_islands(
			const Ref<IWPipelineContext> &ctx,
			const PackedInt32Array &seeds,
			const PackedFloat32Array &tolerances);

	// IslandPickerOp._protect: floods every Add island and marks what it protects.
	//
	// Its own flood rather than a mode inside the classification, because the two cannot
	// share a queue. A background flood claims pixels once and never revisits them; this
	// one has to be free to reach pixels that flood already took, since those are
	// precisely the ones worth protecting.
	static PackedInt32Array flood_protect(
			const Ref<IWPipelineContext> &ctx,
			const PackedInt32Array &seeds,
			const PackedFloat64Array &tolerances);

	// EdgeCleanup._restore_edges: gives a solid pixel sitting straight against a clear
	// one the matte it never got. Returns the new coverage rather than editing in place,
	// because a pixel restored early in the scan must not become the evidence that its
	// neighbour needs restoring too.
	static PackedFloat32Array restore_edges(const Ref<IWPipelineContext> &ctx);

	// EdgeCleanup._inner_band / _outer_band: strength per pixel for each stroke, or an
	// empty array when that stroke puts no paint down anywhere.
	static PackedFloat32Array inner_band(
			const PackedFloat32Array &alpha, double stroke_width, double feather,
			double strength, int64_t width, int64_t height);
	static PackedFloat32Array outer_band(
			const PackedFloat32Array &alpha, double stroke_width, double feather,
			double strength, int64_t width, int64_t height);

	// EdgeCleanup._auto_stroke_colors: three floats per pixel, sampled from an
	// alpha-weighted blur of the subject and then darkened.
	static PackedFloat32Array auto_stroke_colors(
			const Ref<IWPipelineContext> &ctx,
			const PackedFloat32Array &alpha,
			const PackedFloat32Array &inner,
			const PackedFloat32Array &outer,
			int64_t radius);

	// Denoise.process_context: replaces ctx->data with an Open Image Denoise pass over
	// its RGB. Alpha is not colour, is never shown to the filter, and comes through
	// byte-for-byte.
	//
	// The one kernel that rewrites the source pixels. What makes that admissible is
	// entirely a property of its caller: the stage stands down unless it is running
	// above everything that keys, so no map has yet been derived from the bytes it
	// replaces. See Denoise.prerequisite_note.
	//
	// `quality` is a DenoiseSettings.Quality index rather than an OIDN constant — the
	// two are mapped by hand in iw_denoise_kernels.cpp, because OIDN's own values are
	// neither zero-based nor consecutive. `blend` mixes the result back over the
	// original, 0 to 1, and 0 is an exact identity.
	//
	// Returns false and leaves ctx->data alone when OIDN could not be brought up or the
	// filter failed, having pushed an error saying which. A failure is a stage that did
	// nothing, never a corrupted image.
	static bool denoise(const Ref<IWPipelineContext> &ctx, int64_t quality, double blend);

	// RemoveLines.process_context: erases every structure the silhouette is too thin to
	// have earned, and returns the indices it took.
	//
	// A morphological opening by a square of side `thickness + 1` — the smallest square a
	// shape has to have room for to count as thick enough. `detached_only` chooses what
	// happens to what is left: false puts the square back, so a thin part goes wherever it
	// is, and true floods each shape back from wherever a square did fit, so a shape thick
	// anywhere survives whole.
	//
	// The one kernel that erases on the strength of shape alone rather than colour, which
	// is why it needs no key and answers false to needs_keying. It writes coverage, and
	// the mask and key list where a classification exists; the caller owes the run a
	// rebuild_nearest afterwards, and deliberately not a compute_coverage. See the note on
	// RemoveLines.process_context for why that second one would undo the stages above it.
	static PackedInt32Array remove_lines(
			const Ref<IWPipelineContext> &ctx, int64_t thickness, bool detached_only);

	// SmoothColor.process_context: flattens the colour of ctx->data while leaving its
	// brightness and its alpha alone.
	//
	// Both colour parts are smoothed with the brightness as their guide, so they follow
	// the edges the brightness has rather than the blurred ones a JPEG gave them. The
	// second kernel that rewrites the source pixels, and it stands down unless it is
	// running above everything that keys, for the reason given on denoise above.
	static void smooth_color(const Ref<IWPipelineContext> &ctx, int64_t radius,
			double strength, double amount);
};

} // namespace godot
