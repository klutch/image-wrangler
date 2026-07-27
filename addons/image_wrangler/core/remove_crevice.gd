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
## resets the count; one merely within [member RemoveBackgroundSettings.crevice_tolerance]
## may still be crossed, but only [member RemoveBackgroundSettings.crevice_reach]
## of them in a row before solid background is needed again. That is what gets
## through the neck while stopping the flood wandering off across a pale subject,
## which an unbounded weak threshold would do.
##
## [b]A pixel the flood only squeezed through is not background.[/b] It is the
## antialiasing of the two walls it passed between, so it is part subject: it goes
## to the edge band and gets partial alpha from the usual coverage maths, where
## calling it background would cut a hard notch out of the crevice mouth.
##
## [b]Its own pass, downstream of the keying.[/b] It reads the classification the
## stage above produced and grows it further, which is what lets it sit before or
## after the other alpha stages and mean something different in each place. The
## cost is that it takes the band width from the keying stage rather than owning
## one: a crevice opened here is matted to the same depth as every other edge in
## the image, which is what it should be.

var settings: RemoveCreviceSettings

## Read from inside the per-pixel loop, so they are copied out of the settings
## Resource once per run rather than resolved through it millions of times.
var _reach := 0
var _tolerance := 0.0


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
			"tooltip": "How many near-background pixels in a row may be crossed in a row before\nsolid background is needed again, so it needs to be at least as long as the\nconstriction it has to get through. 0 does nothing at all.\n\nWhat it gets into is a nook whose opening is nothing but the antialiasing of\nthe two walls meeting, which the keying above stops at.",
		},
		{
			"property": &"crevice_tolerance",
			"label": "Crevice Tolerance",
			"type": SettingType.FLOAT,
			"min": 0.0,
			"max": 1.0,
			"step": 0.01,
			"tooltip": "How far from the background color those squeezed-through pixels may be.\nOne number for every color in the Remove Background above, because this\ndescribes the gap being squeezed through rather than the background being\nleft behind.",
		},
	]


func stage_weight() -> float:
	return 0.35


func prerequisite_note(ctx: IWPipelineContext) -> String:
	if ctx != null and ctx.has_classification():
		return ""
	return "Needs a Remove Background above it, and takes its Edge Width from it."


func process_context(ctx: IWPipelineContext) -> void:
	_reach = settings.crevice_reach
	_tolerance = settings.crevice_tolerance
	if _reach <= 0 or not ctx.has_classification():
		return

	var touched := _grow(ctx)
	if touched.is_empty():
		report_progress(1.0)
		return
	if not report_progress(0.5):
		return

	# The band has to grow from what the crevice opened, or a gap reached here
	# would have a hard rim where every other edge in the image has a matte. The
	# width is the keying stage's, deliberately: see the class docs.
	var banded := ctx.grow_edge_band(touched, ctx.edge_width)
	touched.append_array(banded)
	if not report_progress(0.7):
		return

	# Pixels that were subject sources a moment ago are not any more, so the map
	# that names the nearest one is stale everywhere within its own reach.
	ctx.rebuild_nearest()
	if not report_progress(0.85):
		return

	# Only what could have changed. A pixel outside the crevice can have the wrong
	# coverage only if its nearest subject moved, which reaches exactly this far —
	# and recomputing the whole image would undo any alpha a stage above dialled in
	# by hand.
	ctx.compute_coverage(ctx.dilate(touched, ctx.search_radius))
	report_progress(1.0)


## Grows the background into weakly-matching neighbours, and returns every pixel it
## took.
##
## Seeded from the background the stage above already found, minus anything with no
## key: a pixel that arrived transparent carries no colour to measure a neighbour
## against, the same reason the band pass skips it.
func _grow(ctx: IWPipelineContext) -> PackedInt32Array:
	var width := ctx.width
	var height := ctx.height
	var pixel_count := ctx.pixel_count
	var mask := ctx.mask
	var key_of := ctx.key_of
	var tolerances := ctx.key_tolerances
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
		if mask[i] == IWPipelineContext.MASK_BACKGROUND and key_of[i] >= 0:
			queue[tail] = i
			tail += 1
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
