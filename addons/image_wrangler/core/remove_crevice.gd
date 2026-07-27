@tool
class_name RemoveCrevice
extends IWStackOperation

## Reaches into gaps the background flood was walled out of.
##
## A crevice whose neck is nothing but the antialiasing of the two walls meeting
## has no pixel in it that is solidly background, so a flood that only crosses
## pixels within their key's own tolerance stops at the mouth and leaves the gap
## filled in.
##
## [b]Canny's double threshold, applied to region growing rather than to edge
## linking.[/b] A pixel within its key's own tolerance is solid background and
## resets the count; one merely within [member RemoveCreviceSettings.crevice_tolerance]
## may still be crossed, but only [member RemoveCreviceSettings.crevice_reach]
## of them in a row before solid background is needed again. That is what gets
## through the neck while stopping the flood wandering off across a pale subject,
## which an unbounded weak threshold would do.
##
## [b]A pixel the flood only squeezed through is not background.[/b] It is the
## antialiasing of the two walls it passed between, so it is part subject: it goes
## to the edge band and gets partial alpha from the usual coverage maths, where
## calling it background would cut a hard notch out of the crevice mouth.
##
## [b]It runs on its own.[/b] Given a classification it grows that; given none it
## works one out from the alpha it can see — what is already transparent is
## background, what is solid is subject, what is in between is the band — and reads
## the background colour back off the source, which still holds it wherever a stage
## above did the removing. Either way it leaves a complete classification behind for
## whatever comes next, and it carries its own Edge Width for the band it rebuilds.
##
## The one thing it cannot recover is a background that was already gone before the
## file was opened: what was there is not in the source to be read, and the colour
## left in its place is the last run's bleed, which is subject colour wearing a
## background's position. Put a Remove Background above it for that.

var settings: RemoveCreviceSettings

## Read from inside the per-pixel loop, so they are copied out of the settings
## Resource once per run rather than resolved through it millions of times.
var _reach := 0
var _tolerance := 0.0

## Colours this run has already registered a key for, keyed by the colour rounded to
## its eight-bit form. A flat background is one entry however many pixels it has.
var _recovered: Dictionary = {}

## Most keys this operation will invent for one run.
##
## A background flat enough to key out is a handful of colours; a noisy one could
## otherwise register a key per speckle, and every one of those is an array entry the
## rest of the run carries. Past the cap the first one is reused, which errs towards
## reaching less far rather than towards reaching somewhere wrong.
const _MAX_RECOVERED_KEYS := 64


func _init() -> void:
	settings = RemoveCreviceSettings.new()


func get_operation_name() -> String:
	return "Remove Crevice"


func get_operation_id() -> StringName:
	return &"remove_crevice"


func get_settings() -> Resource:
	return settings


func set_settings(new_settings: Resource) -> void:
	var typed := new_settings as RemoveCreviceSettings
	if typed == null:
		push_error("Image Wrangler: RemoveCrevice was handed settings of the wrong type.")
		return
	settings = typed


func make_settings() -> Resource:
	return RemoveCreviceSettings.new()


func get_settings_schema() -> Array[Dictionary]:
	return [
		{
			"property": &"crevice_reach",
			"label": "Crevice Reach",
			"type": SettingType.INT,
			"min": 0,
			"max": 32,
			"step": 1,
			"tooltip": "How many near-background pixels in a row may be crossed before solid\nbackground is needed again, so it needs to be at least as long as the\nconstriction it has to get through. 0 does nothing at all.\n\nWhat it gets into is a nook whose opening is nothing but the antialiasing of\nthe two walls meeting, which ordinary keying stops outside.",
		},
		{
			"property": &"edge_width",
			"label": "Edge Width",
			"type": SettingType.INT,
			"min": 0,
			"max": 16,
			"step": 1,
			"tooltip": "How many pixels of antialiasing to rebuild around whatever this opens.\nA crevice mouth wants the same treatment as the silhouette it opens off, so\nthis usually matches the Edge Width in Remove Background \u2014 but it is its own\nsetting, so this operation works wherever you put it.",
		},
		{
			"property": &"crevice_tolerance",
			"label": "Crevice Tolerance",
			"type": SettingType.FLOAT,
			"min": 0.0,
			"max": 1.0,
			"step": 0.01,
			"tooltip": "How far from the background color those squeezed-through pixels may be.\nOne number whatever the background is made of, because this describes the gap\nbeing squeezed through rather than the background being left behind.",
		},
	]


func stage_weight() -> float:
	return 0.35


## It reads a classification if one is there and works one out if not, so nothing has
## to be above it.
func needs_keying() -> bool:
	return false


## Nothing. It builds whatever it needs; see [method _ensure_classification].
func prerequisite_note(_ctx: IWPipelineContext) -> String:
	return ""


func process_context(ctx: IWPipelineContext) -> void:
	_reach = settings.crevice_reach
	_tolerance = settings.crevice_tolerance
	if _reach <= 0:
		return
	_recovered.clear()

	# Whatever it needs and does not have, it works out for itself. A stack is an
	# ordered list of operations, not a set of dependencies, so this has to be able to
	# run wherever it is put — and what it builds is left on the context for whatever
	# comes after it.
	_ensure_classification(ctx)
	if not report_progress(0.15):
		return

	var touched := _grow(ctx)
	if touched.is_empty():
		report_progress(1.0)
		return
	if not report_progress(0.5):
		return

	# The band has to grow from what the crevice opened, or a gap reached here would
	# have a hard rim where every other edge in the image has a matte.
	var banded := ctx.grow_edge_band(touched, settings.edge_width)
	touched.append_array(banded)
	if not report_progress(0.7):
		return

	# Pixels that were subject sources a moment ago are not any more, so the map that
	# names the nearest one is stale everywhere within its own reach.
	ctx.rebuild_nearest()
	if not report_progress(0.85):
		return

	# Only what could have changed. A pixel outside the crevice can have the wrong
	# coverage only if its nearest subject moved, which reaches exactly this far — and
	# recomputing the whole image would undo any alpha a stage above dialled in by hand.
	ctx.compute_coverage(ctx.dilate(touched, ctx.search_radius))
	report_progress(1.0)


## Makes sure there is a classification to grow, building one from the alpha when
## nothing above has produced one.
##
## What is already transparent is background, what is solid is subject, and what is in
## between is the antialiased band — which is the same reading of an image the rest of
## the pipeline uses, arrived at from the other end. Written back to the context, so a
## stage below this one inherits it rather than working it out again.
##
## Background found this way carries [constant IWPipelineContext.KEY_CLEAR]: something
## removed it, but nothing here knows what colour it was. [method _grow] recovers that
## per pixel from the source, which still holds the original colour wherever a stage
## above did the removing.
func _ensure_classification(ctx: IWPipelineContext) -> void:
	# The band pass and the coverage fallback both read this, and with no keying stage
	# above it would be zero.
	ctx.edge_width = maxi(ctx.edge_width, settings.edge_width)
	ctx.search_radius = maxi(ctx.search_radius, ctx.edge_width)
	if ctx.has_classification():
		return

	var pixel_count := ctx.pixel_count
	var alpha := ctx.final_alpha()
	var blacked := ctx.blacked
	var protect := ctx.protect
	var has_blacked := not blacked.is_empty()
	var has_protect := not protect.is_empty()
	var mask := PackedByteArray()
	mask.resize(pixel_count)
	var key_of := PackedInt32Array()
	key_of.resize(pixel_count)

	for i in pixel_count:
		# The drawn and picked regions are read here rather than off the alpha,
		# because they have not reached it yet: they are settled at the very end of a
		# run on purpose, so that nothing smooths across an edge meant to be hard. A
		# declared cut is background whatever the alpha still says.
		if has_blacked and blacked[i] == IWPipelineContext.REGION_CUT:
			mask[i] = IWPipelineContext.MASK_BACKGROUND
			key_of[i] = IWPipelineContext.KEY_CLEAR
			continue
		if (has_protect and protect[i] != 0) \
				or (has_blacked and blacked[i] == IWPipelineContext.REGION_KEEP):
			mask[i] = IWPipelineContext.MASK_SUBJECT
			key_of[i] = IWPipelineContext.KEY_NONE
			continue

		var a := alpha[i]
		if a <= 0.0:
			mask[i] = IWPipelineContext.MASK_BACKGROUND
			key_of[i] = IWPipelineContext.KEY_CLEAR
		elif a >= 1.0:
			mask[i] = IWPipelineContext.MASK_SUBJECT
			key_of[i] = IWPipelineContext.KEY_NONE
		else:
			mask[i] = IWPipelineContext.MASK_EDGE
			key_of[i] = IWPipelineContext.KEY_NONE

	ctx.mask = mask
	ctx.key_of = key_of
	ctx.rebuild_nearest()


## A key index standing for the background colour at [param index], or -1 when there
## is no colour there worth trusting.
##
## For background this operation classified from the alpha rather than from a colour.
## [member IWPipelineContext.data] is the image as it arrived and no stage may write
## to it, so wherever a stage above turned a pixel transparent the original background
## colour is still sitting there to be read. A pixel that arrived transparent in the
## file is the one case that fails: what was there is gone, and the RGB left behind is
## the previous run's colour bleed, which is subject colour wearing a background's
## position.
##
## [b]Registered as an island key.[/b] It is the colour of one spot, which is a licence
## to grow out of that spot rather than to match every pixel of that colour in the
## image — exactly what [member IWPipelineContext.key_is_island] means, and what keeps
## these out of [method IWPipelineContext.claiming_key].
##
## Its tolerance is zero, so only an identical pixel counts as solid background and
## resets the weak count. Everything looser is a squeeze, which is the honest reading:
## nobody declared how far from this colour still counts as background, so the only
## thing that can be called certain is an exact match.
func _recover_key(ctx: IWPipelineContext, index: int) -> int:
	if ctx.is_clear(index):
		return -1

	var color := ctx.color_at(index)
	var quantised := Vector3i(
		roundi(color.r * 255.0), roundi(color.g * 255.0), roundi(color.b * 255.0))
	if _recovered.has(quantised):
		return _recovered[quantised]
	if _recovered.size() >= _MAX_RECOVERED_KEYS:
		return _recovered.values()[0]

	var key := ctx.add_key(color, 0.0, true)
	_recovered[quantised] = key
	return key


## Grows the background into weakly-matching neighbours, and returns every pixel it
## took.
##
## Seeded from every background pixel that can say what colour the background is
## there. A pixel a keying stage claimed says so through its key; one this operation
## classified from the alpha says so through the source, which still holds the
## original colour wherever a stage above did the removing. A pixel that arrived
## transparent in the source file says nothing — whatever was there is gone and the
## RGB left behind is the previous run's colour bleed — so it is not grown from.
func _grow(ctx: IWPipelineContext) -> PackedInt32Array:
	var width := ctx.width
	var height := ctx.height
	var pixel_count := ctx.pixel_count
	var mask := ctx.mask
	var key_of := ctx.key_of
	var reach := _reach

	# Each pixel is claimed at most once, so the queue can be sized up front and
	# used as a plain FIFO with no wraparound.
	var queue := PackedInt32Array()
	queue.resize(pixel_count)
	var head := 0
	var tail := 0
	# How many weak pixels in a row the growth crossed to reach each pixel; zero on
	# anything solidly background, which is what makes the threshold a double one.
	var weak := PackedInt32Array()
	weak.resize(pixel_count)

	for i in pixel_count:
		if mask[i] != IWPipelineContext.MASK_BACKGROUND:
			continue
		if key_of[i] < 0:
			var recovered := _recover_key(ctx, i)
			if recovered < 0:
				continue
			key_of[i] = recovered
		queue[tail] = i
		tail += 1
	# Read after seeding, since recovering a key appends to it.
	var tolerances := ctx.key_tolerances
	if tail == 0:
		return PackedInt32Array()

	var background := IWPipelineContext.MASK_BACKGROUND
	var edge := IWPipelineContext.MASK_EDGE
	var subject := IWPipelineContext.MASK_SUBJECT
	var touched := PackedInt32Array()
	var seen := PackedByteArray()
	seen.resize(pixel_count)

	# [b]The band above is crossed, not eaten.[/b] By the time this runs, the stage
	# above has already matted the mouth of the crevice — those pixels are exactly
	# the antialiasing the neck is made of, and they are what has to be walked
	# through to get inside. But their alpha is already right, so they are traversed
	# and left alone; only subject beyond them is claimed. Reclassifying them instead
	# would push the edge out by the band's width on every run, and then grow a fresh
	# band beyond that.
	#
	# A traversed pixel still costs a weak step unless it is within tolerance, since
	# a step through the neck is a step through the neck whoever matted it first.
	#
	# Written out four times rather than through a helper: the marking has to land in
	# these arrays, and handing a Packed array to a function to be written through
	# would only ever mutate the copy that function got.
	while head < tail:
		var index := queue[head]
		head += 1
		var here := weak[index]
		if here >= reach:
			continue
		var k := key_of[index]
		var tolerance: float = tolerances[k]
		var loose := maxf(_tolerance, tolerance)
		var x := index % width
		@warning_ignore("integer_division")
		var y := index / width

		if x > 0:
			var left := index - 1
			if mask[left] != background and seen[left] == 0 and not ctx.is_clear(left):
				var d := ctx.key_distance(left, k)
				if d <= loose:
					seen[left] = 1
					var solid := d <= tolerance
					weak[left] = 0 if solid else here + 1
					if mask[left] == subject:
						mask[left] = background if solid else edge
						key_of[left] = k
						touched.append(left)
					queue[tail] = left
					tail += 1
		if x < width - 1:
			var right := index + 1
			if mask[right] != background and seen[right] == 0 and not ctx.is_clear(right):
				var d := ctx.key_distance(right, k)
				if d <= loose:
					seen[right] = 1
					var solid := d <= tolerance
					weak[right] = 0 if solid else here + 1
					if mask[right] == subject:
						mask[right] = background if solid else edge
						key_of[right] = k
						touched.append(right)
					queue[tail] = right
					tail += 1
		if y > 0:
			var up := index - width
			if mask[up] != background and seen[up] == 0 and not ctx.is_clear(up):
				var d := ctx.key_distance(up, k)
				if d <= loose:
					seen[up] = 1
					var solid := d <= tolerance
					weak[up] = 0 if solid else here + 1
					if mask[up] == subject:
						mask[up] = background if solid else edge
						key_of[up] = k
						touched.append(up)
					queue[tail] = up
					tail += 1
		if y < height - 1:
			var down := index + width
			if mask[down] != background and seen[down] == 0 and not ctx.is_clear(down):
				var d := ctx.key_distance(down, k)
				if d <= loose:
					seen[down] = 1
					var solid := d <= tolerance
					weak[down] = 0 if solid else here + 1
					if mask[down] == subject:
						mask[down] = background if solid else edge
						key_of[down] = k
						touched.append(down)
					queue[tail] = down
					tail += 1

	ctx.mask = mask
	ctx.key_of = key_of
	return touched
