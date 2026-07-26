@tool
class_name IWBackgroundRemover
extends IWOperation

## Removes a flat background (pure white by default) while preserving the
## antialiased silhouette.
##
## Naively deleting every white pixel fails in one of two ways: a tight
## threshold keeps the half-white edge pixels and leaves a white fringe, a loose
## one eats the soft edge and leaves a jagged cutout. Neither is fixable by
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
## divisor comes from the nearest fully opaque pixel, so the estimate stays
## local and works whether the subject there is black or barely off-white.
##
## [b]Finding the edge.[/b] Coverage alone cannot say whether a light grey pixel
## is a half-covered dark subject or a fully covered light grey one — the two
## are numerically identical. Colour thresholds cannot break that tie, so
## geometry does: antialiasing lives in a thin band hugging the background, so
## pixels are classified by their distance from the flood-filled background
## rather than by how pale they are. See [method _classify].
##
## [b]Killing the fringe.[/b] Correct alpha is only half the job. The RGB of a
## half-covered pixel is still half background, and that residue is what shows
## up as a white outline once the image is composited. So the background is
## un-blended back out:
## [codeblock]
##     F = (C - (1 - a) * K) / a
## [/codeblock]
## Finally the subject colour is bled outwards into the fully transparent
## pixels. Their alpha is zero, but bilinear filtering and mipmaps still sample
## their RGB, which is how white creeps back into an edge that looked clean in
## the file.

## Background colour to key out. Pure white is the default; the maths holds for
## any flat colour.
var key_color: Color = Color.WHITE

## How far a pixel may drift from [member key_color] and still count as pure
## background.
var tolerance: float = 0.02

## Width of the antialiased band, in pixels. Pixels within this many steps of
## the background are treated as a soft edge and given partial alpha; anything
## further in is fully opaque subject.
var edge_width: int = 2

## Pulls the soft edge inwards. Useful when a source image was flattened onto
## white twice and a faint halo survives.
var edge_contract: float = 0.0

## Only remove background reachable from the image border, so white enclosed by
## the subject (eyes, speech bubbles, specular highlights) stays opaque.
var contiguous: bool = true

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
## amplifies source noise into confetti, so its result is faded into the
## nearest known subject colour instead.
const _DECONTAMINATE_FADE := 0.25

## Minimum reach for the nearest-subject map. Coverage estimation needs a
## couple of pixels of reach even when colour bleed is switched off.
const _MIN_SEARCH_RADIUS := 2


func get_operation_name() -> String:
	return "Remove Background"


func get_operation_description() -> String:
	return "Keys out a flat white background and rebuilds the antialiased edge."


func get_output_suffix() -> String:
	return "_nobg"


func get_settings_schema() -> Array[Dictionary]:
	return [
		{
			"property": &"tolerance",
			"label": "White Tolerance",
			"type": SettingType.FLOAT,
			"min": 0.0,
			"max": 0.5,
			"step": 0.005,
			"tooltip": "How far a pixel may drift from pure white and still count as background.\nRaise this if a re-compressed background leaves speckles behind.",
		},
		{
			"property": &"edge_width",
			"label": "Edge Width",
			"type": SettingType.INT,
			"min": 0,
			"max": 16,
			"step": 1,
			"tooltip": "How many pixels of antialiasing to rebuild around the subject.\n2 suits ordinary antialiasing. Raise it for soft edges, glows or\ndrop shadows; set it to 0 for a hard-edged cutout.",
		},
		{
			"property": &"edge_contract",
			"label": "Edge Contract",
			"type": SettingType.FLOAT,
			"min": 0.0,
			"max": 0.9,
			"step": 0.01,
			"tooltip": "Pulls the soft edge inwards. Leave at zero unless a faint halo survives.",
		},
		{
			"property": &"contiguous",
			"label": "Only Outer Background",
			"type": SettingType.BOOL,
			"tooltip": "Flood fill inwards from the image border, so white areas enclosed by the\nsubject (eyes, highlights, gaps in lettering) stay opaque.",
		},
		{
			"property": &"decontaminate",
			"label": "Remove White Fringe",
			"type": SettingType.BOOL,
			"tooltip": "Un-blends white out of partially transparent pixels.\nThis is what stops a white outline appearing once the image is composited.",
		},
		{
			"property": &"bleed_radius",
			"label": "Color Bleed",
			"type": SettingType.INT,
			"min": 0,
			"max": 64,
			"step": 1,
			"tooltip": "Pushes subject colour into fully transparent pixels, in pixels.\nTexture filtering and mipmaps sample RGB even where alpha is zero, so\nwithout this the background can bleed back into the edge on screen.",
		},
	]


## Convenience entry point for code that just wants the default behaviour.
static func remove_white_background(source: Image) -> Image:
	return IWBackgroundRemover.new().process_image(source)


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
	var dist := _distance_map(data, pixel_count)
	var mask := _classify(dist, width, height)
	var search_radius := maxi(maxi(bleed_radius, edge_width), _MIN_SEARCH_RADIUS)
	var nearest := _nearest_subject_map(mask, dist, width, height, search_radius)

	var out := PackedByteArray()
	out.resize(pixel_count * 4)
	var to_unit := 1.0 / 255.0
	var key_r := key_color.r
	var key_g := key_color.g
	var key_b := key_color.b
	var contract_scale := 1.0 / maxf(1.0 - edge_contract, _EPSILON)

	for i in pixel_count:
		var offset := i * 4
		var r := data[offset] * to_unit
		var g := data[offset + 1] * to_unit
		var b := data[offset + 2] * to_unit
		var source_alpha := data[offset + 3] * to_unit
		var neighbour := nearest[i]
		var coverage := 1.0

		if mask[i] == MASK_BACKGROUND:
			coverage = 0.0
		elif mask[i] == MASK_EDGE:
			# Measure this pixel against the nearest opaque subject pixel. For a
			# genuine antialiased edge that ratio *is* the pixel's coverage.
			var reference := 0.0
			if neighbour >= 0:
				reference = dist[neighbour]
			else:
				# Nothing opaque within reach: the band has swallowed a thin
				# feature whole. Fall back to the strongest pixel nearby, which
				# for a stroke is its own core, so it keeps its shape instead of
				# being fattened to fully opaque.
				reference = _local_maximum(dist, width, height, i, edge_width)
			var d := dist[i]
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
			var pure_r := clampf((r - rest * key_r) * inverse, 0.0, 1.0)
			var pure_g := clampf((g - rest * key_g) * inverse, 0.0, 1.0)
			var pure_b := clampf((b - rest * key_b) * inverse, 0.0, 1.0)
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


## Sorts every pixel into background, antialiased edge, or subject.
##
## Two passes over one queue. The first claims the background itself — pixels
## within [member tolerance] of the key colour, flood filled inwards from the
## image border when [member contiguous] is set, which is what keeps enclosed
## white regions opaque. The second walks [member edge_width] steps further in
## from that background and calls what it touches the antialiased band.
##
## Classifying by distance-from-background rather than by colour is the whole
## trick. A pixel's paleness genuinely cannot distinguish a half-covered dark
## subject from a fully covered pale one, but position can: real antialiasing
## only ever occurs in a thin band against the background.
func _classify(dist: PackedFloat32Array, width: int, height: int) -> PackedByteArray:
	var pixel_count := width * height
	var mask := PackedByteArray()
	mask.resize(pixel_count)
	mask.fill(MASK_SUBJECT)

	# Each pixel is claimed at most once, so the queue can be sized up front
	# and used as a plain FIFO with no wraparound.
	var queue := PackedInt32Array()
	queue.resize(pixel_count)
	var head := 0
	var tail := 0

	if contiguous:
		for x in width:
			var top := x
			if mask[top] != MASK_BACKGROUND and dist[top] <= tolerance:
				mask[top] = MASK_BACKGROUND
				queue[tail] = top
				tail += 1
			var bottom := (height - 1) * width + x
			if mask[bottom] != MASK_BACKGROUND and dist[bottom] <= tolerance:
				mask[bottom] = MASK_BACKGROUND
				queue[tail] = bottom
				tail += 1
		for y in height:
			var row_start := y * width
			if mask[row_start] != MASK_BACKGROUND and dist[row_start] <= tolerance:
				mask[row_start] = MASK_BACKGROUND
				queue[tail] = row_start
				tail += 1
			var row_end := row_start + width - 1
			if mask[row_end] != MASK_BACKGROUND and dist[row_end] <= tolerance:
				mask[row_end] = MASK_BACKGROUND
				queue[tail] = row_end
				tail += 1

		# 4-connected on purpose: 8-connectivity leaks through diagonal
		# hairlines in thin subjects such as lettering or wire-frame art.
		while head < tail:
			var index := queue[head]
			head += 1
			var x := index % width
			@warning_ignore("integer_division")
			var y := index / width
			if x > 0:
				var left := index - 1
				if mask[left] != MASK_BACKGROUND and dist[left] <= tolerance:
					mask[left] = MASK_BACKGROUND
					queue[tail] = left
					tail += 1
			if x < width - 1:
				var right := index + 1
				if mask[right] != MASK_BACKGROUND and dist[right] <= tolerance:
					mask[right] = MASK_BACKGROUND
					queue[tail] = right
					tail += 1
			if y > 0:
				var up := index - width
				if mask[up] != MASK_BACKGROUND and dist[up] <= tolerance:
					mask[up] = MASK_BACKGROUND
					queue[tail] = up
					tail += 1
			if y < height - 1:
				var down := index + width
				if mask[down] != MASK_BACKGROUND and dist[down] <= tolerance:
					mask[down] = MASK_BACKGROUND
					queue[tail] = down
					tail += 1
	else:
		for i in pixel_count:
			if dist[i] <= tolerance:
				mask[i] = MASK_BACKGROUND
				queue[tail] = i
				tail += 1

	# Second pass: grow the edge band inwards from the background. The queue
	# still holds every background pixel, so rewinding the head walks outwards
	# in lock-step and depth stays correct. Pixels within tolerance are skipped
	# so enclosed white keeps its full alpha rather than gaining a torn rim.
	var depth := PackedInt32Array()
	depth.resize(pixel_count)
	head = 0
	while head < tail:
		var index := queue[head]
		head += 1
		var step := depth[index] + 1
		if step > edge_width:
			continue
		var x := index % width
		@warning_ignore("integer_division")
		var y := index / width
		if x > 0:
			var left := index - 1
			if mask[left] == MASK_SUBJECT and dist[left] > tolerance:
				mask[left] = MASK_EDGE
				depth[left] = step
				queue[tail] = left
				tail += 1
		if x < width - 1:
			var right := index + 1
			if mask[right] == MASK_SUBJECT and dist[right] > tolerance:
				mask[right] = MASK_EDGE
				depth[right] = step
				queue[tail] = right
				tail += 1
		if y > 0:
			var up := index - width
			if mask[up] == MASK_SUBJECT and dist[up] > tolerance:
				mask[up] = MASK_EDGE
				depth[up] = step
				queue[tail] = up
				tail += 1
		if y < height - 1:
			var down := index + width
			if mask[down] == MASK_SUBJECT and dist[down] > tolerance:
				mask[down] = MASK_EDGE
				depth[down] = step
				queue[tail] = down
				tail += 1

	return mask


## For every pixel, the index of the closest opaque subject pixel, or -1 if none
## lies within [param radius].
##
## A grassfire expansion seeded from all subject pixels at once, so the whole
## map costs one pass over the image rather than a windowed search per edge
## pixel. It feeds both the coverage estimate (as the reference distance) and
## the colour bleed (as the replacement RGB). Enclosed background pixels are
## excluded as seeds — they are opaque, but keying off their colour would hand
## edge pixels the very background colour we are trying to remove.
func _nearest_subject_map(mask: PackedByteArray, dist: PackedFloat32Array, width: int, height: int, radius: int) -> PackedInt32Array:
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
		if mask[i] == MASK_SUBJECT and dist[i] > tolerance:
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


## Highest distance-from-background within [param radius] of [param index].
##
## Only reached for edge pixels that have no opaque subject nearby, which means
## thin features, so the windowed search stays rare.
func _local_maximum(dist: PackedFloat32Array, width: int, height: int, index: int, radius: int) -> float:
	var center_x := index % width
	@warning_ignore("integer_division")
	var center_y := index / width
	var min_x := maxi(center_x - radius, 0)
	var max_x := mini(center_x + radius, width - 1)
	var min_y := maxi(center_y - radius, 0)
	var max_y := mini(center_y + radius, height - 1)
	var best := dist[index]
	for y in range(min_y, max_y + 1):
		var row := y * width
		for x in range(min_x, max_x + 1):
			var value := dist[row + x]
			if value > best:
				best = value
	return best
