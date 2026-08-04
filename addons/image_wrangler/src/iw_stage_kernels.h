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

    // Upscale's Sharpen. Tightens the antialiased ramp round an object without moving the
    // edge that ramp describes. Returns a new RGBA8 image; `image` itself for an `amount`
    // of zero, which is the identity.
    //
    // One of the few kernels here handed an Image rather than a context, because the thing
    // it works on is a finished picture: what comes back off the network is pixels, not a
    // run in progress. See the note on the implementation for why the maths is a per-pixel
    // remap and not a filter.
    static Ref<Image> sharpen_alpha(const Ref<Image> &image, double amount);

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

    // NeuralRemoveBackground.process_context: turns a network's subject probability into
    // the same classification classify produces, with the background colour sampled from
    // the image rather than picked by the user.
    //
    // `probability` is the L8 answer off IWSegNet at whatever size it came back; it is
    // stretched over the image here. `contiguous` keeps only background the image border
    // can reach, so an enclosed pocket the network cut out — a highlight, an eye — stays
    // subject. No ncnn anywhere in this one, deliberately — it stays in the plain build,
    // and a build without the network merely has no stage that calls it.
    static void apply_segmentation(const Ref<IWPipelineContext> &ctx,
            const Ref<Image> &probability, double threshold, double tolerance,
            int64_t edge_width, bool contiguous);

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

	// Whether denoise above can run at all, which is whether the Open Image Denoise
	// runtime is in bin/.
	//
	// It is 49 MB and downloaded rather than committed, so a fresh checkout has every
	// other kernel here and not this one. The DLL is delay-loaded precisely so that its
	// absence costs one stage rather than the whole extension — see SConstruct — and this
	// is what the Denoise stage asks before offering to do anything.
	static bool denoise_available();

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

	// SmoothBlocks.process_context: flattens the seams a JPEG leaves every eight pixels.
	//
	// The other half of the same damage the colour smoother repairs, and the half that
	// lives in the brightness — which is exactly what that one leaves alone. The third
	// kernel that rewrites the source pixels, and it stands down unless it is running
	// above everything that keys, for the reason given on denoise above.
	static void smooth_blocks(const Ref<IWPipelineContext> &ctx, double threshold,
			double amount);

	// SmoothHalos.process_context: flattens the ripples a JPEG leaves beside a hard edge.
	//
	// Only squares holding an edge are touched, and inside them a pixel is averaged only
	// with neighbours on its own side of that edge — so `radius` can be raised without
	// the average ever reaching across the boundary. The last kernel that rewrites the
	// source pixels, and it stands down unless it is running above everything that keys,
	// for the reason given on denoise above.
	static void smooth_halos(const Ref<IWPipelineContext> &ctx, double threshold,
			int64_t radius, double strength);

	// HSVAdjust.process_context: turns the hue, scales the saturation and value, and
	// optionally tints the pixels inside each rectangle to one hue.
	//
	// `rects` is x,y,w,h per region and `shifts` is turn,saturation,value,colorize per
	// region, flattened for the usual reason — an Array of Resources read once per pixel
	// would cost more than the adjustment. Rewrites the source pixels, so it belongs
	// above everything that keys.
	static void adjust_hsv(const Ref<IWPipelineContext> &ctx, const PackedInt32Array &rects,
			const PackedFloat64Array &shifts);

    // RandomHSVTiles.process_context: finds every island of visible pixels and gives each
    // one its own random HSV shift.
    //
    // Takes numbers rather than a list of regions, which is the one kernel here that
    // works the other way round: the caller cannot name the regions because it does not
    // know them yet — finding them is the job. Hue is how far it may wander either way, 0
    // to 1. Saturation and value are the far end each may be pulled towards, 0 to 2 and 0
    // to 3, with 1 leaving them alone. Colorize is how far an island may be mixed towards
    // one flat hue, 0 to 1. Every one of the four is a ceiling, not a setting: each island
    // draws its own number between no change and that end. The seed makes the same image
    // come out the same way twice.
    //
    // Returns x, y, w, h per island: the smallest rectangle containing each one. Reads
    // the alpha the run currently shows, so where it sits in the stack decides what
    // counts as an object. Rewrites the source pixels, so the caller owes the run a
    // rebuild of the distance map afterwards.
    static PackedInt32Array random_hsv_tiles(const Ref<IWPipelineContext> &ctx,
            int64_t rng_seed, double hue_amount, double saturation_amount,
            double value_amount, double colorize_amount);

    // Posterize.process_context: cuts the image down to a small set of colours.
    //
    // `palette_mode` 0 is a fixed ladder of `levels` steps per channel, so a colour lands
    // in the same place whatever the picture is. `palette_mode` 1 is Wu's quantiser: one
    // pass counts the colours of the solid pixels, that count is split into `color_count`
    // boxes by repeatedly cutting whichever still holds the most error, and each box's mean
    // becomes a palette entry. An image holding fewer colours than asked for simply gets
    // fewer.
    //
    // `per_tile` gives every object its own palette rather than sharing one across the
    // sheet, which is what stops a sheet of unrelated sprites averaging into one muddy set
    // of colours. Objects are whatever iw::label_islands says they are, so this stage and
    // Random HSV Tiles cannot disagree about where one ends. A visible pixel no object
    // claimed — a speck too faint to have a solid middle — has no palette to belong to and
    // is left alone. Ignored under `palette_mode` 0, where the ladder is the same
    // everywhere by definition.
    //
    // `dither_mode` 1 is Floyd-Steinberg and works against either palette, walking
    // alternate rows backwards so a smooth gradient does not come out combed.
    // `dither_strength` scales the leftover colour before it is passed on; 0 is the same as
    // no dither at all.
    //
    // Reads the alpha the run currently shows, so where it sits in the stack decides which
    // pixels the palette is built from. [b]Alpha is never touched.[/b] A pixel that is not
    // visible is neither recoloured nor given any leftover colour, and none is passed into
    // one — so a large clear region cannot spend a palette entry or leave a rim.
    //
    // Rewrites the source pixels over the whole image, so the caller owes the run a full
    // rebuild of the distance map afterwards.
    static void posterize(const Ref<IWPipelineContext> &ctx, int64_t palette_mode,
            int64_t levels, int64_t color_count, bool per_tile, int64_t dither_mode,
            double dither_strength);

    // FillPinholes.process_context: closes every enclosed patch of not-fully-opaque pixels
    // of at most `max_area` pixels, colouring each from the solid pixels around it.
    //
    // Takes a number rather than a list of places, for the same reason random_hsv_tiles
    // does: finding them is the job. A patch that reaches the edge of the image is the
    // outside rather than a hole and is never touched, whatever its size, which is what
    // lets this run below a keyer without undoing it.
    //
    // A hole is anything short of full alpha, not merely what is clear: a speck's own soft
    // rim is part of it, counts toward the area, and comes out solid with the rest.
    //
    // Returns every index it filled. Reads the alpha the run currently shows, and writes
    // the source pixels, the coverage and the mask — so the caller owes the run a rebuild
    // of the distance map and of the nearest-subject map afterwards.
    static PackedInt32Array fill_pinholes(const Ref<IWPipelineContext> &ctx, int64_t max_area);

    // BrushEdit.process_context: lays down every stroke, in the order they were drawn.
    //
    // The strokes arrive flattened for the usual reason — `points` is x,y interleaved,
    // `starts` and `counts` bound each stroke's samples, and `radii`, `adding` and
    // `sharpness` carry one value per stroke.
    //
    // The samples are the path the pointer took, not the pixels it covered: the gap
    // between two of them is walked a pixel at a time here, so a stroke is continuous
    // however fast it was drawn. Within a stroke the stamps take the strongest, between
    // strokes each is applied to what the ones above it left.
    //
    // Returns every index it touched. Writes the coverage, the source alpha and the mask,
    // and never the colour — so the caller owes a rebuild_nearest and no distance-map
    // rebuild, the keys being measured against RGB.
    static PackedInt32Array paint_strokes(
            const Ref<IWPipelineContext> &ctx,
            const PackedInt32Array &points,
            const PackedInt32Array &starts,
            const PackedInt32Array &counts,
            const PackedInt32Array &radii,
            const PackedByteArray &adding,
            const PackedFloat64Array &sharpness);

    // The dock's live brush: adds one segment to a stroke in flight and returns the patch
    // of the composed preview it leaves, so the paint can be seen going down between two
    // mouse events.
    //
    // Not the same path as paint_strokes, and deliberately: that one goes through a
    // pipeline context and needs the whole stack re-composed behind it, which is far
    // longer than a drag can wait. This works on the pixels already on screen, over the
    // patch the segment can reach and no further. The stage's answer replaces all of it
    // when the button comes up.
    //
    // `strength` is how hard the stroke has hit each pixel so far, RF, updated in place by
    // taking the strongest dab; the patch is worked out from `base`, the untouched
    // picture, rather than from what the last segment left. That is what stops a soft
    // brush hardening as it overlaps its own rim along a stroke — see the note on the
    // definition. `beneath` is the source over the same region and may be null.
    static Ref<Image> paint_patch(
            const Ref<Image> &base,
            const Ref<Image> &strength,
            const Ref<Image> &beneath,
            const Vector2i &origin,
            const Vector2i &from,
            const Vector2i &to,
            int64_t radius,
            double sharpness,
            bool adding);

    // One stroke's own pixels in one colour, for the dock to lay over the preview so a
    // highlighted row can be found on the image.
    //
    // The same accumulation the paint uses, so what lights up is exactly what that stroke
    // is responsible for and as strongly as it is responsible for it — where a line drawn
    // at the brush's width would only say where the stroke went. Returns an RGBA8 image of
    // `size` covering `origin` onwards, or null when there is nothing to draw.
    static Ref<Image> stroke_overlay(
            const PackedInt32Array &points,
            int64_t radius,
            double sharpness,
            const Vector2i &origin,
            const Vector2i &size,
            const Color &color);

    // The same mark, taken off a strength map that already exists.
    //
    // What the dock uses while a drag is in flight, where paint_patch is accumulating the
    // stroke's strength anyway: the highlight is then a colouring of that map rather than
    // a second walk down a path that grows with every mouse event. The two produce the
    // same picture, being the same numbers.
    static Ref<Image> strength_overlay(const Ref<Image> &strength, const Color &color);

    // IWPacking: every separate object in the image, as the smallest rectangle round each.
    //
    // The same labelling RandomHSVTiles finds its tiles with — iw::label_islands, which
    // both go through — so a sheet coloured by one and packed by the other cannot
    // disagree about where one object ends and the next begins.
    //
    // Reads the alpha the run currently shows, so a keyed sheet gives one sprite per
    // object and an untouched one gives a single sprite the size of the image. Returns
    // x, y, w, h per island, in the order they were found.
    static PackedInt32Array find_islands(const Ref<IWPipelineContext> &ctx);

    // The same islands, each lifted out as an image of its own.
    //
    // Cut to the island rather than cropped to its rectangle: two objects that interlock
    // have overlapping boxes, and a sprite taken as a box would carry a slice of its
    // neighbour onto the packed sheet. Returns one RGBA8 image per island, in the same
    // order as find_islands.
    static TypedArray<Image> cut_islands(const Ref<IWPipelineContext> &ctx);

    // Visible pixels no island claimed, which the cut leaves off every sprite.
    static int64_t stray_pixel_count(const Ref<IWPipelineContext> &ctx);

    // RemoveMinimumArea: removes every island whose area is at or below `min_area`.
    //
    // Area is summed alpha, so a half-covered pixel counts a half. Labelled through any
    // visible pixel rather than through the solid part, which is what lets a speck made
    // entirely of fringe be measured and removed. Returns x, y, w, h per island removed.
    static PackedInt32Array remove_minimum_area(
            const Ref<IWPipelineContext> &ctx, int64_t min_area);

    // ExcludeTiles: keeps or removes whole tiles, by which ones the user picked.
    //
    // A tile is one object, or several joined into one where their rectangles overlap —
    // a rectangle is what this takes, so interlocking objects cannot be separated by it.
    //
    // `points` is x,y interleaved, one pair per pick. `active` is one byte per pick, zero
    // for one switched off; empty or short means the rest count. Every point is resolved
    // to its tile either way. `mode` is 0 to remove the picked tiles and 1 to remove
    // everything else. Returns "bounds", the rectangle of every tile found, and "picked",
    // which tile each point landed on or -1.
    static Dictionary exclude_tiles(
            const Ref<IWPipelineContext> &ctx, const PackedInt32Array &points,
            const PackedByteArray &active, int64_t mode);

    // IWPacking's Round Edges and Color Regions: a normal map for a packed sheet, worked
    // out from the shape of each sprite.
    //
    // Handed a sheet rather than a context because a packed sheet is a finished picture
    // assembled out of many runs, and what tells one sprite from the next is the rectangle
    // list rather than any labelling still in hand. `rects` is x, y, w, h per sprite, the
    // same flattening the packer already keeps. Every sprite is worked out inside its own
    // rectangle and nowhere else, which is what stops one leaning on whatever it was packed
    // against.
    //
    // `roll_off` is how far in from the outline the rounding reaches, in pixels. `curve` is
    // an IWPacking.NormalCurve index. `strength` is how far the surface tips over, measured
    // against the roll-off so the slope holds when that is dragged.
    //
    // `color_tolerance` below zero rounds off the outline alone, which is Round Edges. At
    // zero or above a colour boundary inside the sprite is rounded off too, and the number
    // is how far apart two colours have to be to count as one — that, and nothing else, is
    // Color Regions.
    //
    // Returns a new RGBA8 image the size of the sheet, flat wherever no sprite covers and
    // carrying the sheet's own alpha throughout.
    static Ref<Image> normal_from_shape(
            const Ref<Image> &sheet,
            const PackedInt32Array &rects,
            int64_t roll_off,
            int64_t curve,
            double strength,
            double color_tolerance,
            bool green_down);

    // IWPacking's Brightness: the same map, worked out from how light and dark the sprite's
    // own colours are. Same rectangles and the same guarantee as normal_from_shape.
    //
    // Two scales added together. The fine one is a gradient of the brightness as it is and
    // picks up line work; the coarse one is the same gradient over a mean `coarse_size`
    // pixels across and picks up the large form. Either strength at zero skips that pass.
    static Ref<Image> normal_from_brightness(
            const Ref<Image> &sheet,
            const PackedInt32Array &rects,
            int64_t coarse_size,
            double coarse_strength,
            double fine_strength,
            bool green_down);

    // Merges `detail` into `base`, sprite by sprite, for IWPacking's stack of normal map
    // generators. Same rectangles and the same guarantee as the two above; the space
    // between sprites keeps whatever `base` had there.
    //
    // `mode` 0 is slope blending, which adds the two surfaces' slopes. That is the same
    // answer as adding the two height surfaces and working the normal out once, so neither
    // layer's detail is averaged away — right when both maps describe the same surface as
    // peers.
    //
    // `mode` 1 is reoriented mapping, which rotates `detail` so it sits on `base`'s surface
    // rather than on a flat plane — right when `base` is a shape and `detail` is fine
    // detail meant to follow it.
    //
    // `opacity` scales the detail's slope before either mode runs, so 0 gives back `base`
    // exactly in both and 1 lets the detail through in full. Returns `base` unchanged when
    // there is nothing to merge, or when the two maps are not the same size.
    static Ref<Image> combine_normals(
            const Ref<Image> &base,
            const Ref<Image> &detail,
            const PackedInt32Array &rects,
            int64_t mode,
            double opacity);

    // Spreads the normals found just inside each sprite's outline out to the rim itself.
    //
    // The outermost pixels of a sprite are where every generator is least sure: a shape
    // kernel has almost no room left to roll off in, a brightness one is reading colours
    // half-covered by antialiasing, and a network is guessing at an edge. The result is a
    // rim of noise around art that is otherwise clean. This replaces those pixels with the
    // nearest one that is properly inside, so the rim carries the shape found a little way
    // in rather than whatever the outline produced.
    //
    // `inner_reach` is how deep the rim is taken to be, in pixels, and so how far in the
    // replacements are read from. Same rectangles and the same guarantee as the generators.
    //
    // [b]Alpha is never touched.[/b] The silhouette is what it was — only which way those
    // pixels face changes. A sprite with nothing deeper than `inner_reach` anywhere in it
    // has nothing to spread from and is left exactly as it arrived.
    static Ref<Image> normal_clean_edges(
            const Ref<Image> &map,
            const PackedInt32Array &rects,
            int64_t inner_reach);

    // A copy of `map` with green pointing the other way, which is the one thing two engines
    // never agree on. Red, blue and alpha are untouched.
    //
    // Applied to the finished stack rather than to each generator, so combining never has to
    // reason about which way round its inputs were written.
    static Ref<Image> normal_flip_green(const Ref<Image> &map);
};

} // namespace godot
