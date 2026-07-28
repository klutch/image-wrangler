@tool
class_name IslandPickerOp
extends IWStackOperation

## Removes or protects one region at a time, picked off the preview.
##
## Everything a keying stage does works by colour, which cannot say "this patch,
## and only this patch". A region enclosed by the subject is not reached by listing
## its colour, no matter how exactly it is listed — the flood never gets to it. And
## a region a loose tolerance ate cannot be argued back by tightening the
## tolerance, because that would give the rest of the image back too.
##
## An island answers both. It floods outwards from the pixel the user clicked,
## through anything within its own tolerance of the colour it landed on, and then
## either removes that region or forces it opaque. Subtract and Add are the same
## gesture pointed the other way, bounded by the same edges.
##
## [b]Each island brings its own tolerance.[/b] An island is pointed at one region
## of one image, and how clean that region is says nothing about the one beside it.
## Borrowing a number from a Remove Colors list would be worse still, since those
## entries describe colours an island by definition is not — or the flood would
## have reached it already.
##
## [b]Its key is sampled, not stored.[/b] The colour is read off the pixel the
## island sits on at the moment it runs, so it always removes exactly what was
## clicked even if the stages above it changed what is there.
##
## [b]A Subtract island reaches as far as the border flood would.[/b] It spreads
## through anything the Remove Colors above it claim, not only through its own
## colour, so an island dropped on a white plate still crosses onto the green stem
## beside it. See [method IWPipelineContext.flood_key_for].

var settings: IslandPickerSettings


func _init() -> void:
	settings = IslandPickerSettings.new()


func get_operation_name() -> String:
	return "Island Picker"


func get_operation_id() -> StringName:
	return &"island_picker"


func get_settings() -> Resource:
	return settings


func set_settings(new_settings: Resource) -> void:
	var typed := new_settings as IslandPickerSettings
	if typed == null:
		push_error("Image Wrangler: IslandPickerOp was handed settings of the wrong type.")
		return
	settings = typed


func make_settings() -> Resource:
	return IslandPickerSettings.new()


func get_settings_schema() -> Array[Dictionary]:
	return [
		{
			"property": &"islands",
			"type": SettingType.ISLAND_PICKER,
			"tooltip": "Regions picked off the preview, one click each.\n\nSubtract removes the region, which is how an enclosed background — an eye, a\ngap in lettering, a highlight — comes out, since no Remove Color ever reaches\nit. Add forces the region opaque, which is how a region a loose tolerance ate\ncomes back.\n\nEach one keys out the color of the pixel you clicked at its own tolerance, so\nan island need not match anything in Remove Background.",
		},
	]


## Pulls every island tolerance into range, on top of what the schema clamps.
##
## The schema cannot reach these: it names properties on the settings Resource, and a
## tolerance lives one level down, on an entry.
func clamp_settings_to_schema(target: Resource = null) -> void:
	super(target)
	if target == null:
		target = get_settings()
	var typed := target as IslandPickerSettings
	if typed == null or typed.islands == null:
		return
	for island in typed.islands.entries:
		if island != null:
			island.color_tolerance = clampf(island.color_tolerance, 0.0, RemoveColorEntry.MAX_TOLERANCE)


func stage_weight() -> float:
	return 0.25


## An Add island needs nothing above it — it is its own flood and forces alpha
## directly. A Subtract one needs a classification to add background to, so the
## answer is about the islands picked rather than about the operation.
func needs_keying() -> bool:
	return settings.islands != null and _has(IWAlphaMode.Mode.SUBTRACT)


func prerequisite_note(ctx: IWPipelineContext) -> String:
	if settings.islands == null:
		return ""
	if not _has(IWAlphaMode.Mode.SUBTRACT):
		return ""
	if ctx != null and ctx.has_classification():
		return ""
	return "Subtract islands need a Remove Background above them."


func process_context(ctx: IWPipelineContext) -> void:
	if settings.islands == null:
		return

	var touched := PackedInt32Array()
	if ctx.has_classification():
		touched = _subtract(ctx)
	if not report_progress(0.5):
		return

	var protect_touched := _protect(ctx)
	touched.append_array(protect_touched)
	if touched.is_empty():
		report_progress(1.0)
		return
	if not report_progress(0.7):
		return

	# Both halves moved pixels out of subject, so the map naming the nearest one is
	# stale and the coverage that reads it with it.
	if ctx.has_classification():
		ctx.apply_regions_to_mask()
		ctx.rebuild_nearest()
		ctx.compute_coverage(ctx.dilate(touched, ctx.search_radius))
	report_progress(1.0)


func _has(mode: int) -> bool:
	for entry in settings.islands.entries:
		if entry != null and entry.enabled and entry.mode == mode:
			return true
	return false


## Floods every Subtract island into the background and mattes what it opened.
func _subtract(ctx: IWPipelineContext) -> PackedInt32Array:
	var width := ctx.width
	var height := ctx.height
	var pixel_count := ctx.pixel_count
	var touched := PackedInt32Array()

	var mask := ctx.mask
	var key_of := ctx.key_of
	var queue := PackedInt32Array()
	queue.resize(pixel_count)
	# The same double threshold the border flood obeys; see
	# [method IWPipelineContext.flood_key_for].
	var weak_steps := PackedInt32Array()
	weak_steps.resize(pixel_count)

	for entry in settings.islands.entries:
		if entry == null or not entry.enabled or entry.mode != IWAlphaMode.Mode.SUBTRACT:
			continue
		var point := entry.point
		if point.x < 0 or point.y < 0 or point.x >= width or point.y >= height:
			continue
		var seed := point.y * width + point.x
		# Already swallowed by something above, so it adds nothing. Its key is not
		# registered either — an unused key would still be offered to every pixel by
		# claiming_key if it were not flagged as an island, and flagging a key
		# nothing seeded is just clutter.
		if mask[seed] == IWPipelineContext.MASK_BACKGROUND:
			continue

		# Sampled now rather than stored, so it removes exactly what was clicked.
		var key := ctx.add_key(ctx.color_at(seed), entry.color_tolerance, true)
		var head := 0
		var tail := 0
		weak_steps.fill(0)
		mask[seed] = IWPipelineContext.MASK_BACKGROUND
		key_of[seed] = key
		touched.append(seed)
		queue[tail] = seed
		tail += 1

		# 4-connected on purpose: 8-connectivity leaks through diagonal hairlines in
		# thin subjects such as lettering or wire-frame art. Written out four times
		# for the reason given in [method RemoveBackground._classify].
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
				if mask[left] != IWPipelineContext.MASK_BACKGROUND:
					var took := ctx.flood_key_for(left, claimed_by, weak_here)
					if took != IWPipelineContext.KEY_NONE:
						mask[left] = IWPipelineContext.MASK_BACKGROUND
						key_of[left] = took
						weak_steps[left] = ctx.flood_weak
						touched.append(left)
						queue[tail] = left
						tail += 1
			if x < width - 1:
				var right := index + 1
				if mask[right] != IWPipelineContext.MASK_BACKGROUND:
					var took := ctx.flood_key_for(right, claimed_by, weak_here)
					if took != IWPipelineContext.KEY_NONE:
						mask[right] = IWPipelineContext.MASK_BACKGROUND
						key_of[right] = took
						weak_steps[right] = ctx.flood_weak
						touched.append(right)
						queue[tail] = right
						tail += 1
			if y > 0:
				var up := index - width
				if mask[up] != IWPipelineContext.MASK_BACKGROUND:
					var took := ctx.flood_key_for(up, claimed_by, weak_here)
					if took != IWPipelineContext.KEY_NONE:
						mask[up] = IWPipelineContext.MASK_BACKGROUND
						key_of[up] = took
						weak_steps[up] = ctx.flood_weak
						touched.append(up)
						queue[tail] = up
						tail += 1
			if y < height - 1:
				var down := index + width
				if mask[down] != IWPipelineContext.MASK_BACKGROUND:
					var took := ctx.flood_key_for(down, claimed_by, weak_here)
					if took != IWPipelineContext.KEY_NONE:
						mask[down] = IWPipelineContext.MASK_BACKGROUND
						key_of[down] = took
						weak_steps[down] = ctx.flood_weak
						touched.append(down)
						queue[tail] = down
						tail += 1

	ctx.mask = mask
	ctx.key_of = key_of
	if touched.is_empty():
		return touched
	# What the flood only squeezed through is edge, not background, exactly as in the
	# border flood.
	if ctx.crevice_reach > 0:
		for i in touched:
			if mask[i] == IWPipelineContext.MASK_BACKGROUND and weak_steps[i] > 0:
				mask[i] = IWPipelineContext.MASK_EDGE
		ctx.mask = mask
	# The band has to grow from what this opened, or an island region would have a
	# hard rim where every other edge in the image has a matte.
	touched.append_array(ctx.grow_edge_band(touched, ctx.edge_width))
	return touched


## Floods every Add island and marks what it protects.
##
## Its own flood rather than a mode inside the classification, because the two
## cannot share a queue. A background flood claims pixels once and never revisits
## them; this one has to be free to reach pixels that flood already took, since
## those are precisely the ones worth protecting.
func _protect(ctx: IWPipelineContext) -> PackedInt32Array:
	var width := ctx.width
	var height := ctx.height
	var pixel_count := ctx.pixel_count

	var seeds := PackedInt32Array()
	var seed_keys: Array[Color] = []
	var seed_tolerances: Array[float] = []
	for entry in settings.islands.entries:
		if entry == null or not entry.enabled or entry.mode != IWAlphaMode.Mode.ADD:
			continue
		var point := entry.point
		if point.x < 0 or point.y < 0 or point.x >= width or point.y >= height:
			continue
		var index := point.y * width + point.x
		seeds.append(index)
		seed_keys.append(ctx.color_at(index))
		seed_tolerances.append(entry.color_tolerance)
	if seeds.is_empty():
		return PackedInt32Array()

	var protect := ctx.protect
	if protect.size() != pixel_count:
		protect.resize(pixel_count)
	var touched := PackedInt32Array()
	var queue := PackedInt32Array()
	queue.resize(pixel_count)

	for s in seeds.size():
		var key: Color = seed_keys[s]
		var tolerance: float = seed_tolerances[s]
		var head := 0
		var tail := 0
		if protect[seeds[s]] == 0:
			protect[seeds[s]] = 1
			touched.append(seeds[s])
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
				if protect[left] == 0 and ctx.distance_at(left, key) <= tolerance:
					protect[left] = 1
					touched.append(left)
					queue[tail] = left
					tail += 1
			if x < width - 1:
				var right := index + 1
				if protect[right] == 0 and ctx.distance_at(right, key) <= tolerance:
					protect[right] = 1
					touched.append(right)
					queue[tail] = right
					tail += 1
			if y > 0:
				var up := index - width
				if protect[up] == 0 and ctx.distance_at(up, key) <= tolerance:
					protect[up] = 1
					touched.append(up)
					queue[tail] = up
					tail += 1
			if y < height - 1:
				var down := index + width
				if protect[down] == 0 and ctx.distance_at(down, key) <= tolerance:
					protect[down] = 1
					touched.append(down)
					queue[tail] = down
					tail += 1

	ctx.protect = protect
	return touched
