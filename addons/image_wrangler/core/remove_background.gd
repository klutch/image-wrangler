@tool
class_name RemoveBackground
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
## [b]More than one background colour.[/b] Backgrounds come from two places, and
## which one to reach for is decided by [i]where[/i] the colour is, not by what it
## is. Every entry in [member RemoveBackgroundSettings.remove_colors] is offered to
## the image border, so a frame with different backgrounds down opposite edges
## floods from both — but only where they meet the border, since that is the only
## place the flood may start while [member RemoveBackgroundSettings.contiguous] is
## set. A region enclosed by the subject is not reached by listing its colour, no
## matter how exactly it is listed; that is what [member
## RemoveBackgroundSettings.islands] is for, and each picked island floods with the
## colour of the pixel it sits on so it keys out against itself.
##
## Each carries its own tolerance rather than sharing a global one, because the
## number that swallows a speckled JPEG background would eat into the subject
## beside a clean flat one. Every pixel therefore remembers which key claimed it,
## and its distance, its coverage and its decontamination are all measured against
## that key and that key's tolerance.
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
##
## [b]What colour cannot describe.[/b] Everything above removes background by
## colour, which leaves no way to say "this region goes, whatever is in it" — a
## watermark, a scan edge, a stray element in a corner. [member
## RemoveBackgroundSettings.polygons] is the geometric escape hatch: regions
## drawn over the preview whose interiors are forced transparent. They are folded
## into the classification as background before any alpha is computed, so the rest
## of the pipeline needs no knowledge of them, and they grow no edge band, since a
## polygon edge never blended with anything.
##
## [b]Running it twice.[/b] A source pixel that arrives fully transparent is
## treated as open ground: it is already removed, so every flood crosses it, it
## grows no edge band, and it stays transparent whether or not the flood reached
## it. Without that, a second pass over this operation's own output would be
## fenced in by the first — the bleed above leaves subject colour in the RGB of
## every transparent pixel, so the border of a processed image reads as plant
## green or skin tone rather than as background, and the flood dies at the frame.
## Crossing a hole also re-offers the far side to the whole Remove Colors list,
## since transparency carries no key to inherit.

## This operation's tunables. Swapped by the dock for the image on screen; see
## [RemoveBackgroundSettings].
var settings: RemoveBackgroundSettings

## Settings the flood fill reads from inside its per-pixel loop, snapshotted once
## per run by [method _snapshot_settings].
##
## [method _flood_take] is called four times per background pixel and cannot see
## the locals its caller hoisted, so these would otherwise be resolved through the
## settings Resource millions of times. Every other method reads what it needs
## into a local at the top instead.
var _crevice_reach: int
var _crevice_tolerance: float

## Weak-step count [method _flood_take] wants recorded for the pixel it just
## accepted. An out-parameter, because returning it alongside the key would mean
## allocating an Array four times per background pixel.
var _flood_weak := 0

## Every background colour in play this run, and the tolerance belonging to each.
## Built by [method _build_keys]: the Remove Colors list first, in the order the
## user put it in, then one entry per picked island.
##
## Parallel arrays rather than the [RemoveColorEntry] objects themselves, because
## the per-pixel loops index these millions of times and a property lookup on a
## Resource is not free.
var _keys: Array[Color] = []
var _key_tolerances: Array[float] = []

## How many of [member _keys] came from the Remove Colors list. The rest are
## islands, which seed one region each rather than being matched image-wide.
var _color_count := 0

## Pixel classes produced by [method _classify].
const MASK_BACKGROUND := 0
const MASK_EDGE := 1
const MASK_SUBJECT := 2

## Values of [code]key_of[/code] that are not indices into [member _keys].
##
## [constant KEY_CLEAR] marks a pixel that arrived fully transparent. It is
## background, but it was not keyed out by anything and has no colour to un-blend
## against, so it must not be confused with a pixel some entry claimed.
const KEY_NONE := -1
const KEY_CLEAR := -2

## Values in the mask [method _polygon_mask] builds.
const REGION_NONE := 0
const REGION_CUT := 1
const REGION_KEEP := 2

## Guards divisions where the denominator can legitimately collapse to zero.
const _EPSILON := 0.0001

## Below this coverage the un-blend divides by such a small number that it
## amplifies source noise into confetti, so its result is faded into the nearest
## known subject colour instead.
const _DECONTAMINATE_FADE := 0.25

## Minimum reach for the nearest-subject map. Coverage estimation needs a couple
## of pixels of reach even when colour bleed is switched off.
const _MIN_SEARCH_RADIUS := 2


## Regularisation for [method _guided_refine]. Small enough that the filter
## follows any real silhouette rather than averaging across it, large enough that
## a flat region does not divide by near-zero variance.
##
## Measured rather than guessed: swept from 1e-3 to 1e-7 against known coverage,
## this is where the edge error bottoms out and the bleed into solid interiors
## disappears. Looser lets a low-contrast subject wash out — a near-white one
## lost 8% of its interior alpha at 1e-3 — and tighter changes nothing.
const _REFINE_EPSILON := 0.000001


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


## Copies the settings the flood fill needs into plain fields for the run.
func _snapshot_settings() -> void:
	_crevice_reach = settings.crevice_reach
	_crevice_tolerance = settings.crevice_tolerance


## Fills [member _keys] and [member _key_tolerances] for this run, and returns the
## pixel index of every island seed.
##
## Islands are resolved here, before the flood rather than during it, so that
## [member _keys] is complete by the time [method _distance_map] picks which key
## to precompute against. An island's key is the colour of the pixel it landed on,
## sampled now rather than stored, so it always removes exactly what was clicked.
##
## Islands have no row of their own to carry a tolerance on, so they take
## [constant RemoveColorEntry.DEFAULT_TOLERANCE]. Borrowing one from the Remove
## Colors list would be worse than a constant: the entries there describe colours
## an island by definition is not, or the flood would have reached it already.
##
## The returned order matters — island [code]i[/code] owns key
## [code]_color_count + i[/code], which is what saves carrying a second array.
##
## Only Subtract islands are here. An Add island floods too, but to protect
## rather than to remove, so it has nothing to contribute to a background key and
## is handled on its own afterwards by [method _protect_mask].
func _build_keys(data: PackedByteArray, width: int, height: int) -> PackedInt32Array:
	_keys = []
	_key_tolerances = []
	for entry in settings.remove_colors.entries:
		if entry == null or not entry.enabled:
			continue
		_keys.append(entry.color)
		_key_tolerances.append(entry.color_tolerance)
	_color_count = _keys.size()

	var seeds := PackedInt32Array()
	# Without contiguity there is nothing to flood from, so islands have no
	# meaning: every pixel matching a Remove Color already qualifies.
	if not settings.contiguous:
		return seeds
	for entry in settings.islands.entries:
		if entry == null or not entry.enabled or entry.mode != IWAlphaMode.Mode.SUBTRACT:
			continue
		var point := entry.point
		if point.x < 0 or point.y < 0 or point.x >= width or point.y >= height:
			continue
		var index := point.y * width + point.x
		_keys.append(_color_at(data, index))
		_key_tolerances.append(RemoveColorEntry.DEFAULT_TOLERANCE)
		seeds.append(index)
	return seeds


func get_output_suffix() -> String:
	return "_nobg"


func get_settings_schema() -> Array[Dictionary]:
	return [
		{
			"property": &"remove_colors",
			"group": "Remove Colors",
			"type": SettingType.COLOR_LIST,
			"tooltip": "The background colors to key out, each with its own tolerance.\nPick them off the preview, or add one and set it by hand. An image with\ntwo flat backgrounds needs two entries: one tolerance loose enough for a\nspeckled one would eat into the subject beside the clean one.\n\nThe flood spreads through every listed color, so entries work together —\na white plate around a green stem needs both listed, and taking white out\nstops green working too, because nothing reaches it from the border.\n\nBackground walled off by opaque subject is never reached, whatever you\nlist. Pick that with the Island Picker instead.\n\nWhere two entries could both claim a pixel, the higher one wins.",
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
			"property": &"contiguous",
			"label": "Only Outer Background",
			"group": "Settings",
			"type": SettingType.BOOL,
			"tooltip": "Flood fill inwards from the image border, so regions enclosed by the\nsubject (eyes, highlights, gaps in lettering) stay opaque.\n\nThis is also what makes Remove Colors border-only: an entry seeds the flood\nwhere its color meets the border, and nowhere else. Turn it off and every\nlisted color is removed wherever it appears — enclosed regions included.",
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
			"property": &"refine_edges",
			"label": "Refine Edges",
			"group": "Settings",
			"type": SettingType.BOOL,
			"tooltip": "Runs the alpha through a guided filter, which snaps it to the edges the\nimage itself has. Tidies ragged alpha in crevices and around fine detail.\nCosts a few passes over the image, so it is off by default.",
		},
		{
			"property": &"refine_radius",
			"label": "Refine Radius",
			"group": "Settings",
			"type": SettingType.INT,
			"min": 1,
			"max": 16,
			"step": 1,
			"tooltip": "Window radius for that filter: roughly how far a ragged patch of alpha\nmay sit from a real edge and still be pulled onto it.\nOnly applies while Refine Edges is on.",
		},
		{
			"property": &"alpha_floor",
			"label": "Alpha Floor",
			"group": "Settings",
			"type": SettingType.FLOAT,
			"min": 0.0,
			"max": 1.0,
			"step": 0.01,
			"tooltip": "Alpha at or below this is forced fully clear.\nApplied last, so it also clears the faint ghosts Refine Edges leaves where\nit smooths leftover background instead of removing it. Around 0.5 does that;\nthe cost is that genuinely faint edge pixels go with them.",
		},
		{
			"property": &"alpha_ceiling",
			"label": "Alpha Ceiling",
			"group": "Settings",
			"type": SettingType.FLOAT,
			"min": 0.0,
			"max": 1.0,
			"step": 0.01,
			"tooltip": "Alpha at or above this is forced fully solid, with everything between the\nfloor and here stretched across the two. Bring it down towards the floor for\na harder cutoff, leave it at 1 for a soft one.",
		},
		{
			"property": &"islands",
			"group": "Island Picker",
			"collapsed": true,
			"type": SettingType.ISLAND_PICKER,
			"tooltip": "Enclosed regions to remove anyway, picked off the preview.\nEach one keys out the color of the pixel you clicked at the default\ntolerance, so an island need not match anything in Remove Colors.\nOnly applies while \"Only Outer Background\" is on.",
		},
		{
			"property": &"polygons",
			"group": "Polygon Edit",
			"collapsed": true,
			"type": SettingType.POLYGON_LIST,
			"tooltip": "Regions drawn over the preview by hand. Subtract makes the inside fully\ntransparent whatever color it is; Add makes it fully opaque.\n\nThis is the one thing here that does not work by color, so it is the way\nto edit something that has no color in common with itself — a watermark,\na scan edge, a stray element in a corner. Shapes may be concave.\n\nThe edge is hard: no antialiasing is rebuilt along it, since there is no\nbackground there to have blended with.",
		},
	]


## Pulls every Remove Color tolerance into range, on top of what the schema
## clamps.
##
## The schema cannot reach these: it names properties on the settings Resource,
## and a tolerance lives one level down, on an entry. Without this a hand-edited
## file could carry 50 while the slider clamps its display to
## [constant RemoveColorEntry.MAX_TOLERANCE] — the form and the processing
## silently disagreeing, which is the exact failure the base method exists to
## prevent.
func clamp_settings_to_schema(target: Resource = null) -> void:
	super(target)
	if target == null:
		target = get_settings()
	var typed := target as RemoveBackgroundSettings
	if typed == null or typed.remove_colors == null:
		return
	for entry in typed.remove_colors.entries:
		if entry != null:
			entry.color_tolerance = clampf(entry.color_tolerance, 0.0, RemoveColorEntry.MAX_TOLERANCE)


## Convenience entry point for code that just wants the default behaviour.
static func remove_background(source: Image, key := Color.WHITE) -> Image:
	var operation := RemoveBackground.new()
	operation.settings.remove_colors.set_only(key)
	return operation.process_image(source)


func process_image(source: Image) -> Image:
	_snapshot_settings()
	var bleed_radius := settings.bleed_radius
	var edge_width := settings.edge_width
	var refine_edges := settings.refine_edges
	var alpha_floor := settings.alpha_floor
	var alpha_ceiling := settings.alpha_ceiling

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
	var blacked := _polygon_mask(width, height)
	var island_seeds := _build_keys(data, width, height)
	# No colours and no Subtract islands is a coherent request for no keying, and
	# every map below would otherwise have to defend itself against having no key
	# to measure against. The regions still have to land, though — they are
	# geometry and owe nothing to the keying that is being skipped.
	if _keys.is_empty():
		var regions := _protect_mask(data, width, height)
		if blacked.is_empty() and regions.is_empty():
			return image
		return _regions_only(image, data, blacked, regions, pixel_count)

	# Distances against the first key. Every other one is measured on demand, but
	# this covers the border flood, which is nearly every background pixel in a
	# normal image.
	var key_dist := _distance_map(data, pixel_count)

	var classified := _classify(data, key_dist, island_seeds, width, height)
	var mask: PackedByteArray = classified[0]
	var key_of: PackedInt32Array = classified[1]

	# Folded into the mask here rather than into the alpha at the end, so that
	# everything downstream treats these pixels correctly without being told about
	# regions at all: coverage reads them off the mask, the nearest-subject map
	# picks its bleed sources from it, and compose follows.
	#
	# KEY_CLEAR on a cut, because the band pass skips a pixel with no key: a
	# drawn cut is a hard edge and must not be matted. Applied after _classify for
	# the same reason — a band already grown into the region is overwritten rather
	# than left as a soft rim inside a hard edge.
	var protect := _protect_mask(data, width, height)
	if not blacked.is_empty():
		for i in pixel_count:
			if blacked[i] == REGION_CUT:
				mask[i] = MASK_BACKGROUND
				key_of[i] = KEY_CLEAR
	# Second, and over the top of the cut above, because Add wins every overlap.
	if not protect.is_empty() or not blacked.is_empty():
		for i in pixel_count:
			if (not protect.is_empty() and protect[i] != 0) \
					or (not blacked.is_empty() and blacked[i] == REGION_KEEP):
				mask[i] = MASK_SUBJECT
				key_of[i] = KEY_NONE

	var search_radius := maxi(maxi(bleed_radius, edge_width), _MIN_SEARCH_RADIUS)
	var nearest := _nearest_subject_map(data, mask, key_dist, width, height, search_radius)

	# Alpha is settled for the whole image before any colour work, because the
	# refinement below is a neighbourhood operation and cannot run a pixel at a
	# time.
	var coverage := _coverage_map(data, key_dist, mask, key_of, nearest, width, height)
	if refine_edges:
		coverage = _guided_refine(coverage, key_dist, width, height)
	# Last, so it settles the refinement's leftovers rather than being smoothed
	# back into a haze by it.
	if alpha_floor > 0.0 or alpha_ceiling < 1.0:
		_clip_alpha(coverage)

	# After everything that can move alpha, since a region is an instruction about
	# the result rather than a suggestion to the keyer. Refinement smooths across
	# a hard region edge and the alpha clip drags values around; both would leave a
	# drawn shape not quite doing what it says.
	# Cuts first and protection second, so that where the two meet the protection
	# is what survives — the same precedence the mask above was given.
	if not blacked.is_empty():
		for i in pixel_count:
			if blacked[i] == REGION_CUT:
				coverage[i] = 0.0
			elif blacked[i] == REGION_KEEP:
				coverage[i] = 1.0
	if not protect.is_empty():
		for i in pixel_count:
			if protect[i] != 0:
				coverage[i] = 1.0

	return _compose(data, coverage, key_of, nearest, width, height)


## One byte per pixel marking what the drawn regions do there, or an empty
## array when no region is both drawn and switched on.
##
## [constant REGION_CUT] for a Subtract region, [constant REGION_KEEP] for an
## Add one. Add writes over anything, Subtract only over untouched pixels, so Add
## wins every overlap whatever order the rows are in — protection is an override
## rather than another layer of paint, which is what lets the list stay a set of
## rules with no way to reorder it.
##
## Scanline fill under the even-odd rule, not a point-in-polygon test per pixel.
## For each row, the x where every edge crosses that row's centre line is
## collected, sorted, and the spans between alternate pairs are filled. Concave
## shapes fall out of this for free — they are exactly the case where a row has
## more than two crossings — and so do self-intersecting ones, where even-odd
## gives the sensible answer of a hole. A triangle fan, which is what naive
## polygon drawing does, gets both wrong.
##
## Cost is one pass over each polygon's own bounding box rather than the image, so
## a small cut-out on a large image is cheap.
func _polygon_mask(width: int, height: int) -> PackedByteArray:
	var empty := PackedByteArray()
	if settings.polygons == null or not settings.polygons.has_active():
		return empty

	var marked := PackedByteArray()
	marked.resize(width * height)
	var filled_any := false

	for region in settings.polygons.regions:
		if region == null or not region.is_active():
			continue
		var adding := region.mode == IWAlphaMode.Mode.ADD
		var value := REGION_KEEP if adding else REGION_CUT
		var points := region.points
		var count := points.size()
		var box := region.bounds()
		var first_row := maxi(box.position.y, 0)
		var last_row := mini(box.position.y + box.size.y - 1, height - 1)

		for y in range(first_row, last_row + 1):
			# Sampled at the row's centre, so a vertex landing exactly on an
			# integer row cannot be counted as a crossing twice.
			var line := y + 0.5
			var crossings := PackedFloat32Array()
			for e in count:
				var a := points[e]
				var b := points[(e + 1) % count]
				# Half-open on purpose: a vertex is counted by the edge below it
				# and not the one above, which is what stops a shared vertex
				# registering as two crossings and inverting the rest of the row.
				if (a.y > line) == (b.y > line):
					continue
				var t := (line - a.y) / float(b.y - a.y)
				crossings.append(a.x + t * (b.x - a.x))
			if crossings.size() < 2:
				continue
			crossings.sort()

			var row := y * width
			var pair := 0
			while pair + 1 < crossings.size():
				# Pixel centres, so a span is filled where it actually covers the
				# middle of a pixel rather than merely touching its edge.
				var from_x := maxi(ceili(crossings[pair] - 0.5), 0)
				var to_x := mini(floori(crossings[pair + 1] - 0.5), width - 1)
				for x in range(from_x, to_x + 1):
					# Add overwrites whatever is there; Subtract yields to an Add
					# already written. One pass, and row order stops mattering.
					if adding or marked[row + x] != REGION_KEEP:
						marked[row + x] = value
					filled_any = true
				pair += 2

	return marked if filled_any else empty


## One byte per pixel marking what every Add island protects, or an empty array
## when there are none.
##
## An Add island floods exactly as a Subtract one does — outwards from the clicked
## pixel, through anything within [constant RemoveColorEntry.DEFAULT_TOLERANCE] of
## the colour it landed on — and then forces that region opaque instead of
## removing it. So the two are the same gesture pointed the other way: click a
## region a loose tolerance ate and it comes back, bounded by the same edges that
## would have bounded its removal.
##
## Its own flood rather than a mode inside [method _classify], because the two
## cannot share a queue. The background flood claims pixels once and never
## revisits them; this one has to be free to reach pixels that flood already took,
## since those are precisely the ones worth protecting.
func _protect_mask(data: PackedByteArray, width: int, height: int) -> PackedByteArray:
	var empty := PackedByteArray()
	if settings.islands == null or not settings.contiguous:
		return empty

	var seeds := PackedInt32Array()
	var seed_keys: Array[Color] = []
	for entry in settings.islands.entries:
		if entry == null or not entry.enabled or entry.mode != IWAlphaMode.Mode.ADD:
			continue
		var point := entry.point
		if point.x < 0 or point.y < 0 or point.x >= width or point.y >= height:
			continue
		var index := point.y * width + point.x
		seeds.append(index)
		seed_keys.append(_color_at(data, index))
	if seeds.is_empty():
		return empty

	var pixel_count := width * height
	var protect := PackedByteArray()
	protect.resize(pixel_count)
	var queue := PackedInt32Array()
	queue.resize(pixel_count)

	# Written out four times rather than through a helper, the same way the
	# background flood is: the marking has to land in this array, and handing a
	# Packed array to a function to be written through is the sort of thing that
	# depends on which side of a copy-on-write you end up on.
	var tolerance := RemoveColorEntry.DEFAULT_TOLERANCE
	for s in seeds.size():
		var key: Color = seed_keys[s]
		var head := 0
		var tail := 0
		if protect[seeds[s]] == 0:
			protect[seeds[s]] = 1
			queue[tail] = seeds[s]
			tail += 1
		# 4-connected, matching the background flood, so a diagonal hairline is no
		# more of a bridge here than it is there.
		while head < tail:
			var index := queue[head]
			head += 1
			var x := index % width
			@warning_ignore("integer_division")
			var y := index / width
			if x > 0:
				var left := index - 1
				if protect[left] == 0 and _distance_at(data, left, key) <= tolerance:
					protect[left] = 1
					queue[tail] = left
					tail += 1
			if x < width - 1:
				var right := index + 1
				if protect[right] == 0 and _distance_at(data, right, key) <= tolerance:
					protect[right] = 1
					queue[tail] = right
					tail += 1
			if y > 0:
				var up := index - width
				if protect[up] == 0 and _distance_at(data, up, key) <= tolerance:
					protect[up] = 1
					queue[tail] = up
					tail += 1
			if y < height - 1:
				var down := index + width
				if protect[down] == 0 and _distance_at(data, down, key) <= tolerance:
					protect[down] = 1
					queue[tail] = down
					tail += 1

	return protect


## Applies the drawn and picked regions to [param image] and nothing else.
##
## Reached when there is no colour and no Subtract island to key from, which
## leaves the whole classification pipeline with no key to measure against. The
## regions owe that pipeline nothing, so they are written straight to alpha.
##
## Protection is applied after the cuts, so an Add still wins where the two meet.
func _regions_only(image: Image, data: PackedByteArray, blacked: PackedByteArray, protect: PackedByteArray, pixel_count: int) -> Image:
	var out := data.duplicate()
	for i in pixel_count:
		var offset := i * 4 + 3
		if not blacked.is_empty():
			if blacked[i] == REGION_CUT:
				out[offset] = 0
			elif blacked[i] == REGION_KEEP:
				out[offset] = 255
		if not protect.is_empty() and protect[i] != 0:
			out[offset] = 255
	return Image.create_from_data(
			image.get_width(), image.get_height(), false, Image.FORMAT_RGBA8, out)


## Stretches alpha so [member alpha_floor] and below lands on clear and
## [member alpha_ceiling] and above on solid. Edits [param coverage] in place.
func _clip_alpha(coverage: PackedFloat32Array) -> void:
	var alpha_ceiling := settings.alpha_ceiling

	var low := settings.alpha_floor
	# Letting the ceiling sit at or under the floor is a legitimate request for a
	# hard cutoff at that value, so it is honoured rather than rejected — just
	# not by dividing by zero.
	var span := maxf(alpha_ceiling - low, _EPSILON)
	for i in coverage.size():
		coverage[i] = clampf((coverage[i] - low) / span, 0.0, 1.0)


## Alpha for every pixel, before any refinement.
func _coverage_map(data: PackedByteArray, key_dist: PackedFloat32Array, mask: PackedByteArray, key_of: PackedInt32Array, nearest: PackedInt32Array, width: int, height: int) -> PackedFloat32Array:
	var edge_width := settings.edge_width

	var pixel_count := width * height
	var coverage := PackedFloat32Array()
	coverage.resize(pixel_count)

	for i in pixel_count:
		if mask[i] == MASK_BACKGROUND:
			coverage[i] = 0.0
			continue
		if mask[i] != MASK_EDGE:
			coverage[i] = 1.0
			continue

		var k := key_of[i]
		var pixel_key: Color = _keys[k]
		# Measure this pixel against the nearest opaque subject pixel, both
		# through the key that claimed this region. For a genuine antialiased
		# edge that ratio *is* the pixel's coverage.
		var d := _key_distance(data, key_dist, i, k)
		var neighbour := nearest[i]
		var reference := 0.0
		if neighbour >= 0:
			reference = _key_distance(data, key_dist, neighbour, k)
		else:
			# Nothing opaque within reach: the band has swallowed a thin feature
			# whole. Fall back to the strongest pixel nearby, which for a stroke
			# is its own core, so it keeps its shape instead of being fattened to
			# fully opaque.
			reference = _local_maximum(data, width, height, i, edge_width, pixel_key)

		# Its own key's tolerance, so a loosely keyed region does not drag the
		# coverage of a tightly keyed one around with it.
		var tolerance: float = _key_tolerances[k]
		var value := 0.0
		if d > tolerance:
			value = (d - tolerance) / maxf(reference - tolerance, _EPSILON)
		value = clampf(value, 0.0, 1.0)
		coverage[i] = value

	return coverage


## Writes the final image: alpha from [param coverage], colour un-blended and
## bled outwards as needed.
func _compose(data: PackedByteArray, coverage: PackedFloat32Array, key_of: PackedInt32Array, nearest: PackedInt32Array, width: int, height: int) -> Image:
	var bleed_radius := settings.bleed_radius
	var decontaminate := settings.decontaminate
	# Stand-in for a pixel no flood ever claimed. Only reachable once refinement
	# or the alpha clip has pulled a subject pixel below full coverage, since
	# nothing else leaves an unclaimed pixel needing to be un-blended.
	var fallback_key: Color = _keys[0]

	var pixel_count := width * height
	var out := PackedByteArray()
	out.resize(pixel_count * 4)
	var to_unit := 1.0 / 255.0

	for i in pixel_count:
		var offset := i * 4
		var r := data[offset] * to_unit
		var g := data[offset + 1] * to_unit
		var b := data[offset + 2] * to_unit
		var source_alpha := data[offset + 3] * to_unit
		var neighbour := nearest[i]
		var alpha := coverage[i]
		# Whichever background claimed this pixel is the one to un-blend.
		var k := key_of[i]
		var pixel_key: Color = _keys[k] if k >= 0 else fallback_key

		if alpha <= 0.0:
			alpha = 0.0
			if bleed_radius > 0 and neighbour >= 0:
				var bleed_offset := neighbour * 4
				r = data[bleed_offset] * to_unit
				g = data[bleed_offset + 1] * to_unit
				b = data[bleed_offset + 2] * to_unit
		elif alpha < 1.0 and decontaminate:
			var inverse := 1.0 / alpha
			var rest := 1.0 - alpha
			var pure_r := clampf((r - rest * pixel_key.r) * inverse, 0.0, 1.0)
			var pure_g := clampf((g - rest * pixel_key.g) * inverse, 0.0, 1.0)
			var pure_b := clampf((b - rest * pixel_key.b) * inverse, 0.0, 1.0)
			if alpha < _DECONTAMINATE_FADE and neighbour >= 0:
				var weight := alpha / _DECONTAMINATE_FADE
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
		out[offset + 3] = roundi(clampf(source_alpha * alpha, 0.0, 1.0) * 255.0)

	return Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, out)


## Edge-aware smoothing of the alpha, after He, Sun and Tang's guided filter
## (ECCV 2010) — the "guided feathering" application from that paper.
##
## Within each window the output is fitted as a linear function of the guide,
## [code]q = a * I + b[/code], with the coefficients chosen by least squares and
## then averaged over the windows covering each pixel. Where the guide is flat
## the fit degenerates to the local mean and the alpha is smoothed; where the
## guide has an edge the fit follows it, so the alpha snaps to that edge instead
## of blurring across it. Ragged crevices get tidied without the silhouette going
## soft.
##
## The guide is distance-from-key rather than the image's luminance. It is
## already computed, and it is the better signal here: its edges are exactly the
## background/subject boundary whatever the hue, so it separates a green screen
## from an equally bright subject, which luminance cannot.
##
## A flat region is preserved exactly, not approximately. Where the alpha is
## uniform the covariance term is zero, so [code]a = 0[/code] and
## [code]b[/code] is that value — a solid interior cannot be dragged off 1.0.
func _guided_refine(coverage: PackedFloat32Array, guide: PackedFloat32Array, width: int, height: int) -> PackedFloat32Array:
	var pixel_count := width * height
	var radius := maxi(settings.refine_radius, 1)

	var guide_squared := PackedFloat32Array()
	guide_squared.resize(pixel_count)
	var guide_times_alpha := PackedFloat32Array()
	guide_times_alpha.resize(pixel_count)
	for i in pixel_count:
		guide_squared[i] = guide[i] * guide[i]
		guide_times_alpha[i] = guide[i] * coverage[i]

	var mean_guide := _box_mean(guide, width, height, radius)
	var mean_alpha := _box_mean(coverage, width, height, radius)
	var mean_guide_squared := _box_mean(guide_squared, width, height, radius)
	var mean_guide_alpha := _box_mean(guide_times_alpha, width, height, radius)

	var slope := PackedFloat32Array()
	slope.resize(pixel_count)
	var offset := PackedFloat32Array()
	offset.resize(pixel_count)
	for i in pixel_count:
		var variance := mean_guide_squared[i] - mean_guide[i] * mean_guide[i]
		var covariance := mean_guide_alpha[i] - mean_guide[i] * mean_alpha[i]
		# The regularisation is what decides how hard an edge has to be before
		# the filter follows it rather than smoothing across it.
		var a := covariance / (variance + _REFINE_EPSILON)
		slope[i] = a
		offset[i] = mean_alpha[i] - a * mean_guide[i]

	var mean_slope := _box_mean(slope, width, height, radius)
	var mean_offset := _box_mean(offset, width, height, radius)

	var refined := PackedFloat32Array()
	refined.resize(pixel_count)
	for i in pixel_count:
		refined[i] = clampf(mean_slope[i] * guide[i] + mean_offset[i], 0.0, 1.0)
	return refined


## Mean over a (2r+1)² window, via a summed-area table so the cost is the same
## whatever the radius. The table is accumulated at double precision because a
## large image sums to a magnitude where float32 has stopped counting single
## pixels.
func _box_mean(source: PackedFloat32Array, width: int, height: int, radius: int) -> PackedFloat32Array:
	var stride := width + 1
	var integral := PackedFloat64Array()
	integral.resize(stride * (height + 1))
	for y in height:
		var row_sum := 0.0
		var row := y * width
		var out_row := (y + 1) * stride
		var prev_row := y * stride
		for x in width:
			row_sum += source[row + x]
			integral[out_row + x + 1] = integral[prev_row + x + 1] + row_sum

	var result := PackedFloat32Array()
	result.resize(width * height)
	for y in height:
		var min_y := maxi(y - radius, 0)
		var max_y := mini(y + radius, height - 1) + 1
		var top := min_y * stride
		var bottom := max_y * stride
		var rows := max_y - min_y
		for x in width:
			var min_x := maxi(x - radius, 0)
			var max_x := mini(x + radius, width - 1) + 1
			var total := integral[bottom + max_x] - integral[top + max_x] \
					- integral[bottom + min_x] + integral[top + min_x]
			result[y * width + x] = total / float(rows * (max_x - min_x))
	return result


## Largest per-channel distance from the first key, per pixel.
##
## Only the first is worth a whole map. It is the one the border flood almost
## always starts from, and the rest are measured on demand by [method
## _distance_at] — a second map per key would cost a pass over the image each to
## serve a handful of pixels.
##
## The max-channel metric is the one that makes the coverage maths work: under
## [code]C = a * F + (1 - a) * K[/code] every channel difference scales by the
## same [code]a[/code], so their maximum does too. A euclidean or luminance
## distance would not survive being divided by a neighbour's distance.
func _distance_map(data: PackedByteArray, pixel_count: int) -> PackedFloat32Array:
	var key_color := _keys[0]

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


## Whether a source pixel arrived fully transparent, and so is already removed.
##
## Exactly zero rather than a threshold. A partly transparent pixel is a real
## antialiased edge carrying real coverage, and treating it as empty would eat the
## soft edge of anything processed twice. Zero is what this operation itself
## writes for background, so a second pass recognises its own first pass.
func _is_clear(data: PackedByteArray, index: int) -> bool:
	return data[index * 4 + 3] == 0


## Distance from a pixel to key [param k], taking the precomputed map for the
## first key and measuring the rest on demand.
func _key_distance(data: PackedByteArray, key_dist: PackedFloat32Array, index: int, k: int) -> float:
	return key_dist[index] if k == 0 else _distance_at(data, index, _keys[k])


## Index of the first Remove Color claiming [param index], or -1 for none.
##
## First match rather than closest match, so the list reads as an ordered set of
## rules. Two entries close enough to both claim a pixel are describing the same
## background twice, and which of them wins matters far less than the answer being
## the one the user can see at the top of the list.
##
## Islands are deliberately not searched. Their key is the colour of one spot the
## user pointed at, which is a licence to remove that region rather than every
## pixel of that colour in the image.
## The first key is unrolled out of the loop. This is called once per pixel by
## both [method _nearest_subject_map] and the non-contiguous branch of [method
## _classify], and for the overwhelmingly common single-colour list that leaves it
## an array lookup and a compare rather than a nested call per pixel.
func _claiming_key(data: PackedByteArray, key_dist: PackedFloat32Array, index: int) -> int:
	if _color_count == 0:
		return KEY_NONE
	if key_dist[index] <= _key_tolerances[0]:
		return 0
	for k in range(1, _color_count):
		if _distance_at(data, index, _keys[k]) <= _key_tolerances[k]:
			return k
	return KEY_NONE


## The key a border pixel starts the flood with, or [constant KEY_NONE].
##
## Transparency is checked before colour, because a transparent pixel's RGB is
## not a colour anyone chose. This operation bleeds subject colour into what it
## makes transparent, so the border of an image it has already processed is full
## of plant green or skin tone — matching that against the Remove Colors list
## would be reading a value that is there to stop filtering artefacts, not to
## describe a background.
func _border_key(data: PackedByteArray, key_dist: PackedFloat32Array, index: int) -> int:
	return KEY_CLEAR if _is_clear(data, index) else _claiming_key(data, key_dist, index)


## Sorts every pixel into background, antialiased edge, or subject, and records
## which background colour claimed it.
##
## Returns [code][mask, key_of][/code]: the class per pixel, and the index into
## [member _keys] that claimed it (-1 for subject).
##
## Two passes over one queue. The first claims the background itself — pixels
## within their key's own tolerance, flood filled inwards from the image border
## (plus any [param island_seeds]) when [member contiguous] is set, which is what
## keeps unpicked enclosed regions opaque. The second walks [member edge_width]
## steps further in from that background and calls what it touches the antialiased
## band, inheriting the key it grew from.
##
## Classifying by distance-from-background rather than by colour is the whole
## trick. A pixel's colour genuinely cannot distinguish a half-covered distant
## subject from a fully covered near-key one, but position can: real antialiasing
## only ever occurs in a thin band against the background.
func _classify(data: PackedByteArray, key_dist: PackedFloat32Array, island_seeds: PackedInt32Array, width: int, height: int) -> Array:
	var edge_width := settings.edge_width
	var contiguous := settings.contiguous
	var crevice_reach := settings.crevice_reach

	var pixel_count := width * height
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
	# on anything solidly background. See [method _flood_take].
	var weak_steps := PackedInt32Array()
	weak_steps.resize(pixel_count)

	if contiguous:
		# Every border pixel is offered to the whole Remove Colors list, so a frame
		# with one background down one edge and another down the opposite edge
		# floods from both without either needing to be picked as an island.
		for x in width:
			var top := x
			if mask[top] != MASK_BACKGROUND:
				var top_key := _border_key(data, key_dist, top)
				if top_key != KEY_NONE:
					mask[top] = MASK_BACKGROUND
					key_of[top] = top_key
					queue[tail] = top
					tail += 1
			var bottom := (height - 1) * width + x
			if mask[bottom] != MASK_BACKGROUND:
				var bottom_key := _border_key(data, key_dist, bottom)
				if bottom_key != KEY_NONE:
					mask[bottom] = MASK_BACKGROUND
					key_of[bottom] = bottom_key
					queue[tail] = bottom
					tail += 1
		for y in height:
			var row_start := y * width
			if mask[row_start] != MASK_BACKGROUND:
				var start_key := _border_key(data, key_dist, row_start)
				if start_key != KEY_NONE:
					mask[row_start] = MASK_BACKGROUND
					key_of[row_start] = start_key
					queue[tail] = row_start
					tail += 1
			var row_end := row_start + width - 1
			if mask[row_end] != MASK_BACKGROUND:
				var end_key := _border_key(data, key_dist, row_end)
				if end_key != KEY_NONE:
					mask[row_end] = MASK_BACKGROUND
					key_of[row_end] = end_key
					queue[tail] = row_end
					tail += 1

		# Picked islands join the same queue as the border, each carrying the
		# colour of the pixel it landed on. An island always takes, since its key
		# is that pixel's own colour — the user pointed at what to remove. One
		# already swallowed by the border flood adds nothing, so its seed is
		# dropped; its key stays in the array unused rather than renumbering the
		# rest.
		for i in island_seeds.size():
			var island_index := island_seeds[i]
			if mask[island_index] == MASK_BACKGROUND:
				continue
			mask[island_index] = MASK_BACKGROUND
			key_of[island_index] = _color_count + i
			queue[tail] = island_index
			tail += 1

		# 4-connected on purpose: 8-connectivity leaks through diagonal
		# hairlines in thin subjects such as lettering or wire-frame art.
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
				if mask[left] != MASK_BACKGROUND:
					var took := _flood_take(data, key_dist, left, claimed_by, weak_here)
					if took != KEY_NONE:
						mask[left] = MASK_BACKGROUND
						key_of[left] = took
						weak_steps[left] = _flood_weak
						queue[tail] = left
						tail += 1
			if x < width - 1:
				var right := index + 1
				if mask[right] != MASK_BACKGROUND:
					var took := _flood_take(data, key_dist, right, claimed_by, weak_here)
					if took != KEY_NONE:
						mask[right] = MASK_BACKGROUND
						key_of[right] = took
						weak_steps[right] = _flood_weak
						queue[tail] = right
						tail += 1
			if y > 0:
				var up := index - width
				if mask[up] != MASK_BACKGROUND:
					var took := _flood_take(data, key_dist, up, claimed_by, weak_here)
					if took != KEY_NONE:
						mask[up] = MASK_BACKGROUND
						key_of[up] = took
						weak_steps[up] = _flood_weak
						queue[tail] = up
						tail += 1
			if y < height - 1:
				var down := index + width
				if mask[down] != MASK_BACKGROUND:
					var took := _flood_take(data, key_dist, down, claimed_by, weak_here)
					if took != KEY_NONE:
						mask[down] = MASK_BACKGROUND
						key_of[down] = took
						weak_steps[down] = _flood_weak
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
		# Without contiguity there is nothing to flood from, so islands have no
		# meaning: every pixel matching a Remove Color already qualifies.
		for i in pixel_count:
			var claimed := _claiming_key(data, key_dist, i)
			if claimed != KEY_NONE:
				mask[i] = MASK_BACKGROUND
				key_of[i] = claimed
				queue[tail] = i
				tail += 1

	# Transparency the flood never reached is still transparent. Marked without
	# being queued: there is nothing behind a transparent pixel to make opaque, so
	# leaving it classed as subject would have coverage fill in every enclosed hole
	# the moment an image was processed a second time — but it grows no band
	# either, since it has no colour anything could be matted against.
	for i in pixel_count:
		if mask[i] != MASK_BACKGROUND and _is_clear(data, i):
			mask[i] = MASK_BACKGROUND
			key_of[i] = KEY_CLEAR

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
		# A pixel that arrived transparent has no key and grows no band. Its
		# neighbours' alpha was settled by whatever pass made it transparent, and
		# re-matting them against a colour nobody chose would chew the soft edge
		# off anything processed twice.
		if claimed_by < 0:
			continue
		# The band inherits the key it grew from, so it is that key's tolerance
		# that decides what still counts as background here.
		var tolerance: float = _key_tolerances[claimed_by]
		var x := index % width
		@warning_ignore("integer_division")
		var y := index / width
		if x > 0:
			var left := index - 1
			if mask[left] == MASK_SUBJECT and _key_distance(data, key_dist, left, claimed_by) > tolerance:
				mask[left] = MASK_EDGE
				key_of[left] = claimed_by
				depth[left] = step
				queue[tail] = left
				tail += 1
		if x < width - 1:
			var right := index + 1
			if mask[right] == MASK_SUBJECT and _key_distance(data, key_dist, right, claimed_by) > tolerance:
				mask[right] = MASK_EDGE
				key_of[right] = claimed_by
				depth[right] = step
				queue[tail] = right
				tail += 1
		if y > 0:
			var up := index - width
			if mask[up] == MASK_SUBJECT and _key_distance(data, key_dist, up, claimed_by) > tolerance:
				mask[up] = MASK_EDGE
				key_of[up] = claimed_by
				depth[up] = step
				queue[tail] = up
				tail += 1
		if y < height - 1:
			var down := index + width
			if mask[down] == MASK_SUBJECT and _key_distance(data, key_dist, down, claimed_by) > tolerance:
				mask[down] = MASK_EDGE
				key_of[down] = claimed_by
				depth[down] = step
				queue[tail] = down
				tail += 1

	return [mask, key_of]


## The key [param to] should take for a flood arriving from [param from_key], or
## [constant KEY_NONE] to refuse it. The weak-step count to record is left in
## [member _flood_weak].
##
## Returns the key rather than letting the caller inherit one, because the key
## that arrives is not always the key that applies. The flood spreads through the
## background as a whole, not through one colour of it: a pixel the arriving key
## refuses is offered to the rest of the list, and takes whichever entry claims
## it. Reaching a colour is therefore a question of a path existing through
## listed colours, not of that colour touching the image border itself.
##
## Transparency is the other case. A transparent pixel is open ground — already
## removed, so any flood crosses it — and it carries no colour of its own to pass
## on, so the first opaque pixel on the far side is offered to the whole list
## afresh. That is what lets a background reach a region walled off by a hole,
## which is the normal shape of an image this operation has already run over once.
##
## This is Canny's double threshold applied to region growing rather than edge
## linking. A pixel within its key's own tolerance is solid background and resets
## the count; one merely within [member crevice_tolerance] may still be crossed,
## but only [member crevice_reach] of them in a row before solid background is
## needed again. That is what gets into a crevice whose neck is nothing but the
## antialiasing of the two walls meeting, while stopping the flood from wandering
## off across a pale subject, which an unbounded weak threshold would do.
##
## The flood carries its key with it, so a region seeded by a tightly toleranced
## entry stays tight even where it runs alongside one keyed loosely. Which entry
## claimed the seed is therefore the whole story for everything downstream of it.
##
## First visit wins rather than the lowest count, so a pixel reachable two ways
## may keep a worse count than it deserves. That only ever makes the flood stop
## short — it can never reach further than the rule allows — so the failure mode
## is background left behind, never subject eaten.
func _flood_take(data: PackedByteArray, key_dist: PackedFloat32Array, to: int, from_key: int, from_weak: int) -> int:
	_flood_weak = 0
	if _is_clear(data, to):
		return KEY_CLEAR
	if from_key == KEY_CLEAR:
		return _claiming_key(data, key_dist, to)

	var distance := _key_distance(data, key_dist, to, from_key)
	var tolerance: float = _key_tolerances[from_key]
	if distance <= tolerance:
		return from_key

	# The arriving key does not want it, so the rest of the list is asked before
	# giving up. Two flat backgrounds meeting — a white plate around a green stem —
	# are one region to the eye and have to be one to the flood, or the second
	# colour would only ever work where it independently touched the image border,
	# which is almost never. Whichever entry claims this pixel takes it, and the
	# flood carries on from here at that entry's tolerance rather than the one it
	# set out with.
	var claimed := _claiming_key(data, key_dist, to)
	if claimed != KEY_NONE:
		return claimed

	# Last, so a pixel another entry claims outright is never taken by the weaker
	# rule instead. Straying is for getting through a gap, not for choosing a key.
	if _crevice_reach > 0 and from_weak < _crevice_reach and distance <= maxf(_crevice_tolerance, tolerance):
		_flood_weak = from_weak + 1
		return from_key
	return KEY_NONE


## For every pixel, the index of the closest opaque subject pixel, or -1 if none
## lies within [param radius].
##
## A grassfire expansion seeded from all subject pixels at once, so the whole map
## costs one pass over the image rather than a windowed search per edge pixel. It
## feeds both the coverage estimate (as the reference distance) and the colour
## bleed (as the replacement RGB).
##
## Subject pixels matching any Remove Color are excluded as sources — an unpicked
## enclosed region is opaque, but keying off its colour would hand edge pixels the
## very background we are trying to remove. Island keys are deliberately not
## excluded here: a colour an island keys out in one place is legitimate subject
## material elsewhere in the image.
func _nearest_subject_map(data: PackedByteArray, mask: PackedByteArray, key_dist: PackedFloat32Array, width: int, height: int, radius: int) -> PackedInt32Array:
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
		if mask[i] == MASK_SUBJECT and _claiming_key(data, key_dist, i) == KEY_NONE:
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
