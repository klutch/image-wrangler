@tool
class_name IWPipelineContext
extends RefCounted

## The buffers one run of an [IWPipeline] passes from stage to stage.
##
## Operations in the stack are not image-to-image filters. Splitting them that way
## would mean each one re-deriving from RGBA what the one above it already knew:
## the guided filter would lose the distance-from-key it uses as a guide, the
## fringe removal would lose which background claimed each pixel, and the crevice
## pass would have nothing but alpha to grow through. So a stage reads and writes
## this instead, and the pixels are written out once at the end by [IWCompose].
##
## [b]The source is immutable.[/b] [member data] is the image as it arrived and no
## stage may write to it. Everything a stage decides goes into [member coverage],
## [member mask] or [member key_of] — which is what lets a later stage measure
## against the original colours rather than against a half-finished result.
##
## [RefCounted] rather than [Resource], deliberately: [code]IWSettingsIO[/code]
## walks anything with storage flags, and a context reachable from a settings
## object would be serialised into a sidecar.


## Pixel classes in [member mask].
const MASK_BACKGROUND := 0
const MASK_EDGE := 1
const MASK_SUBJECT := 2

## Values of [member key_of] that are not indices into [member keys].
##
## [constant KEY_CLEAR] marks a pixel that arrived fully transparent. It is
## background, but it was not keyed out by anything and has no colour to un-blend
## against, so it must not be confused with a pixel some entry claimed.
const KEY_NONE := -1
const KEY_CLEAR := -2

## Values in [member blacked].
const REGION_NONE := 0
const REGION_CUT := 1
const REGION_KEEP := 2

## Guards divisions where the denominator can legitimately collapse to zero.
const EPSILON := 0.0001

## Minimum reach for the nearest-subject map. Coverage estimation needs a couple
## of pixels of reach even when colour bleed is switched off.
const MIN_SEARCH_RADIUS := 2

## The source image, RGBA8, four bytes per pixel. Read-only to every stage.
var data: PackedByteArray

var width := 0
var height := 0
var pixel_count := 0

## Every background colour in play this run, and the tolerance belonging to each.
##
## Parallel arrays rather than the [RemoveColorEntry] objects themselves, because
## the per-pixel loops index these millions of times and a property lookup on a
## Resource is not free.
var keys: Array[Color] = []
var key_tolerances: Array[float] = []

## Which of [member keys] came from a picked island rather than from a Remove
## Colors list, one byte each.
##
## A flag per key rather than a count of the colours, because a stack can add keys
## from more than one place and in any order — an Island Picker between two Remove
## Backgrounds would break any rule that assumed the colours came first.
##
## The distinction matters because an island's key is the colour of one spot the
## user pointed at, which is a licence to remove that region rather than every
## pixel of that colour in the image. See [method claiming_key].
var key_is_island := PackedByteArray()

## Largest per-channel distance from [code]keys[0][/code], per pixel. Empty until
## a stage builds it.
##
## Only the first key is worth a whole map. It is the one the border flood almost
## always starts from, and the rest are measured on demand by [method distance_at]
## — a second map per key would cost a pass over the image each to serve a handful
## of pixels.
var key_dist := PackedFloat32Array()

## One [constant MASK_BACKGROUND]/[constant MASK_EDGE]/[constant MASK_SUBJECT] per
## pixel, and the key that claimed each. Empty until a stage classifies.
var mask := PackedByteArray()
var key_of := PackedInt32Array()

## For every pixel, the index of the closest opaque subject pixel, or -1 if none
## lies within [member search_radius]. Empty until a stage builds it.
var nearest := PackedInt32Array()

## Alpha per pixel, 0 to 1, before it is multiplied by the source's own. The
## buffer every stage after the classification is really arguing about.
var coverage := PackedFloat32Array()

## What the drawn regions do at each pixel, or empty when none are drawn.
var blacked := PackedByteArray()

## Non-zero wherever a picked Add island protects the pixel, or empty when there
## are none.
var protect := PackedByteArray()

## Non-zero wherever the result is opaque whatever the source was, or empty.
##
## Distinct from a coverage of 1.0, which still gets multiplied by the alpha the
## source arrived with. This says the user drew or picked something here and wants
## it solid — so a region added over a hole fills the hole rather than agreeing
## with it.
var force_opaque := PackedByteArray()

## Stroke strength per pixel for each band, and a colour per pixel when the stroke
## takes its colour from the image. All empty when nothing is being stroked.
var stroke_inner := PackedFloat32Array()
var stroke_outer := PackedFloat32Array()
var stroke_colors := PackedFloat32Array()

## How the final write should treat what the stages left behind. Set by whichever
## stage owns each: the band width and the bleed by Remove Background, the stroke
## colour by Edge Cleanup.
var edge_width := 0
var bleed_radius := 0
var decontaminate := false
var search_radius := MIN_SEARCH_RADIUS
var stroke_color := Color(0, 0, 0, 0)

## Whether any stage has established keys to measure against. Stages that can only
## work relative to a background check this and stand down.
var has_keying := false


func _init(source_data: PackedByteArray, source_width: int, source_height: int) -> void:
	data = source_data
	width = source_width
	height = source_height
	pixel_count = source_width * source_height


## A context over [param source], decompressed and converted to RGBA8.
##
## The one place a run gets its pixels, so every entry point agrees on what a
## stage may assume about them: eight bits a channel, four channels, never
## compressed. [param source] itself is left untouched.
static func from_image(source: Image) -> IWPipelineContext:
	var image := Image.new()
	image.copy_from(source)
	if image.is_compressed():
		image.decompress()
	if image.get_format() != Image.FORMAT_RGBA8:
		image.convert(Image.FORMAT_RGBA8)
	return IWPipelineContext.new(image.get_data(), image.get_width(), image.get_height())


## Largest per-channel distance from [param key] for one pixel.
##
## The max-channel metric is the one that makes the coverage maths work: under
## [code]C = a * F + (1 - a) * K[/code] every channel difference scales by the
## same [code]a[/code], so their maximum does too. A euclidean or luminance
## distance would not survive being divided by a neighbour's distance.
func distance_at(index: int, key: Color) -> float:
	var offset := index * 4
	var to_unit := 1.0 / 255.0
	return maxf(
		absf(data[offset] * to_unit - key.r),
		maxf(absf(data[offset + 1] * to_unit - key.g), absf(data[offset + 2] * to_unit - key.b)),
	)


func color_at(index: int) -> Color:
	var offset := index * 4
	var to_unit := 1.0 / 255.0
	return Color(data[offset] * to_unit, data[offset + 1] * to_unit, data[offset + 2] * to_unit)


## Whether a source pixel arrived fully transparent, and so is already removed.
##
## Exactly zero rather than a threshold. A partly transparent pixel is a real
## antialiased edge carrying real coverage, and treating it as empty would eat the
## soft edge of anything processed twice. Zero is what this pipeline itself writes
## for background, so a second run recognises its own first one.
func is_clear(index: int) -> bool:
	return data[index * 4 + 3] == 0


## Distance from a pixel to key [param k], taking the precomputed map for the
## first key and measuring the rest on demand.
func key_distance(index: int, k: int) -> float:
	return key_dist[index] if k == 0 else distance_at(index, keys[k])


## Index of the first non-island key claiming [param index], or [constant KEY_NONE].
##
## First match rather than closest match, so the list reads as an ordered set of
## rules. Two entries close enough to both claim a pixel are describing the same
## background twice, and which of them wins matters far less than the answer being
## the one the user can see at the top of the list.
##
## Islands are deliberately skipped, for the reason given on [member key_is_island].
##
## The first key is unrolled out of the loop. This is called once per pixel by both
## the nearest-subject map and the non-contiguous classification, and for the
## overwhelmingly common single-colour list that leaves it an array lookup and a
## compare rather than a nested call per pixel.
func claiming_key(index: int) -> int:
	var count := keys.size()
	if count == 0:
		return KEY_NONE
	if key_is_island[0] == 0 and key_dist[index] <= key_tolerances[0]:
		return 0
	for k in range(1, count):
		if key_is_island[k] != 0:
			continue
		if distance_at(index, keys[k]) <= key_tolerances[k]:
			return k
	return KEY_NONE


## The key [param to] should take for a flood arriving from [param from_key], or
## [constant KEY_NONE] to refuse it.
##
## Returns the key rather than letting the caller inherit one, because the key that
## arrives is not always the key that applies. A flood spreads through the
## background as a whole, not through one colour of it: a pixel the arriving key
## refuses is offered to the rest of the list, and takes whichever entry claims it.
## Reaching a colour is therefore a question of a path existing through listed
## colours, not of that colour touching the image border itself.
##
## Transparency is the other case. A transparent pixel is open ground — already
## removed, so any flood crosses it — and it carries no colour of its own to pass
## on, so the first opaque pixel on the far side is offered to the whole list
## afresh. That is what lets a background reach a region walled off by a hole,
## which is the normal shape of an image this pipeline has already run over once.
##
## Shared by every flood here, so an island reaches as far through mixed background
## as the border flood does.
func flood_key_for(to: int, from_key: int) -> int:
	if is_clear(to):
		return KEY_CLEAR
	if from_key == KEY_CLEAR:
		return claiming_key(to)
	if key_distance(to, from_key) <= key_tolerances[from_key]:
		return from_key
	# The arriving key does not want it, so the rest of the list is asked before
	# giving up. Two flat backgrounds meeting — a white plate around a green stem —
	# are one region to the eye and have to be one to the flood, or the second
	# colour would only ever work where it independently touched the image border,
	# which is almost never.
	return claiming_key(to)


## Highest distance from [param key] within [param radius] of [param index].
##
## Only reached for edge pixels that have no opaque subject nearby, which means
## thin features, so the windowed search stays rare.
func local_maximum(index: int, radius: int, key: Color) -> float:
	var center_x := index % width
	@warning_ignore("integer_division")
	var center_y := index / width
	var min_x := maxi(center_x - radius, 0)
	var max_x := mini(center_x + radius, width - 1)
	var min_y := maxi(center_y - radius, 0)
	var max_y := mini(center_y + radius, height - 1)
	var best := distance_at(index, key)
	for y in range(min_y, max_y + 1):
		var row := y * width
		for x in range(min_x, max_x + 1):
			var value := distance_at(row + x, key)
			if value > best:
				best = value
	return best


## The alpha the image ends up with, 0 to 1: the source's own multiplied by the
## coverage worked out for it, forced solid where [member force_opaque] says so.
##
## What [IWCompose] is about to write, ahead of it writing it, so the stroke can
## measure its silhouette from the shape that actually comes out.
func final_alpha() -> PackedFloat32Array:
	var alpha := PackedFloat32Array()
	alpha.resize(pixel_count)
	var to_unit := 1.0 / 255.0
	var has_coverage := not coverage.is_empty()
	var has_force := not force_opaque.is_empty()
	for i in pixel_count:
		if has_force and force_opaque[i] != 0:
			alpha[i] = 1.0
			continue
		var value := data[i * 4 + 3] * to_unit
		if has_coverage:
			value *= coverage[i]
		alpha[i] = value
	return alpha


## Fills [member coverage] with full opacity, for a run where nothing has keyed
## anything out and the regions are the whole story.
func ensure_coverage() -> void:
	if not coverage.is_empty():
		return
	coverage.resize(pixel_count)
	coverage.fill(1.0)


## Whether a classification exists for a stage to build on.
func has_classification() -> bool:
	return not mask.is_empty()


## Adds a key and returns its index.
##
## Appends rather than replacing, so a second keying stage adds to what the first
## established instead of overruling it. [param island] flags a key that seeds one
## region rather than being matched image-wide; see [member key_is_island].
func add_key(key: Color, tolerance: float, island: bool) -> int:
	keys.append(key)
	key_tolerances.append(tolerance)
	key_is_island.append(1 if island else 0)
	has_keying = true
	ensure_key_dist()
	return keys.size() - 1


## Builds [member key_dist] against the first key, if it is not built already.
##
## Called by whichever stage registers the first key, so [method key_distance] can
## read the map unconditionally rather than testing for it once per neighbour
## visited in every flood.
##
## Only the first key gets a map, for the reason on [member key_dist]. It stays
## pointed at whichever key came first even after more are added: the map is an
## optimisation for the one the border flood almost always starts from, not a fact
## about the list.
func ensure_key_dist() -> void:
	if not key_dist.is_empty() or keys.is_empty():
		return
	var key_color: Color = keys[0]
	key_dist.resize(pixel_count)
	var to_unit := 1.0 / 255.0
	var key_r := key_color.r
	var key_g := key_color.g
	var key_b := key_color.b
	for i in pixel_count:
		var offset := i * 4
		var dr := absf(data[offset] * to_unit - key_r)
		var dg := absf(data[offset + 1] * to_unit - key_g)
		var db := absf(data[offset + 2] * to_unit - key_b)
		key_dist[i] = maxf(dr, maxf(dg, db))


## Grows the antialiased edge band inwards from [param from], up to [param width]
## steps, and returns every pixel it claimed.
##
## The band is what turns a hard flood boundary into a matte: [method
## IWPipelineContext.compute_coverage] gives these pixels partial alpha from the
## usual coverage maths, where leaving them as subject would put a hard edge
## wherever the flood stopped.
##
## Pixels within the inherited key's tolerance are skipped, so an unpicked enclosed
## region keeps its full alpha rather than gaining a torn rim. A pixel that arrived
## transparent has no key and grows no band: its neighbours' alpha was settled by
## whatever pass made it transparent, and re-matting them against a colour nobody
## chose would chew the soft edge off anything processed twice.
##
## Breadth-first from the whole of [param from] at once, so depth is the distance
## from the nearest starting pixel rather than from whichever one happened to be
## visited first.
func grow_edge_band(from: PackedInt32Array, band_width: int) -> PackedInt32Array:
	var claimed := PackedInt32Array()
	if band_width <= 0 or from.is_empty():
		return claimed

	var queue := PackedInt32Array()
	queue.resize(pixel_count)
	var depth := PackedInt32Array()
	depth.resize(pixel_count)
	var head := 0
	var tail := 0
	for index in from:
		queue[tail] = index
		tail += 1

	while head < tail:
		var index := queue[head]
		head += 1
		var step := depth[index] + 1
		if step > band_width:
			continue
		var claimed_by := key_of[index]
		if claimed_by < 0:
			continue
		# The band inherits the key it grew from, so it is that key's tolerance
		# that decides what still counts as background here.
		var tolerance: float = key_tolerances[claimed_by]
		var x := index % width
		@warning_ignore("integer_division")
		var y := index / width
		if x > 0:
			var left := index - 1
			if mask[left] == MASK_SUBJECT and key_distance(left, claimed_by) > tolerance:
				mask[left] = MASK_EDGE
				key_of[left] = claimed_by
				depth[left] = step
				claimed.append(left)
				queue[tail] = left
				tail += 1
		if x < width - 1:
			var right := index + 1
			if mask[right] == MASK_SUBJECT and key_distance(right, claimed_by) > tolerance:
				mask[right] = MASK_EDGE
				key_of[right] = claimed_by
				depth[right] = step
				claimed.append(right)
				queue[tail] = right
				tail += 1
		if y > 0:
			var up := index - width
			if mask[up] == MASK_SUBJECT and key_distance(up, claimed_by) > tolerance:
				mask[up] = MASK_EDGE
				key_of[up] = claimed_by
				depth[up] = step
				claimed.append(up)
				queue[tail] = up
				tail += 1
		if y < height - 1:
			var down := index + width
			if mask[down] == MASK_SUBJECT and key_distance(down, claimed_by) > tolerance:
				mask[down] = MASK_EDGE
				key_of[down] = claimed_by
				depth[down] = step
				claimed.append(down)
				queue[tail] = down
				tail += 1

	return claimed


## Rebuilds [member nearest] from the current classification.
##
## Subject pixels matching any Remove Color are excluded as sources — an unpicked
## enclosed region is opaque, but keying off its colour would hand edge pixels the
## very background we are trying to remove. Island keys are deliberately not
## excluded: a colour an island keys out in one place is legitimate subject
## material elsewhere in the image.
##
## Rebuilt whole rather than patched, whenever a stage moves a pixel out of
## subject. The map is one grassfire pass, and working out which entries a change
## invalidated costs more than recomputing them.
func rebuild_nearest() -> void:
	if mask.is_empty():
		nearest = PackedInt32Array()
		return
	# Sized for the worst case and trimmed: on a normal image most pixels are
	# subject, so appending would reallocate its way up the whole buffer.
	var seeds := PackedInt32Array()
	seeds.resize(pixel_count)
	var count := 0
	for i in pixel_count:
		if mask[i] == MASK_SUBJECT and claiming_key(i) == KEY_NONE:
			seeds[count] = i
			count += 1
	seeds.resize(count)
	nearest = IWPixelMath.grassfire(seeds, width, height, search_radius)


## Alpha for every pixel of [param indices], from the classification and the
## nearest-subject map. Writes straight into [member coverage].
##
## The coverage estimate itself: a pixel's distance from the key that claimed it,
## over the nearest opaque subject pixel's distance from that same key. Under
## [code]C = a * F + (1 - a) * K[/code] the unknown subject colour cancels and what
## is left is the coverage.
##
## Takes a list rather than running the whole image, so a stage that only opened up
## a crevice pays for the crevice. Pass [method all_indices] for everything.
func compute_coverage(indices: PackedInt32Array) -> void:
	if coverage.size() != pixel_count:
		coverage.resize(pixel_count)
	if mask.is_empty():
		return
	var out := coverage
	var has_nearest := not nearest.is_empty()

	for i in indices:
		if mask[i] == MASK_BACKGROUND:
			out[i] = 0.0
			continue
		if mask[i] != MASK_EDGE:
			out[i] = 1.0
			continue

		var k := key_of[i]
		# An edge pixel with no key has nothing to be matted against — a drawn cut
		# or a pixel that arrived transparent. Left solid; whatever declared it
		# will settle its alpha.
		if k < 0:
			out[i] = 1.0
			continue
		var pixel_key: Color = keys[k]
		# Measure this pixel against the nearest opaque subject pixel, both
		# through the key that claimed this region. For a genuine antialiased
		# edge that ratio *is* the pixel's coverage.
		var d := key_distance(i, k)
		var neighbour := nearest[i] if has_nearest else -1
		var reference := 0.0
		if neighbour >= 0:
			reference = key_distance(neighbour, k)
		else:
			# Nothing opaque within reach: the band has swallowed a thin feature
			# whole. Fall back to the strongest pixel nearby, which for a stroke
			# is its own core, so it keeps its shape instead of being fattened to
			# fully opaque.
			reference = local_maximum(i, edge_width, pixel_key)

		# Its own key's tolerance, so a loosely keyed region does not drag the
		# coverage of a tightly keyed one around with it.
		var tolerance: float = key_tolerances[k]
		var value := 0.0
		if d > tolerance:
			value = (d - tolerance) / maxf(reference - tolerance, EPSILON)
		out[i] = clampf(value, 0.0, 1.0)

	coverage = out


## Every pixel index, for a stage that has invalidated the whole image.
func all_indices() -> PackedInt32Array:
	var all := PackedInt32Array()
	all.resize(pixel_count)
	for i in pixel_count:
		all[i] = i
	return all


## Every pixel within [param radius] of one of [param seeds], seeds included.
##
## What a stage that changed a patch of the classification has to recompute
## coverage over: a pixel outside the patch can only have the wrong answer if its
## nearest subject moved, and that reaches exactly this far.
func dilate(seeds: PackedInt32Array, radius: int) -> PackedInt32Array:
	if seeds.is_empty():
		return seeds
	var reached := IWPixelMath.grassfire(seeds, width, height, maxi(radius, 0))
	var out := PackedInt32Array()
	out.resize(pixel_count)
	var count := 0
	for i in pixel_count:
		if reached[i] >= 0:
			out[count] = i
			count += 1
	out.resize(count)
	return out


## Folds the drawn and picked regions into the classification.
##
## Called by whichever stage has just built or changed [member mask], so that
## everything downstream treats these pixels correctly without being told about
## regions at all: coverage reads them off the mask, the nearest-subject map picks
## its bleed sources from it, and the final write follows.
##
## [constant KEY_CLEAR] on a cut, because the band pass skips a pixel with no key:
## a drawn cut is a hard edge and must not be matted.
##
## Cuts first and protection second, so that where the two meet the protection is
## what survives — Add wins every overlap whatever order the rows are in.
func apply_regions_to_mask() -> void:
	if mask.is_empty():
		return
	var has_blacked := not blacked.is_empty()
	var has_protect := not protect.is_empty()
	if not has_blacked and not has_protect:
		return

	if has_blacked:
		for i in pixel_count:
			if blacked[i] == REGION_CUT:
				mask[i] = MASK_BACKGROUND
				key_of[i] = KEY_CLEAR
	for i in pixel_count:
		if (has_protect and protect[i] != 0) or (has_blacked and blacked[i] == REGION_KEEP):
			mask[i] = MASK_SUBJECT
			key_of[i] = KEY_NONE


## Folds the drawn and picked regions into the alpha.
##
## Applied after everything that can move alpha, since a region is an instruction
## about the result rather than a suggestion to the keyer. Refinement smooths
## across a hard region edge and the alpha clip drags values around; both would
## leave a drawn shape not quite doing what it says.
##
## An Add sets [member force_opaque] rather than a coverage of 1.0, because the two
## differ where the source was already transparent: coverage is multiplied by the
## source's own alpha, and a region drawn over a hole is meant to fill it.
##
## Idempotent, so a stage may call it without knowing whether another already has.
func apply_regions_to_coverage() -> void:
	var has_blacked := not blacked.is_empty()
	var has_protect := not protect.is_empty()
	if not has_blacked and not has_protect:
		return
	ensure_coverage()

	var out := coverage
	var force := force_opaque
	if force.size() != pixel_count:
		force.resize(pixel_count)
	for i in pixel_count:
		if has_blacked:
			if blacked[i] == REGION_CUT:
				out[i] = 0.0
			elif blacked[i] == REGION_KEEP:
				out[i] = 1.0
				force[i] = 1
		if has_protect and protect[i] != 0:
			out[i] = 1.0
			force[i] = 1
	coverage = out
	force_opaque = force
