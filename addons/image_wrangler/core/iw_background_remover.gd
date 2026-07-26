@tool
class_name IWBackgroundRemover
extends IWOperation

## Removes a flat background colour while preserving the antialiased silhouette.
##
## Naively deleting every background-coloured pixel fails in one of two ways: a
## tight threshold keeps the half-blended edge pixels and leaves a fringe, a
## loose one eats the soft edge and leaves a jagged cutout. Neither is fixable by
## tuning the threshold, because the edge is not a mask — it is a matte.
##
## An antialiased pixel is a blend of the subject and the background:
## [codeblock]
##     C = a * F + (1 - a) * K
## [/codeblock]
## [code]C[/code] is the pixel we can see, [code]K[/code] the background colour,
## [code]F[/code] the subject colour hiding underneath, and [code]a[/code] the
## pixel coverage we want back as alpha.
##
## [b]Recovering coverage.[/b] Every channel is blended with the same
## [code]a[/code], so a pixel's largest per-channel distance from [code]K[/code]
## is exactly [code]a[/code] times the subject's own distance from [code]K[/code].
## Divide one by the other and the unknown [code]F[/code] cancels out. The
## divisor comes from the nearest fully opaque pixel, so the estimate stays local
## and works whether the subject there is far from the key colour or barely off it.
##
## [b]Finding the edge.[/b] Coverage alone cannot say whether a half-key-coloured
## pixel is a half-covered distant subject or a fully covered near-key one — the
## two are numerically identical. Colour thresholds cannot break that tie, so
## geometry does: antialiasing lives in a thin band hugging the background, so
## pixels are classified by their distance from the flood-filled background
## rather than by how close to the key they are. See [method _classify].
##
## [b]More than one background colour.[/b] The image border floods with
## [member key_color], but each picked island in [member island_points] floods with
## the colour of the pixel it sits on, so an island of some other flat colour
## keys out against itself. Every pixel therefore remembers which key claimed it,
## and coverage and decontamination are both measured against that key rather
## than a single global one.
##
## [b]Killing the fringe.[/b] Correct alpha is only half the job. The RGB of a
## half-covered pixel is still half background, and that residue is what shows up
## as an outline once the image is composited. So the background is un-blended
## back out:
## [codeblock]
##     F = (C - (1 - a) * K) / a
## [/codeblock]
## Finally the subject colour is bled outwards into the fully transparent pixels.
## Their alpha is zero, but bilinear filtering and mipmaps still sample their
## RGB, which is how the background creeps back into an edge that looked clean in
## the file.

## Background colour keyed out from the image border inwards.
var key_color: Color = Color.WHITE

## How far a pixel may drift from the colour keying its region and still count as
## pure background.
var tolerance: float = 0.02

## Width of the antialiased band, in pixels. Pixels within this many steps of the
## background are treated as a soft edge and given partial alpha; anything
## further in is fully opaque subject.
var edge_width: int = 2

## Pulls the soft edge inwards. Useful when a source image was flattened onto the
## background twice and a faint halo survives.
var edge_contract: float = 0.0

## Only remove background reachable from the image border, so regions enclosed by
## the subject (eyes, speech bubbles, specular highlights) stay opaque.
var contiguous: bool = true

## How far from the keying colour the flood may stray to squeeze through a gap
## too narrow to hold a single clean background pixel. Only has an effect while
## [member crevice_reach] is above zero. See [method _flood_step].
var crevice_tolerance: float = 0.5

## How many near-background pixels in a row the flood may cross before it needs
## solid background again, so it must be at least as long as the constriction it
## has to squeeze through. Zero disables the whole mechanism, leaving the flood
## strictly within [member tolerance].
##
## Setting it generously is safer than it sounds. Somewhere the flood reaches
## only by straying is reclassified as edge rather than background, so it is
## matted by the usual coverage maths instead of being cut out — and genuine
## subject measures as fully covered there, so it keeps its alpha. Straying too
## far wastes work rather than eating the subject.
var crevice_reach: int = 0

## Extra pixels to start the background flood fill from, on top of the image
## border. Lets the user hand-pick enclosed regions that [member contiguous]
## deliberately skips.
##
## Each island keys out the colour of the pixel it lands on, sampled at process
## time rather than stored, so an island always removes exactly what was clicked and
## can never disagree with the image. Ignored when [member contiguous] is off,
## since every key-coloured pixel already qualifies then.
##
## These describe one particular image, so the dock swaps them per file rather
## than treating them as a setting shared across a batch. Points outside the
## image being processed are skipped, which keeps a stale list harmless.
var island_points: Array[Vector2i] = []

## Un-blend the background out of partially transparent pixels.
var decontaminate: bool = true

## How far subject colour is pushed into transparent pixels, in pixels.
var bleed_radius: int = 16

## Pixel classes produced by [method _classify].
const MASK_BACKGROUND := 0
const MASK_EDGE := 1
const MASK_SUBJECT := 2

## Guards divisions where the denominator can legitimately collapse to zero.
const _EPSILON := 0.0001

## Below this coverage the un-blend divides by such a small number that it
## amplifies source noise into confetti, so its result is faded into the nearest
## known subject colour instead.
const _DECONTAMINATE_FADE := 0.25

## Minimum reach for the nearest-subject map. Coverage estimation needs a couple
## of pixels of reach even when colour bleed is switched off.
const _MIN_SEARCH_RADIUS := 2


func get_operation_name() -> String:
	return "Remove Background"


func get_output_suffix() -> String:
	return "_nobg"


func get_key_color_property() -> StringName:
	return &"key_color"


func get_settings_schema() -> Array[Dictionary]:
	return [
		{
			"property": &"tolerance",
			"label": "Color Tolerance",
			"group": "Settings",
			"type": SettingType.FLOAT,
			"min": 0.0,
			"max": 0.5,
			"step": 0.005,
			"tooltip": "How far a pixel may drift from the background color and still be keyed out.\nRaise this if a re-compressed background leaves speckles behind.",
		},
		{
			"property": &"edge_width",
			"label": "Edge Width",
			"group": "Settings",
			"type": SettingType.INT,
			"min": 0,
			"max": 16,
			"step": 1,
			"tooltip": "How many pixels of antialiasing to rebuild around the subject.\n2 suits ordinary antialiasing. Raise it for soft edges, glows or\ndrop shadows; set it to 0 for a hard-edged cutout.",
		},
		{
			"property": &"edge_contract",
			"label": "Edge Contract",
			"group": "Settings",
			"type": SettingType.FLOAT,
			"min": 0.0,
			"max": 0.9,
			"step": 0.01,
			"tooltip": "Pulls the soft edge inwards. Leave at zero unless a faint halo survives.",
		},
		{
			"property": &"contiguous",
			"label": "Only Outer Background",
			"group": "Settings",
			"type": SettingType.BOOL,
			"tooltip": "Flood fill inwards from the image border, so regions enclosed by the\nsubject (eyes, highlights, gaps in lettering) stay opaque.",
		},
		{
			"property": &"crevice_reach",
			"label": "Crevice Reach",
			"group": "Settings",
			"type": SettingType.INT,
			"min": 0,
			"max": 32,
			"step": 1,
			"tooltip": "Lets the flood squeeze into nooks whose opening is nothing but the\nantialiasing of the two walls meeting, which it would otherwise stop at.\nThis is how many such pixels it may cross in a row, so it needs to be at\nleast as long as the constriction it has to get through. 0 switches it off.",
		},
		{
			"property": &"crevice_tolerance",
			"label": "Crevice Tolerance",
			"group": "Settings",
			"type": SettingType.FLOAT,
			"min": 0.0,
			"max": 1.0,
			"step": 0.01,
			"tooltip": "How far from the background color those squeezed-through pixels may be.\nOnly applies while Crevice Reach is above zero.",
		},
		{
			"property": &"decontaminate",
			"label": "Remove Color Fringe",
			"group": "Settings",
			"type": SettingType.BOOL,
			"tooltip": "Un-blends the background color out of partially transparent pixels.\nThis is what stops an outline appearing once the image is composited.",
		},
		{
			"property": &"bleed_radius",
			"label": "Color Bleed",
			"group": "Settings",
			"type": SettingType.INT,
			"min": 0,
			"max": 64,
			"step": 1,
			"tooltip": "Pushes subject color into fully transparent pixels, in pixels.\nTexture filtering and mipmaps sample RGB even where alpha is zero, so\nwithout this the background can bleed back into the edge on screen.",
		},
		{
			"property": &"island_points",
			"group": "Island Picker",
			"type": SettingType.ISLAND_PICKER,
			"tooltip": "Enclosed regions to remove anyway, picked off the preview.\nEach one keys out the color of the pixel you clicked, so an island need\nnot match the main background color. Only applies while\n\"Only Outer Background\" is on.",
		},
	]


## Convenience entry point for code that just wants the default behaviour.
static func remove_background(source: Image, key := Color.WHITE) -> Image:
	var operation := IWBackgroundRemover.new()
	operation.key_color = key
	return operation.process_image(source)


func process_image(source: Image) -> Image:
	var image := Image.new()
	image.copy_from(source)
	if image.is_compressed():
		image.decompress()
	if image.get_format() != Image.FORMAT_RGBA8:
		image.convert(Image.FORMAT_RGBA8)

	var width := image.get_width()
	var height := image.get_height()
	var pixel_count := width * height
	if pixel_count == 0:
		return image

	var data := image.get_data()
	# Distances against the operation's own key. Picked islands bring their own
	# and are measured on demand, but this covers the border flood, which is
	# nearly every background pixel in a normal image.
	var key_dist := _distance_map(data, pixel_count)

	var classified := _classify(data, key_dist, width, height)
	var mask: PackedByteArray = classified[0]
	var key_of: PackedInt32Array = classified[1]
	var keys: Array[Color] = classified[2]

	var search_radius := maxi(maxi(bleed_radius, edge_width), _MIN_SEARCH_RADIUS)
	var nearest := _nearest_subject_map(mask, key_dist, width, height, search_radius)

	var out := PackedByteArray()
	out.resize(pixel_count * 4)
	var to_unit := 1.0 / 255.0
	var contract_scale := 1.0 / maxf(1.0 - edge_contract, _EPSILON)

	for i in pixel_count:
		var offset := i * 4
		var r := data[offset] * to_unit
		var g := data[offset + 1] * to_unit
		var b := data[offset + 2] * to_unit
		var source_alpha := data[offset + 3] * to_unit
		var neighbour := nearest[i]
		var coverage := 1.0
		# Only meaningful for edge pixels, which are the only ones un-blended.
		var pixel_key := key_color

		if mask[i] == MASK_BACKGROUND:
			coverage = 0.0
		elif mask[i] == MASK_EDGE:
			var k := key_of[i]
			pixel_key = keys[k]
			# Measure this pixel against the nearest opaque subject pixel, both
			# through the key that claimed this region. For a genuine antialiased
			# edge that ratio *is* the pixel's coverage.
			var d := key_dist[i] if k == 0 else _distance_at(data, i, pixel_key)
			var reference := 0.0
			if neighbour >= 0:
				reference = key_dist[neighbour] if k == 0 else _distance_at(data, neighbour, pixel_key)
			else:
				# Nothing opaque within reach: the band has swallowed a thin
				# feature whole. Fall back to the strongest pixel nearby, which
				# for a stroke is its own core, so it keeps its shape instead of
				# being fattened to fully opaque.
				reference = _local_maximum(data, width, height, i, edge_width, pixel_key)
			if d > tolerance:
				coverage = (d - tolerance) / maxf(reference - tolerance, _EPSILON)
			else:
				coverage = 0.0
			coverage = clampf(coverage, 0.0, 1.0)
			if edge_contract > 0.0:
				coverage = clampf((coverage - edge_contract) * contract_scale, 0.0, 1.0)

		if coverage <= 0.0:
			coverage = 0.0
			if bleed_radius > 0 and neighbour >= 0:
				var bleed_offset := neighbour * 4
				r = data[bleed_offset] * to_unit
				g = data[bleed_offset + 1] * to_unit
				b = data[bleed_offset + 2] * to_unit
		elif coverage < 1.0 and decontaminate:
			var inverse := 1.0 / coverage
			var rest := 1.0 - coverage
			var pure_r := clampf((r - rest * pixel_key.r) * inverse, 0.0, 1.0)
			var pure_g := clampf((g - rest * pixel_key.g) * inverse, 0.0, 1.0)
			var pure_b := clampf((b - rest * pixel_key.b) * inverse, 0.0, 1.0)
			if coverage < _DECONTAMINATE_FADE and neighbour >= 0:
				var weight := coverage / _DECONTAMINATE_FADE
				var bleed_offset := neighbour * 4
				r = lerpf(data[bleed_offset] * to_unit, pure_r, weight)
				g = lerpf(data[bleed_offset + 1] * to_unit, pure_g, weight)
				b = lerpf(data[bleed_offset + 2] * to_unit, pure_b, weight)
			else:
				r = pure_r
				g = pure_g
				b = pure_b

		out[offset] = roundi(clampf(r, 0.0, 1.0) * 255.0)
		out[offset + 1] = roundi(clampf(g, 0.0, 1.0) * 255.0)
		out[offset + 2] = roundi(clampf(b, 0.0, 1.0) * 255.0)
		out[offset + 3] = roundi(clampf(source_alpha * coverage, 0.0, 1.0) * 255.0)

	return Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, out)


## Largest per-channel distance from [member key_color], per pixel.
##
## The max-channel metric is the one that makes the coverage maths work: under
## [code]C = a * F + (1 - a) * K[/code] every channel difference scales by the
## same [code]a[/code], so their maximum does too. A euclidean or luminance
## distance would not survive being divided by a neighbour's distance.
func _distance_map(data: PackedByteArray, pixel_count: int) -> PackedFloat32Array:
	var dist := PackedFloat32Array()
	dist.resize(pixel_count)
	var to_unit := 1.0 / 255.0
	var key_r := key_color.r
	var key_g := key_color.g
	var key_b := key_color.b
	for i in pixel_count:
		var offset := i * 4
		var dr := absf(data[offset] * to_unit - key_r)
		var dg := absf(data[offset + 1] * to_unit - key_g)
		var db := absf(data[offset + 2] * to_unit - key_b)
		dist[i] = maxf(dr, maxf(dg, db))
	return dist


## The same metric as [method _distance_map], for one pixel against any key.
func _distance_at(data: PackedByteArray, index: int, key: Color) -> float:
	var offset := index * 4
	var to_unit := 1.0 / 255.0
	return maxf(
		absf(data[offset] * to_unit - key.r),
		maxf(absf(data[offset + 1] * to_unit - key.g), absf(data[offset + 2] * to_unit - key.b)),
	)


func _color_at(data: PackedByteArray, index: int) -> Color:
	var offset := index * 4
	var to_unit := 1.0 / 255.0
	return Color(data[offset] * to_unit, data[offset + 1] * to_unit, data[offset + 2] * to_unit)


## Sorts every pixel into background, antialiased edge, or subject, and records
## which background colour claimed it.
##
## Returns [code][mask, key_of, keys][/code]: the class per pixel, the index into
## [code]keys[/code] that claimed it (-1 for subject), and the background colours
## in play — the operation's own key first, then one per picked island.
##
## Two passes over one queue. The first claims the background itself — pixels
## within [member tolerance] of the colour keying their region, flood filled
## inwards from the image border (plus any [member island_points]) when
## [member contiguous] is set, which is what keeps unpicked enclosed regions
## opaque. The second walks [member edge_width] steps further in from that
## background and calls what it touches the antialiased band, inheriting the key
## it grew from.
##
## Classifying by distance-from-background rather than by colour is the whole
## trick. A pixel's colour genuinely cannot distinguish a half-covered distant
## subject from a fully covered near-key one, but position can: real antialiasing
## only ever occurs in a thin band against the background.
func _classify(data: PackedByteArray, key_dist: PackedFloat32Array, width: int, height: int) -> Array:
	var pixel_count := width * height
	var keys: Array[Color] = [key_color]
	var mask := PackedByteArray()
	mask.resize(pixel_count)
	mask.fill(MASK_SUBJECT)
	var key_of := PackedInt32Array()
	key_of.resize(pixel_count)
	key_of.fill(-1)

	# Each pixel is claimed at most once, so the queue can be sized up front and
	# used as a plain FIFO with no wraparound.
	var queue := PackedInt32Array()
	queue.resize(pixel_count)
	var head := 0
	var tail := 0

	# How many weak pixels in a row the flood crossed to reach each pixel; zero
	# on anything solidly background. See [method _flood_step].
	var weak_steps := PackedInt32Array()
	weak_steps.resize(pixel_count)

	if contiguous:
		for x in width:
			var top := x
			if mask[top] != MASK_BACKGROUND and key_dist[top] <= tolerance:
				mask[top] = MASK_BACKGROUND
				key_of[top] = 0
				queue[tail] = top
				tail += 1
			var bottom := (height - 1) * width + x
			if mask[bottom] != MASK_BACKGROUND and key_dist[bottom] <= tolerance:
				mask[bottom] = MASK_BACKGROUND
				key_of[bottom] = 0
				queue[tail] = bottom
				tail += 1
		for y in height:
			var row_start := y * width
			if mask[row_start] != MASK_BACKGROUND and key_dist[row_start] <= tolerance:
				mask[row_start] = MASK_BACKGROUND
				key_of[row_start] = 0
				queue[tail] = row_start
				tail += 1
			var row_end := row_start + width - 1
			if mask[row_end] != MASK_BACKGROUND and key_dist[row_end] <= tolerance:
				mask[row_end] = MASK_BACKGROUND
				key_of[row_end] = 0
				queue[tail] = row_end
				tail += 1

		# Picked islands join the same queue as the border, each carrying
		# the colour of the pixel it landed on. An island always takes, since its
		# key is that pixel's own colour — the user pointed at what to remove.
		# One already swallowed by the border flood adds nothing, so it is
		# skipped rather than duplicating a key.
		for point in island_points:
			if point.x < 0 or point.y < 0 or point.x >= width or point.y >= height:
				continue
			var island_index := point.y * width + point.x
			if mask[island_index] == MASK_BACKGROUND:
				continue
			keys.append(_color_at(data, island_index))
			mask[island_index] = MASK_BACKGROUND
			key_of[island_index] = keys.size() - 1
			queue[tail] = island_index
			tail += 1

		# 4-connected on purpose: 8-connectivity leaks through diagonal
		# hairlines in thin subjects such as lettering or wire-frame art.
		while head < tail:
			var index := queue[head]
			head += 1
			var claimed_by := key_of[index]
			var key: Color = keys[claimed_by]
			var weak_here := weak_steps[index]
			var x := index % width
			@warning_ignore("integer_division")
			var y := index / width
			if x > 0:
				var left := index - 1
				if mask[left] != MASK_BACKGROUND:
					var step := _flood_step(data, key_dist, left, claimed_by, key, weak_here)
					if step >= 0:
						mask[left] = MASK_BACKGROUND
						key_of[left] = claimed_by
						weak_steps[left] = step
						queue[tail] = left
						tail += 1
			if x < width - 1:
				var right := index + 1
				if mask[right] != MASK_BACKGROUND:
					var step := _flood_step(data, key_dist, right, claimed_by, key, weak_here)
					if step >= 0:
						mask[right] = MASK_BACKGROUND
						key_of[right] = claimed_by
						weak_steps[right] = step
						queue[tail] = right
						tail += 1
			if y > 0:
				var up := index - width
				if mask[up] != MASK_BACKGROUND:
					var step := _flood_step(data, key_dist, up, claimed_by, key, weak_here)
					if step >= 0:
						mask[up] = MASK_BACKGROUND
						key_of[up] = claimed_by
						weak_steps[up] = step
						queue[tail] = up
						tail += 1
			if y < height - 1:
				var down := index + width
				if mask[down] != MASK_BACKGROUND:
					var step := _flood_step(data, key_dist, down, claimed_by, key, weak_here)
					if step >= 0:
						mask[down] = MASK_BACKGROUND
						key_of[down] = claimed_by
						weak_steps[down] = step
						queue[tail] = down
						tail += 1
		# A pixel the flood only squeezed through is not background — it is the
		# antialiasing of the two walls it passed between, so it is part subject.
		# Handing it to the band gives it partial alpha from the usual coverage
		# maths, where calling it background would cut a hard notch out of the
		# crevice mouth. It stays in the queue, so the band still grows from it.
		if crevice_reach > 0:
			for i in pixel_count:
				if mask[i] == MASK_BACKGROUND and weak_steps[i] > 0:
					mask[i] = MASK_EDGE
	else:
		# Without contiguity there is nothing to flood from, so picked islands have
		# no meaning: every key-coloured pixel already qualifies.
		for i in pixel_count:
			if key_dist[i] <= tolerance:
				mask[i] = MASK_BACKGROUND
				key_of[i] = 0
				queue[tail] = i
				tail += 1

	# Second pass: grow the edge band inwards from the background. The queue
	# still holds every background pixel, so rewinding the head walks outwards in
	# lock-step and depth stays correct. Pixels within tolerance of the inherited
	# key are skipped so an unpicked enclosed region keeps its full alpha rather
	# than gaining a torn rim.
	var depth := PackedInt32Array()
	depth.resize(pixel_count)
	head = 0
	while head < tail:
		var index := queue[head]
		head += 1
		var step := depth[index] + 1
		if step > edge_width:
			continue
		var claimed_by := key_of[index]
		var key: Color = keys[claimed_by]
		var x := index % width
		@warning_ignore("integer_division")
		var y := index / width
		if x > 0:
			var left := index - 1
			if mask[left] == MASK_SUBJECT and _region_distance(data, key_dist, left, claimed_by, key) > tolerance:
				mask[left] = MASK_EDGE
				key_of[left] = claimed_by
				depth[left] = step
				queue[tail] = left
				tail += 1
		if x < width - 1:
			var right := index + 1
			if mask[right] == MASK_SUBJECT and _region_distance(data, key_dist, right, claimed_by, key) > tolerance:
				mask[right] = MASK_EDGE
				key_of[right] = claimed_by
				depth[right] = step
				queue[tail] = right
				tail += 1
		if y > 0:
			var up := index - width
			if mask[up] == MASK_SUBJECT and _region_distance(data, key_dist, up, claimed_by, key) > tolerance:
				mask[up] = MASK_EDGE
				key_of[up] = claimed_by
				depth[up] = step
				queue[tail] = up
				tail += 1
		if y < height - 1:
			var down := index + width
			if mask[down] == MASK_SUBJECT and _region_distance(data, key_dist, down, claimed_by, key) > tolerance:
				mask[down] = MASK_EDGE
				key_of[down] = claimed_by
				depth[down] = step
				queue[tail] = down
				tail += 1

	return [mask, key_of, keys]


## Distance from a pixel to the key of the region claiming it, taking the
## precomputed map for the operation's own key and measuring the rest on demand.
func _region_distance(data: PackedByteArray, key_dist: PackedFloat32Array, index: int, key_index: int, key: Color) -> float:
	return key_dist[index] if key_index == 0 else _distance_at(data, index, key)


## Whether the flood may step onto [param index], and at what weak-step count.
## Returns -1 to refuse, otherwise the count to record there.
##
## This is Canny's double threshold applied to region growing rather than edge
## linking. A pixel within [member tolerance] is solid background and resets the
## count; one merely within [member crevice_tolerance] may still be crossed, but
## only [member crevice_reach] of them in a row before solid background is needed
## again. That is what gets into a crevice whose neck is nothing but the
## antialiasing of the two walls meeting, while stopping the flood from wandering
## off across a pale subject, which an unbounded weak threshold would do.
##
## First visit wins rather than the lowest count, so a pixel reachable two ways
## may keep a worse count than it deserves. That only ever makes the flood stop
## short — it can never reach further than the rule allows — so the failure mode
## is background left behind, never subject eaten.
func _flood_step(data: PackedByteArray, key_dist: PackedFloat32Array, index: int, key_index: int, key: Color, from_weak: int) -> int:
	var distance := _region_distance(data, key_dist, index, key_index, key)
	if distance <= tolerance:
		return 0
	if crevice_reach > 0 and from_weak < crevice_reach and distance <= maxf(crevice_tolerance, tolerance):
		return from_weak + 1
	return -1


## For every pixel, the index of the closest opaque subject pixel, or -1 if none
## lies within [param radius].
##
## A grassfire expansion seeded from all subject pixels at once, so the whole map
## costs one pass over the image rather than a windowed search per edge pixel. It
## feeds both the coverage estimate (as the reference distance) and the colour
## bleed (as the replacement RGB).
##
## Subject pixels that look like the operation's own background colour are excluded
## as sources — an unpicked enclosed region is opaque, but keying off its colour
## would hand edge pixels the very background we are trying to remove. Island keys
## are deliberately not excluded here: a colour an island keys out in one place is
## legitimate subject material elsewhere in the image.
func _nearest_subject_map(mask: PackedByteArray, key_dist: PackedFloat32Array, width: int, height: int, radius: int) -> PackedInt32Array:
	var pixel_count := width * height
	var nearest := PackedInt32Array()
	nearest.resize(pixel_count)
	nearest.fill(-1)
	var steps := PackedInt32Array()
	steps.resize(pixel_count)
	var queue := PackedInt32Array()
	queue.resize(pixel_count)
	var head := 0
	var tail := 0

	for i in pixel_count:
		if mask[i] == MASK_SUBJECT and key_dist[i] > tolerance:
			nearest[i] = i
			queue[tail] = i
			tail += 1

	while head < tail:
		var index := queue[head]
		head += 1
		var step := steps[index] + 1
		if step > radius:
			continue
		var source := nearest[index]
		var x := index % width
		@warning_ignore("integer_division")
		var y := index / width
		if x > 0:
			var left := index - 1
			if nearest[left] == -1:
				nearest[left] = source
				steps[left] = step
				queue[tail] = left
				tail += 1
		if x < width - 1:
			var right := index + 1
			if nearest[right] == -1:
				nearest[right] = source
				steps[right] = step
				queue[tail] = right
				tail += 1
		if y > 0:
			var up := index - width
			if nearest[up] == -1:
				nearest[up] = source
				steps[up] = step
				queue[tail] = up
				tail += 1
		if y < height - 1:
			var down := index + width
			if nearest[down] == -1:
				nearest[down] = source
				steps[down] = step
				queue[tail] = down
				tail += 1

	return nearest


## Highest distance from [param key] within [param radius] of [param index].
##
## Only reached for edge pixels that have no opaque subject nearby, which means
## thin features, so the windowed search stays rare.
func _local_maximum(data: PackedByteArray, width: int, height: int, index: int, radius: int, key: Color) -> float:
	var center_x := index % width
	@warning_ignore("integer_division")
	var center_y := index / width
	var min_x := maxi(center_x - radius, 0)
	var max_x := mini(center_x + radius, width - 1)
	var min_y := maxi(center_y - radius, 0)
	var max_y := mini(center_y + radius, height - 1)
	var best := _distance_at(data, index, key)
	for y in range(min_y, max_y + 1):
		var row := y * width
		for x in range(min_x, max_x + 1):
			var value := _distance_at(data, row + x, key)
			if value > best:
				best = value
	return best
