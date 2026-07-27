@tool
class_name EdgeCleanup
extends IWStackOperation

## Two finishing jobs on the silhouette: restore the antialiasing, then outline it.
##
## [b]Restoring the antialiasing.[/b] Keying builds a matte while it decides what is
## background, which only helps where it is the one doing the cutting. An image that
## arrived aliased, or an edge a hard alpha clip flattened on the way past, has a
## solid pixel sitting straight against a clear one and nothing in between. This
## finds those and works the coverage back out of the same relation everything else
## rests on: a pixel on an antialiased edge is [code]C = a * F + (1 - a) * K[/code],
## so its distance from the background is [code]a[/code] times the subject's
## distance from the background, and dividing one by the other gives back
## [code]a[/code] with the unknown [code]F[/code] cancelled out.
##
## [b]Adjacency is the whole test[/b], and it is why this needs no settings. Only a
## pixel with the opposite extreme directly beside it is touched. A properly matted
## edge has half-covered pixels in between, so neither side can see the other and
## the edge is left exactly as it was — this cannot undo the good work of the edge
## band, so there is nothing to tune it down with. Hard by intent is left hard: a
## pixel in or against a drawn region is skipped, since a drawn cut is a straight
## line the user asked for rather than an edge that lost its antialiasing.
##
## [b]The outline.[/b] The inner stroke runs within the shape and touches only
## colour; the outer one runs outside it and has to bring alpha with it, since out
## there is nothing to colour. The outer one is composited underneath the subject,
## so the shape's own soft edge stays on top of it.
##
## The two belong together because the stroke needs the restoration: a stroke places
## its edges from the alpha's own sub-pixel contour, which a hard silhouette does
## not have — and giving a hard silhouette one is precisely what the restoration
## does.
##
## This is also the stage that settles the drawn regions into the alpha, because it
## has to: the stroke follows the silhouette that actually comes out, drawn shapes
## and all, rather than the one the keying alone would have given.

## What the restoration counts as fully solid and fully clear.
##
## Deliberately not 1.0 and 0.0 exactly: alpha arriving here has been through a
## division, possibly a guided filter and possibly a clip, and a pixel that is
## solid for every practical purpose can miss an exact comparison by a hair.
const _RESTORE_SOLID := 0.995
const _RESTORE_CLEAR := 0.005

## How many pixels the restoration steps inward looking for a subject colour. Two,
## because from a clear pixel the first step only reaches the boundary — which is
## the contaminated pixel being stepped past.
const _RESTORE_INWARD_MAX := 2

## How the automatic stroke colour is derived from what it runs alongside.
##
## A line is a darker, more saturated relative of the fill it borders — that is how
## it is picked by hand, and it is why the sampled colour cannot be used as it is:
## paint a colour over itself and there is nothing to see.
##
## Proportional rather than a fixed target, and with no threshold anywhere: a rule
## that switched from darkening to lightening below some luminance would flip the
## outline mid-stroke wherever a subject crossed it, which is worse than an outline
## that is merely subtle on something already dark.
const _AUTO_STROKE_DARKEN := 0.35
const _AUTO_STROKE_SATURATION := 1.3

## Blur radius for the sample, as a multiple of the stroke's own width and never
## below a few pixels.
##
## Wide on purpose. The question is "what colour is the subject around here", and a
## tight blur answers "what colour is this pixel" — which on any texture is noise,
## and would give a stroke that changed colour along its own length.
const _AUTO_STROKE_BLUR_SCALE := 4.0
const _AUTO_STROKE_BLUR_MIN := 6

## Feather on the stroke's inner edge at full softness, in pixels.
##
## Two, so that the middle of the slider lands on a one-pixel falloff — the width a
## real antialiased edge has, and what the stroke did before it was adjustable. That
## leaves the top half of the range for softer than natural, which is what the
## setting is mostly wanted for.
const _STROKE_MAX_FEATHER := 2.0

var settings: EdgeCleanupSettings


func _init() -> void:
	settings = EdgeCleanupSettings.new()


func get_operation_name() -> String:
	return "Edge Cleanup"


func get_operation_id() -> StringName:
	return &"edge_cleanup"


func get_settings() -> Resource:
	return settings


func set_settings(new_settings: Resource) -> void:
	var typed := new_settings as EdgeCleanupSettings
	if typed == null:
		push_error("Image Wrangler: EdgeCleanup was handed settings of the wrong type.")
		return
	settings = typed


func make_settings() -> Resource:
	return EdgeCleanupSettings.new()


func get_settings_schema() -> Array[Dictionary]:
	return [
		{
			"property": &"inner_stroke_width",
			"label": "Inner Stroke Width",
			"type": SettingType.FLOAT,
			"min": 0.0,
			"max": 5.0,
			"step": 0.25,
			"tooltip": "Width of the stroke drawn inside the silhouette, in pixels. 0 draws none.\n\nInside means it never extends the shape: it follows the holes in a subject as\nwell as its outer contour, and leaves the alpha channel exactly as it found\nit. Only color changes.\n\nAntialiased, so fractional widths are worth having — both its edges fall\nbetween pixels rather than stepping along them.",
		},
		{
			"property": &"outer_stroke_width",
			"label": "Outer Stroke Width",
			"type": SettingType.FLOAT,
			"min": 0.0,
			"max": 5.0,
			"step": 0.25,
			"tooltip": "Width of the stroke drawn outside the silhouette, in pixels. 0 draws none.\n\nUnlike the inner one this adds alpha — outside the shape there is nothing to\ncolor, so the stroke brings its own. The subject comes out this many pixels\nlarger than it went in.\n\nDrawn underneath the subject rather than over it, so the shape's own soft edge\nstays on top and the stroke shows through it. That is what an outer stroke\nlooks like, and what stops it eating the antialiasing it is there to sit\nbehind.",
		},
		{
			"property": &"stroke_softness",
			"label": "Stroke Softness",
			"type": SettingType.FLOAT,
			"min": 0.0,
			"max": 1.0,
			"step": 0.05,
			"tooltip": "How soft the stroke's inner edge is. 0 is a hard step with no antialiasing at\nall; 0.5 falls off over one pixel, which is what a real antialiased edge does;\n1 is the softest.\n\nOnly the inner edge. The outer one is the silhouette itself, and its softness\ncomes from the image's own alpha — feathering that would let the stroke bleed\npast the shape, which is the one thing an inside stroke must not do.\n\nA wide feather on a narrow stroke spreads it past its own width, since the\nfalloff is centred on the edge rather than tucked inside it.",
		},
		{
			"property": &"auto_stroke_color",
			"label": "Auto Stroke Color",
			"type": SettingType.BOOL,
			"tooltip": "Takes the stroke color from the image instead of picking one.\n\nEach stroke pixel samples a heavily blurred copy of the subject nearby and\nthen darkens it, so a green stem gets a dark green outline and a red petal a\ndeep red one — the way an illustrator picks a line color against a fill,\nrather than one flat color fighting everything it runs alongside.\n\nThe blur is weighted by alpha, so only real subject pixels count towards it.\nAn unweighted one would average in the empty space just outside the edge,\nwhich is exactly where every stroke pixel sits.\n\nDrawn at full strength. For a stroke that only tints, turn this off and pick a\ncolor with some transparency.",
		},
		{
			"property": &"stroke_color",
			"label": "Stroke Color",
			"hidden_when": &"auto_stroke_color",
			"type": SettingType.COLOR,
			"tooltip": "Color of the stroke. Its alpha is how strongly it is laid over what is already\nthere, not how transparent the result becomes — at half alpha the stroke tints\nthe art beneath it rather than covering it.",
		},
	]


func stage_weight() -> float:
	return 0.30


## The stroke is drawn from alpha alone, and alpha exists whether or not anything
## was keyed. Only the restoration needs a key, and it stands down without one.
func needs_keying() -> bool:
	return false


func process_context(ctx: IWPipelineContext) -> void:
	ctx.stroke_color = settings.stroke_color

	# After any clip, because flattening an edge is one of the ways an edge comes to
	# need restoring, and before the regions below, which are hard on purpose.
	if ctx.has_keying and not ctx.coverage.is_empty():
		ctx.coverage = _restore_edges(ctx)
	if not report_progress(0.4):
		return

	# Before the stroke, so it follows the silhouette that actually comes out.
	ctx.apply_regions_to_coverage()
	if not report_progress(0.5):
		return

	if not _wants_stroke():
		report_progress(1.0)
		return

	var alpha := ctx.final_alpha()
	var bands := _stroke_bands(ctx, alpha)
	var inner: PackedFloat32Array = bands[0]
	var outer: PackedFloat32Array = bands[1]
	ctx.stroke_inner = inner
	ctx.stroke_outer = outer
	if not report_progress(0.8):
		return
	ctx.stroke_colors = _auto_stroke_colors(ctx, alpha, inner, outer)
	report_progress(1.0)


## Whether either stroke would actually put paint down.
##
## Two zero widths mean no, and so does a fully transparent colour — but only when
## the colour is the one being used: an automatic stroke takes its colour from the
## image and never sees the picker, whose alpha would otherwise be a hidden switch
## for a hidden control.
func _wants_stroke() -> bool:
	if settings.inner_stroke_width <= 0.0 and settings.outer_stroke_width <= 0.0:
		return false
	return settings.auto_stroke_color or settings.stroke_color.a > 0.0


## How strongly the stroke is laid over what is under it.
##
## Full for an automatic colour, since its picker is hidden and there would be no
## way to have set anything else.
func _stroke_strength() -> float:
	return 1.0 if settings.auto_stroke_color else settings.stroke_color.a


func _restore_edges(ctx: IWPipelineContext) -> PackedFloat32Array:
	var coverage := ctx.coverage
	var width := ctx.width
	var height := ctx.height
	var key_of := ctx.key_of
	var nearest := ctx.nearest
	var blacked := ctx.blacked
	var has_regions := not blacked.is_empty()
	var has_nearest := not nearest.is_empty()
	var has_key_of := not key_of.is_empty()
	var fallback_key: Color = ctx.keys[0]
	var pixel_count := ctx.pixel_count
	# Written to a copy, so that a pixel restored early in the scan cannot become
	# the evidence that its neighbour needs restoring too.
	var out := coverage.duplicate()

	for i in pixel_count:
		if has_regions and blacked[i] != IWPipelineContext.REGION_NONE:
			continue
		var here := coverage[i]
		var solid := here >= _RESTORE_SOLID
		if not solid and here > _RESTORE_CLEAR:
			continue

		var x := i % width
		@warning_ignore("integer_division")
		var y := i / width

		# The opposite extreme, if it is right there. Anything softer between the
		# two means this edge already has its matte.
		var facing := -1
		if x > 0 and _opposes(coverage, i - 1, solid):
			facing = i - 1
		elif x < width - 1 and _opposes(coverage, i + 1, solid):
			facing = i + 1
		elif y > 0 and _opposes(coverage, i - width, solid):
			facing = i - width
		elif y < height - 1 and _opposes(coverage, i + width, solid):
			facing = i + width
		if facing < 0:
			continue
		if has_regions and blacked[facing] != IWPipelineContext.REGION_NONE:
			continue

		# The background this edge is against, taken from whichever of the two
		# sides the flood actually claimed, since that is the one that knows.
		var claimed := -1
		if has_key_of:
			claimed = key_of[facing] if key_of[facing] >= 0 else key_of[i]
		var key: Color = ctx.keys[claimed] if claimed >= 0 else fallback_key

		var subject := _inward(coverage, x, y, width, height)
		if subject < 0 and has_nearest:
			subject = nearest[i]
		if subject < 0:
			continue

		var reference := ctx.distance_at(subject, key)
		# Subject indistinguishable from background here: the division would
		# amplify nothing into anything, and there is no coverage to recover.
		if reference <= IWPipelineContext.EPSILON:
			continue
		out[i] = clampf(ctx.distance_at(i, key) / reference, 0.0, 1.0)

	return out


## Whether [param index] sits at the opposite extreme to a pixel that is
## [param solid].
func _opposes(coverage: PackedFloat32Array, index: int, solid: bool) -> bool:
	return coverage[index] <= _RESTORE_CLEAR if solid else coverage[index] >= _RESTORE_SOLID


## A pixel a step or two into the opaque shape from ([param x], [param y]), or -1.
##
## The pixel being restored is itself part background — that is what makes it an
## edge — so measuring it against its own colour would ask how much of a blend a
## blend is and answer "all of it". A step inward gets past the contamination.
##
## The direction comes from the alpha around the pixel: every neighbour pulls
## towards itself in proportion to how opaque it is, so the sum points the way the
## shape lies. Walking it stops at the first pixel that is not solid, so a step can
## never cross a gap and come back with a colour from the far side.
func _inward(coverage: PackedFloat32Array, x: int, y: int, width: int, height: int) -> int:
	var dx := 0.0
	var dy := 0.0
	for oy in [-1, 0, 1]:
		for ox in [-1, 0, 1]:
			if ox == 0 and oy == 0:
				continue
			var nx: int = x + ox
			var ny: int = y + oy
			if nx < 0 or ny < 0 or nx >= width or ny >= height:
				continue
			var weight := coverage[ny * width + nx]
			dx += ox * weight
			dy += oy * weight

	var length := sqrt(dx * dx + dy * dy)
	if length <= IWPipelineContext.EPSILON:
		return -1
	dx /= length
	dy /= length

	var found := -1
	for step in range(1, _RESTORE_INWARD_MAX + 1):
		var sx := x + roundi(dx * step)
		var sy := y + roundi(dy * step)
		if sx < 0 or sy < 0 or sx >= width or sy >= height:
			break
		var candidate := sy * width + sx
		if coverage[candidate] < _RESTORE_SOLID:
			break
		found = candidate
	return found


## The two stroke bands, as [code][inner, outer][/code], each a strength per pixel
## and each empty when that stroke is not being drawn.
##
## [b]The silhouette sits between pixels, not on them.[/b] What matters is the
## contour where alpha crosses a half, and a pixel's own alpha says where that
## contour runs relative to its centre: coverage on a properly antialiased edge
## falls off over about one pixel, so a pixel of alpha [code]a[/code] is
## [code]a - 0.5[/code] from the contour, signed. That holds for a hard edge too,
## where the two sides read +0.5 and -0.5 and put the contour exactly halfway
## between them.
##
## Measuring from that sub-pixel contour rather than from the nearest transparent
## pixel is the whole of the antialiasing. Whole-pixel distances quantise, and on a
## shallow diagonal — where the nearest empty pixel stays directly below for a long
## run — they quantise into a staircase, which is exactly the artefact a stroke must
## not have.
##
## [param alpha] is the alpha the image actually ends up with, 0 to 1 — not the
## coverage, which is only half of it.
func _stroke_bands(ctx: IWPipelineContext, alpha: PackedFloat32Array) -> Array:
	var none := PackedFloat32Array()
	var width := ctx.width
	var height := ctx.height
	var strength := _stroke_strength()
	var feather := clampf(settings.stroke_softness, 0.0, 1.0) * _STROKE_MAX_FEATHER
	var inner_width := settings.inner_stroke_width
	var outer_width := settings.outer_stroke_width

	var inner := none
	if inner_width > 0.0:
		inner = _inner_band(alpha, inner_width, feather, strength, width, height)
	var outer := none
	if outer_width > 0.0:
		outer = _outer_band(alpha, outer_width, feather, strength, width, height)
	return [inner, outer]


## Nearest seed index for every pixel within [param reach] of the contour, or -1.
##
## [param seed_inside] picks which side seeds: the far side from whichever band is
## being measured, since what each pixel wants is the distance to the other side.
func _contour_seeds(alpha: PackedFloat32Array, seed_inside: bool, reach: int, width: int, height: int) -> PackedInt32Array:
	var pixel_count := width * height
	# Sized for the worst case and trimmed, rather than grown: one side of the
	# contour is most of the image, so appending would reallocate its way up the
	# whole buffer.
	var seeds := PackedInt32Array()
	seeds.resize(pixel_count)
	var count := 0

	# Half coverage is the line, not full transparency. The half-covered band along
	# an antialiased edge belongs to the shape's soft edge, and counting it as solid
	# would push the contour a pixel out and blunt the very gradient this measures.
	for i in pixel_count:
		if (alpha[i] >= 0.5) == seed_inside:
			seeds[count] = i
			count += 1
	seeds.resize(count)
	if seeds.is_empty() or seeds.size() == pixel_count:
		# All of one side, so there is no contour anywhere to measure from. Empty
		# rather than a map of -1, since the callers treat "no contour" and "out of
		# reach of one" differently.
		return PackedInt32Array()

	return IWPixelMath.grassfire(seeds, width, height, reach)


## Strength per pixel for the stroke inside the silhouette.
##
## [b]The canvas edge counts as outside.[/b] Rather than seeding the border, every
## pixel also measures its distance to just past the frame and takes whichever is
## nearer — one comparison, no extra seeds, and a shape running off the edge is
## stroked along it like any other contour.
##
## [b]The inner edge is feathered, the outer one is not.[/b] The outer edge here is
## the silhouette, and its softness is already in the image's own alpha — the stroke
## covers those pixels outright and lets that alpha do the fading. Feathering it as
## well would let the stroke bleed past the shape, which is the one thing an inside
## stroke must not do.
func _inner_band(alpha: PackedFloat32Array, stroke_width: float, feather: float, strength: float, width: int, height: int) -> PackedFloat32Array:
	var empty := PackedFloat32Array()
	var pixel_count := width * height
	# Far enough to cover the whole falloff and one more, so a pixel that should
	# still be faintly stroked is never left unreached and reading as empty. The
	# feather counts here: it pushes the fade out past the requested width.
	var reach := ceili(stroke_width + feather * 0.5) + 1
	var source := _contour_seeds(alpha, false, reach, width, height)

	var mask := PackedFloat32Array()
	mask.resize(pixel_count)
	var painted := false
	for i in pixel_count:
		# Nothing there to paint on, and painting anyway would put stroke colour
		# into the pixels the colour bleed is filling.
		if alpha[i] <= 0.0:
			continue
		var x := i % width
		@warning_ignore("integer_division")
		var y := i / width

		# Half a pixel, because the frame runs along the outer edge of the border
		# row rather than through its centre.
		var distance := float(mini(mini(x, y), mini(width - 1 - x, height - 1 - y))) + 0.5

		if alpha[i] < 0.5:
			# Outside the contour but still visible: part of the shape's own soft
			# edge. Its distance is negative, so the stroke covers it outright and
			# the pixel's own alpha does the fading.
			distance = minf(distance, alpha[i] - 0.5)
		elif not source.is_empty():
			var seed_index := source[i]
			if seed_index >= 0:
				var sx := seed_index % width
				@warning_ignore("integer_division")
				var sy := seed_index / width
				var span := sqrt(float((x - sx) * (x - sx) + (y - sy) * (y - sy)))
				# The seed is a pixel centre, and the contour is a fraction of a
				# pixel short of it. Adding the seed's own signed offset — negative,
				# since a seed is outside — walks the measurement back to the
				# contour, and is what makes this smooth along an edge rather than
				# stepping with the seed positions.
				distance = minf(distance, span + (alpha[seed_index] - 0.5))

		var band := _falloff(distance, stroke_width, feather)
		if band <= 0.0:
			continue
		mask[i] = band * strength
		painted = true

	return mask if painted else empty


## Strength per pixel for the stroke outside the silhouette.
##
## The mirror of [method _inner_band], measuring outwards from the same contour, and
## with the frame deliberately playing no part: there is nothing beyond it to grow
## into, so a shape running off the edge simply gets clipped there.
##
## A pixel already solid is skipped. The stroke is drawn under the subject, so where
## the subject is opaque there is nothing of the stroke left to see and working it
## out would be effort spent on an invisible result.
func _outer_band(alpha: PackedFloat32Array, stroke_width: float, feather: float, strength: float, width: int, height: int) -> PackedFloat32Array:
	var empty := PackedFloat32Array()
	var pixel_count := width * height
	var reach := ceili(stroke_width + feather * 0.5) + 1
	var source := _contour_seeds(alpha, true, reach, width, height)
	if source.is_empty():
		return empty

	var mask := PackedFloat32Array()
	mask.resize(pixel_count)
	var painted := false
	for i in pixel_count:
		if alpha[i] >= 1.0:
			continue
		var x := i % width
		@warning_ignore("integer_division")
		var y := i / width

		var distance := 0.0
		if alpha[i] >= 0.5:
			# Inside the contour but not solid: the shape's own soft edge again,
			# seen from the other side. Negative distance, so the stroke fills the
			# whole of it and is then hidden by whatever alpha the subject has.
			distance = 0.5 - alpha[i]
		else:
			var seed_index := source[i]
			if seed_index < 0:
				continue
			var sx := seed_index % width
			@warning_ignore("integer_division")
			var sy := seed_index / width
			var span := sqrt(float((x - sx) * (x - sx) + (y - sy) * (y - sy)))
			# Subtracted rather than added: the seed is inside this time, so its own
			# offset is how far past the contour it sits.
			distance = span - (alpha[seed_index] - 0.5)

		var band := _falloff(distance, stroke_width, feather)
		if band <= 0.0:
			continue
		mask[i] = band * strength
		painted = true

	return mask if painted else empty


## How much of the stroke covers a pixel [param distance] from the contour.
##
## Falls off across the requested width rather than up to it, so softening blurs the
## far edge in place instead of walking the stroke inwards. A feather of zero is a
## genuine step rather than a very narrow ramp, so the division is skipped rather
## than approximated.
func _falloff(distance: float, stroke_width: float, feather: float) -> float:
	if feather <= IWPipelineContext.EPSILON:
		return 1.0 if distance <= stroke_width else 0.0
	return clampf((stroke_width + feather * 0.5 - distance) / feather, 0.0, 1.0)


## A stroke colour per pixel, taken from the image, or an empty array when the
## colour is being picked by hand instead.
##
## Three floats per pixel, filled only where the stroke actually paints. The rest is
## left at zero and never read.
##
## [b]Sampled from an alpha-weighted blur.[/b] Each channel is blurred premultiplied
## by alpha and divided by a blur of the alpha itself, so the average is over subject
## only. That weighting is the whole trick: a plain blur, sampled at the silhouette
## edge where every stroke pixel sits, would average in the empty space just outside
## it and drag every stroke towards whatever the bleed left there.
##
## [b]Then darkened[/b], because painting a colour over itself shows nothing. See
## [constant _AUTO_STROKE_DARKEN].
func _auto_stroke_colors(ctx: IWPipelineContext, alpha: PackedFloat32Array, inner: PackedFloat32Array, outer: PackedFloat32Array) -> PackedFloat32Array:
	var empty := PackedFloat32Array()
	if not settings.auto_stroke_color:
		return empty
	var has_inner := not inner.is_empty()
	var has_outer := not outer.is_empty()
	if not has_inner and not has_outer:
		return empty

	var data := ctx.data
	var width := ctx.width
	var height := ctx.height
	var pixel_count := ctx.pixel_count
	var premul_r := PackedFloat32Array()
	var premul_g := PackedFloat32Array()
	var premul_b := PackedFloat32Array()
	var weight := PackedFloat32Array()
	premul_r.resize(pixel_count)
	premul_g.resize(pixel_count)
	premul_b.resize(pixel_count)
	weight.resize(pixel_count)

	var to_unit := 1.0 / 255.0
	for i in pixel_count:
		var offset := i * 4
		var a := alpha[i]
		premul_r[i] = data[offset] * to_unit * a
		premul_g[i] = data[offset + 1] * to_unit * a
		premul_b[i] = data[offset + 2] * to_unit * a
		weight[i] = a

	var widest := maxf(settings.inner_stroke_width, settings.outer_stroke_width)
	var radius := maxi(ceili(widest * _AUTO_STROKE_BLUR_SCALE), _AUTO_STROKE_BLUR_MIN)
	premul_r = IWPixelMath.box_mean(premul_r, width, height, radius)
	premul_g = IWPixelMath.box_mean(premul_g, width, height, radius)
	premul_b = IWPixelMath.box_mean(premul_b, width, height, radius)
	weight = IWPixelMath.box_mean(weight, width, height, radius)

	var colors := PackedFloat32Array()
	colors.resize(pixel_count * 3)
	for i in pixel_count:
		# Wherever either stroke paints. They share a colour, so the sample only has
		# to be worked out once per pixel.
		if (not has_inner or inner[i] <= 0.0) and (not has_outer or outer[i] <= 0.0):
			continue
		var w := weight[i]
		# No subject within the whole blur radius, which for a stroke pixel means
		# something has gone strange. Nothing to sample, so leave it black.
		if w <= IWPipelineContext.EPSILON:
			continue
		var sampled := Color(premul_r[i] / w, premul_g[i] / w, premul_b[i] / w)
		var line := Color.from_hsv(
			sampled.h,
			minf(sampled.s * _AUTO_STROKE_SATURATION, 1.0),
			clampf(sampled.v * _AUTO_STROKE_DARKEN, 0.0, 1.0),
		)
		var slot := i * 3
		colors[slot] = line.r
		colors[slot + 1] = line.g
		colors[slot + 2] = line.b

	return colors
