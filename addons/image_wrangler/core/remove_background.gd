@tool
class_name RemoveBackground
extends IWStackOperation

## Removes a flat background colour while preserving the antialiased silhouette.
##
## The stage the rest of the stack is measured against: it establishes the keys,
## decides what is background, and produces the alpha every stage below it refines.
##
## Naively deleting every background-coloured pixel fails in one of two ways: a
## tight threshold keeps the half-blended edge pixels and leaves a fringe, a loose
## one eats the soft edge and leaves a jagged cutout. Neither is fixable by tuning
## the threshold, because the edge is not a mask — it is a matte.
##
## An antialiased pixel is a blend of the subject and the background:
## [codeblock]
##     C = a * F + (1 - a) * K
## [/codeblock]
## [code]C[/code] is the pixel we can see, [code]K[/code] the background colour,
## [code]F[/code] the subject colour hiding underneath, and [code]a[/code] the pixel
## coverage we want back as alpha.
##
## [b]Recovering coverage.[/b] Every channel is blended with the same [code]a[/code],
## so a pixel's largest per-channel distance from [code]K[/code] is exactly
## [code]a[/code] times the subject's own distance from [code]K[/code]. Divide one by
## the other and the unknown [code]F[/code] cancels out. The divisor comes from the
## nearest fully opaque pixel, so the estimate stays local and works whether the
## subject there is far from the key colour or barely off it. See
## [method IWPipelineContext.compute_coverage].
##
## [b]Finding the edge.[/b] Coverage alone cannot say whether a half-key-coloured
## pixel is a half-covered distant subject or a fully covered near-key one — the two
## are numerically identical. Colour thresholds cannot break that tie, so geometry
## does: antialiasing lives in a thin band hugging the background, so pixels are
## classified by their distance from the flood-filled background rather than by how
## close to the key they are. See [method _classify].
##
## [b]More than one background colour.[/b] Every entry in
## [member RemoveBackgroundSettings.remove_colors] is offered to the image border, so
## a frame with different backgrounds down opposite edges floods from both — but only
## where they meet the border, since that is the only place the flood may start while
## [member RemoveBackgroundSettings.contiguous] is set. A region enclosed by the
## subject is not reached by listing its colour, no matter how exactly it is listed;
## that is what [IslandPickerOp] is for.
##
## Each carries its own tolerance rather than sharing a global one, because the number
## that swallows a speckled JPEG background would eat into the subject beside a clean
## flat one. Every pixel therefore remembers which key claimed it, and its distance,
## its coverage and its decontamination are all measured against that key and that
## key's tolerance.
##
## [b]Killing the fringe.[/b] Correct alpha is only half the job. The RGB of a
## half-covered pixel is still half background, and that residue is what shows up as
## an outline once the image is composited. So the background is un-blended back out:
## [codeblock]
##     F = (C - (1 - a) * K) / a
## [/codeblock]
## Finally the subject colour is bled outwards into the fully transparent pixels.
## Their alpha is zero, but bilinear filtering and mipmaps still sample their RGB,
## which is how the background creeps back into an edge that looked clean in the
## file. Both are settings here and both are applied by [IWCompose], which is the
## only pass that writes colour.
##
## [b]Running it twice.[/b] A source pixel that arrives fully transparent is treated
## as open ground: it is already removed, so every flood crosses it, it grows no edge
## band, and it stays transparent whether or not the flood reached it. Without that, a
## second pass over this stack's own output would be fenced in by the first — the
## bleed above leaves subject colour in the RGB of every transparent pixel, so the
## border of a processed image reads as plant green or skin tone rather than as
## background, and the flood dies at the frame. Crossing a hole also re-offers the far
## side to the whole Remove Colors list, since transparency carries no key to inherit.
##
## [b]Getting into a nook too narrow to flood[/b] is [RemoveCrevice], which is a stage
## of its own below this one. The rule still runs inside this flood — a squeeze is
## measured against the tolerance of whichever entry the flood is carrying at that
## moment — but the terms come off the context rather than out of these settings, so
## whichever [RemoveCrevice] is above says what they are and every flood below obeys
## the same ones. A stack with none of them keys strictly within each colour's own
## tolerance.
##
## [b]What the other stages do.[/b] Tidying the alpha afterwards is [RefineEdges];
## picking a region by hand is [IslandPickerOp] or [PolygonEditOp]; restoring a hard
## edge and outlining the result is [EdgeCleanup]. Placing a second one of these below
## another adds its colours to the keys already registered rather than starting again.

## This operation's tunables. Swapped by the dock for the image on screen; see
## [RemoveBackgroundSettings].
var settings: RemoveBackgroundSettings


func _init() -> void:
	settings = RemoveBackgroundSettings.new()


func get_operation_name() -> String:
	return "Remove Background"


func get_operation_id() -> StringName:
	return &"remove_background"


func get_settings() -> Resource:
	return settings


func set_settings(new_settings: Resource) -> void:
	var typed := new_settings as RemoveBackgroundSettings
	if typed == null:
		push_error("Image Wrangler: RemoveBackground was handed settings of the wrong type.")
		return
	settings = typed


func make_settings() -> Resource:
	return RemoveBackgroundSettings.new()


func get_output_suffix() -> String:
	return "_nobg"


## The stage that establishes the keys, so nothing has to be keyed above it.
func needs_keying() -> bool:
	return false


## And the only one that does: the mask everything else builds on is made here.
func establishes_keying() -> bool:
	return true


## Most of a run by a distance: the flood and the nearest-subject map between them
## are the bulk of the work whatever else is in the stack.
func stage_weight() -> float:
	return 1.0


## Convenience entry point for code that just wants the default behaviour.
static func remove_background(source: Image, key := Color.WHITE) -> Image:
	var operation := RemoveBackground.new()
	operation.settings.remove_colors.set_only(key)
	return operation.process_image(source)


func process_context(ctx: IWPipelineContext) -> void:
	# What the final write needs to know. Owned here because the fringe removal and
	# the bleed are both about the background this stage identified.
	ctx.edge_width = maxi(ctx.edge_width, settings.edge_width)
	ctx.bleed_radius = maxi(ctx.bleed_radius, settings.bleed_radius)
	ctx.decontaminate = ctx.decontaminate or settings.decontaminate
	ctx.search_radius = maxi(
			maxi(ctx.bleed_radius, ctx.edge_width), IWPipelineContext.MIN_SEARCH_RADIUS)

	# Fractions along the way, for whatever is drawing the progress bar. Hand-set
	# rather than evenly spaced, because the passes are nothing like equal: the flood
	# and the nearest-subject map between them are most of the work, and a bar that
	# pretended otherwise would crawl and then leap.
	#
	# Each is also where the run gives up if it has been asked to. Between them it
	# cannot: a pass runs to its end once started, so how quickly a cancel takes hold
	# is however long the longest pass has left.
	if not report_progress(0.02):
		return

	var first_key := _build_keys(ctx)
	# No colours at all is a coherent request for no keying here — the stack may key
	# elsewhere, or not at all, and the regions and the stroke owe this stage nothing.
	if first_key < 0 and not ctx.has_keying:
		return
	if not report_progress(0.10):
		return

	_classify(ctx, first_key)
	if not report_progress(0.48):
		return

	# Folded into the mask rather than into the alpha at the end, so that everything
	# downstream treats these pixels correctly without being told about regions at
	# all: coverage reads them off the mask, the nearest-subject map picks its bleed
	# sources from it, and the final write follows.
	#
	# Applied after the classification for the same reason a cut is left hard — a band
	# already grown into the region is overwritten rather than left as a soft rim
	# inside a hard edge.
	ctx.apply_regions_to_mask()
	if not report_progress(0.62):
		return

	ctx.rebuild_nearest()
	if not report_progress(0.75):
		return

	# Alpha is settled for the whole image here, because the refinement below is a
	# neighbourhood operation and cannot run a pixel at a time.
	ctx.compute_coverage(ctx.all_indices())
	report_progress(1.0)


## Registers every enabled Remove Color as a key, and returns the index of the first
## one — or -1 when the list is empty or entirely switched off.
##
## Appended to whatever is already registered, so a second one of these adds its
## colours instead of replacing the first's. The returned index is where this stage's
## own colours begin, which is what the border flood needs to know.
func _build_keys(ctx: IWPipelineContext) -> int:
	var first := -1
	if settings.remove_colors == null:
		return first
	for entry in settings.remove_colors.entries:
		if entry == null or not entry.enabled:
			continue
		var index := ctx.add_key(entry.color, entry.color_tolerance, false)
		if first < 0:
			first = index
	return first


## Sorts every pixel into background, antialiased edge, or subject, and records which
## background colour claimed it.
##
## Two passes over one queue. The first claims the background itself — pixels within
## their key's own tolerance, flood filled inwards from the image border when
## [member RemoveBackgroundSettings.contiguous] is set, which is what keeps unpicked
## enclosed regions opaque. The second walks
## [member RemoveBackgroundSettings.edge_width] steps further in from that background
## and calls what it touches the antialiased band, inheriting the key it grew from.
##
## Classifying by distance-from-background rather than by colour is the whole trick. A
## pixel's colour genuinely cannot distinguish a half-covered distant subject from a
## fully covered near-key one, but position can: real antialiasing hugs the background
## it blended with.
##
## Additive, so a second one of these narrows what is left rather than starting over:
## a pixel already claimed is left alone, and the band grows only from what this pass
## took.
func _classify(ctx: IWPipelineContext, first_key: int) -> void:
	var width := ctx.width
	var height := ctx.height
	var pixel_count := ctx.pixel_count
	var contiguous := settings.contiguous
	var background := IWPipelineContext.MASK_BACKGROUND
	var key_none := IWPipelineContext.KEY_NONE
	var key_clear := IWPipelineContext.KEY_CLEAR

	var fresh := ctx.mask.is_empty()
	var mask := ctx.mask
	var key_of := ctx.key_of
	if fresh:
		mask.resize(pixel_count)
		mask.fill(IWPipelineContext.MASK_SUBJECT)
		key_of.resize(pixel_count)
		key_of.fill(key_none)

	# Each pixel is claimed at most once, so the queue can be sized up front and used
	# as a plain FIFO with no wraparound.
	var queue := PackedInt32Array()
	queue.resize(pixel_count)
	var head := 0
	var tail := 0
	# How many weak pixels in a row the flood crossed to reach each pixel; zero on
	# anything solidly background. See [method IWPipelineContext.flood_key_for].
	var weak_steps := PackedInt32Array()
	weak_steps.resize(pixel_count)

	if contiguous:
		# Every border pixel is offered to the whole Remove Colors list, so a frame
		# with one background down one edge and another down the opposite edge floods
		# from both without either needing to be picked as an island.
		#
		# Transparency is checked before colour, which flood_key_for does: a
		# transparent pixel's RGB is not a colour anyone chose. This stack bleeds
		# subject colour into what it makes transparent, so the border of an image it
		# has already processed is full of plant green or skin tone — matching that
		# against the list would be reading a value that is there to stop filtering
		# artefacts, not to describe a background.
		for x in width:
			var top := x
			if mask[top] != background:
				var top_key := ctx.flood_key_for(top, key_clear)
				if top_key != key_none:
					mask[top] = background
					key_of[top] = top_key
					queue[tail] = top
					tail += 1
			var bottom := (height - 1) * width + x
			if mask[bottom] != background:
				var bottom_key := ctx.flood_key_for(bottom, key_clear)
				if bottom_key != key_none:
					mask[bottom] = background
					key_of[bottom] = bottom_key
					queue[tail] = bottom
					tail += 1
		for y in height:
			var row_start := y * width
			if mask[row_start] != background:
				var start_key := ctx.flood_key_for(row_start, key_clear)
				if start_key != key_none:
					mask[row_start] = background
					key_of[row_start] = start_key
					queue[tail] = row_start
					tail += 1
			var row_end := row_start + width - 1
			if mask[row_end] != background:
				var end_key := ctx.flood_key_for(row_end, key_clear)
				if end_key != key_none:
					mask[row_end] = background
					key_of[row_end] = end_key
					queue[tail] = row_end
					tail += 1

		# 4-connected on purpose: 8-connectivity leaks through diagonal hairlines in
		# thin subjects such as lettering or wire-frame art.
		#
		# Written out four times rather than through a helper: the marking has to land
		# in these arrays, and handing a Packed array to a function to be written
		# through would only ever mutate the copy that function got.
		while head < tail:
			var index := queue[head]
			head += 1
			var claimed_by := key_of[index]
			var weak_here := weak_steps[index]
			var x := index % width
			@warning_ignore("integer_division")
			var y := index / width
			if x > 0:
				var left := index - 1
				if mask[left] != background:
					var took := ctx.flood_key_for(left, claimed_by, weak_here)
					if took != key_none:
						mask[left] = background
						key_of[left] = took
						weak_steps[left] = ctx.flood_weak
						queue[tail] = left
						tail += 1
			if x < width - 1:
				var right := index + 1
				if mask[right] != background:
					var took := ctx.flood_key_for(right, claimed_by, weak_here)
					if took != key_none:
						mask[right] = background
						key_of[right] = took
						weak_steps[right] = ctx.flood_weak
						queue[tail] = right
						tail += 1
			if y > 0:
				var up := index - width
				if mask[up] != background:
					var took := ctx.flood_key_for(up, claimed_by, weak_here)
					if took != key_none:
						mask[up] = background
						key_of[up] = took
						weak_steps[up] = ctx.flood_weak
						queue[tail] = up
						tail += 1
			if y < height - 1:
				var down := index + width
				if mask[down] != background:
					var took := ctx.flood_key_for(down, claimed_by, weak_here)
					if took != key_none:
						mask[down] = background
						key_of[down] = took
						weak_steps[down] = ctx.flood_weak
						queue[tail] = down
						tail += 1
	else:
		# Without contiguity there is nothing to flood from, so islands have no
		# meaning here: every pixel matching a Remove Color already qualifies.
		for i in pixel_count:
			if mask[i] == background:
				continue
			var claimed := ctx.claiming_key(i)
			if claimed != key_none:
				mask[i] = background
				key_of[i] = claimed
				queue[tail] = i
				tail += 1

	# Transparency the flood never reached is still transparent. Marked without being
	# queued: there is nothing behind a transparent pixel to make opaque, so leaving
	# it classed as subject would have coverage fill in every enclosed hole the moment
	# an image was processed a second time — but it grows no band either, since it has
	# no colour anything could be matted against.
	if fresh:
		for i in pixel_count:
			if mask[i] != background and ctx.is_clear(i):
				mask[i] = background
				key_of[i] = key_clear

	# A pixel the flood only squeezed through is not background — it is the
	# antialiasing of the two walls it passed between, so it is part subject. Handing
	# it to the band gives it partial alpha from the usual coverage maths, where
	# calling it background would cut a hard notch out of the crevice mouth. It stays
	# in the queue, so the band still grows from it.
	#
	# Everything the path reached [i]after[/i] that crossing goes with it, which is
	# what makes straying as cheap as the setting claims: the coverage maths decides
	# those pixels by colour rather than the flood deciding them by arrival, so
	# background beyond a crevice still measures as fully background and comes out,
	# and subject the flood should never have got to measures as covered and keeps
	# its alpha instead of being cut. Marking only the crossing itself left every
	# pixel past it hard background, which is exactly where the damage was.
	#
	# Never a pixel that arrived transparent, though: it has no key to be matted
	# against, and the band pass leaves it alone for the same reason.
	#
	# The rule itself belongs to [RemoveCrevice] now, and this obeys whatever one of
	# those above it declared — a flood squeezing on different terms from the pass that
	# set the terms would be arbitrary. A stack with none of them keys strictly within
	# each colour's own tolerance, which is what a reach of zero always meant.
	if ctx.crevice_reach > 0:
		var strayed := ctx.strayed
		if strayed.size() != pixel_count:
			strayed.resize(pixel_count)
		for i in pixel_count:
			if mask[i] == background and weak_steps[i] > 0 and key_of[i] >= 0:
				mask[i] = IWPipelineContext.MASK_EDGE
				strayed[i] = 1
		ctx.strayed = strayed

	ctx.mask = mask
	ctx.key_of = key_of

	# The queue still holds every pixel this pass claimed, in the order it claimed
	# them, so growing the band from it walks outwards in lock-step and depth stays
	# correct.
	queue.resize(tail)
	ctx.grow_edge_band(queue, settings.edge_width)


func get_settings_schema() -> Array[Dictionary]:
	return [
		{
			"property": &"remove_colors",
			"type": SettingType.COLOR_LIST,
			"tooltip": "The background colors to key out, each with its own tolerance.
Pick them off the preview, or add one and set it by hand. An image with
two flat backgrounds needs two entries: one tolerance loose enough for a
speckled one would eat into the subject beside the clean one.

The flood spreads through every listed color, so entries work together —
a white plate around a green stem needs both listed, and taking white out
stops green working too, because nothing reaches it from the border.

Background walled off by opaque subject is never reached, whatever you
list. Add an Island Picker for that instead.

Where two entries could both claim a pixel, the higher one wins.",
		},
		{
			"property": &"edge_width",
			"label": "Edge Width",
			"type": SettingType.INT,
			"min": 0,
			"max": 16,
			"step": 1,
			"tooltip": "How many pixels of antialiasing to rebuild around the subject.
2 suits ordinary antialiasing. Raise it for soft edges, glows or
drop shadows; set it to 0 for a hard-edged cutout.

Remove Crevice and Island Picker take their band width from here too, so
every edge in the image is matted to the same depth.",
		},
		{
			"property": &"contiguous",
			"label": "Only Outer Background",
			"type": SettingType.BOOL,
			"tooltip": "Flood fill inwards from the image border, so regions enclosed by the
subject (eyes, highlights, gaps in lettering) stay opaque.

This is also what makes Remove Colors border-only: an entry seeds the flood
where its color meets the border, and nowhere else. Turn it off and every
listed color is removed wherever it appears — enclosed regions included.",
		},
		{
			"property": &"decontaminate",
			"label": "Remove Color Fringe",
			"type": SettingType.BOOL,
			"tooltip": "Un-blends the background color out of partially transparent pixels.
This is what stops an outline appearing once the image is composited.",
		},
		{
			"property": &"bleed_radius",
			"label": "Color Bleed",
			"type": SettingType.INT,
			"min": 0,
			"max": 64,
			"step": 1,
			"tooltip": "Pushes subject color into fully transparent pixels, in pixels.
Texture filtering and mipmaps sample RGB even where alpha is zero, so
without this the background can bleed back into the edge on screen.",
		},
	]


## Pulls every Remove Color tolerance into range, on top of what the schema clamps.
##
## The schema cannot reach these: it names properties on the settings Resource, and a
## tolerance lives one level down, on an entry. Without this a hand-edited file could
## carry 50 while the slider clamps its display to
## [constant RemoveColorEntry.MAX_TOLERANCE] — the form and the processing silently
## disagreeing, which is the exact failure the base method exists to prevent.
func clamp_settings_to_schema(target: Resource = null) -> void:
	super(target)
	if target == null:
		target = get_settings()
	var typed := target as RemoveBackgroundSettings
	if typed == null:
		return
	if typed.remove_colors != null:
		for entry in typed.remove_colors.entries:
			if entry != null:
				entry.color_tolerance = clampf(entry.color_tolerance, 0.0, RemoveColorEntry.MAX_TOLERANCE)
