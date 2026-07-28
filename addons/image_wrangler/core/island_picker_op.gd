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
## An island answers both. It floods outwards from every pixel the user picked,
## through anything within that pixel's own tolerance of the colour it landed on, and
## then either removes what it reached or forces it opaque. Subtract and Add are the
## same gesture pointed the other way, bounded by the same edges.
##
## [b]An island is a region picked, not a pixel picked.[/b] The user drags a rectangle
## and every pixel in it seeds a flood, which is what gets a patchy region out in one
## gesture — a speckled highlight is a dozen colours, and one seed only ever finds the
## one it landed on. The floods do not multiply the work: a pixel one seed claimed is
## never offered to the next, so the seeds inside a region a flood already took cost a
## test each. See [IslandEntry] for why they are grouped rather than listed flat.
##
## [b]Each pick brings its own tolerance.[/b] An island is pointed at one region
## of one image, and how clean that region is says nothing about the one beside it.
## Borrowing a number from a Remove Colors list would be worse still, since those
## entries describe colours an island by definition is not — or the flood would
## have reached it already.
##
## [b]Its keys are sampled, not stored.[/b] Each colour is read off the pixel its pick
## sits on at the moment it runs, so an island always removes exactly what was
## picked even if the stages above it changed what is there.
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
			"tooltip": "Regions picked off the preview: drag a rectangle, or click for a single pixel.\n\nSubtract removes the region, which is how an enclosed background — an eye, a\ngap in lettering, a highlight — comes out, since no Remove Color ever reaches\nit. Add forces the region opaque, which is how a region a loose tolerance ate\ncomes back.\n\nEvery pixel you picked keys out its own color at its own tolerance, so an\nisland need not match anything in Remove Background.",
		},
	]


## Pulls every pick's tolerance into range, on top of what the schema clamps.
##
## The schema cannot reach these: it names properties on the settings Resource, and a
## tolerance lives two levels down, on a pick inside an entry.
func clamp_settings_to_schema(target: Resource = null) -> void:
	super(target)
	if target == null:
		target = get_settings()
	var typed := target as IslandPickerSettings
	if typed == null or typed.islands == null:
		return
	for island in typed.islands.entries:
		if island == null:
			continue
		for pick in island.picks:
			if pick != null:
				pick.color_tolerance = clampf(pick.color_tolerance, 0.0, RemoveColorEntry.MAX_TOLERANCE)


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
##
## Only the seed gathering happens here. The picks live on Resources — an entry, its
## mode and switch, then a list of picks with a point and a tolerance each — and reading
## one is a property lookup the flood cannot afford per pixel, so they are flattened
## into packed arrays first. That was already true when the flood was GDScript; the only
## thing that changed is where the flood is.
func _subtract(ctx: IWPipelineContext) -> PackedInt32Array:
	var width := ctx.width
	var height := ctx.height

	# Flattened out of the groups they are managed in, because the flood does not care
	# which rectangle a seed was drawn in: what matters is that a pixel one seed claimed
	# is never offered to the next, and that holds across entries exactly as it holds
	# within one. The same shape [method _protect] uses, for the same reason.
	var seeds := PackedInt32Array()
	var seed_tolerances := PackedFloat32Array()
	for entry in settings.islands.entries:
		if entry == null or not entry.enabled or entry.mode != IWAlphaMode.Mode.SUBTRACT:
			continue
		for pick in entry.picks:
			if pick == null:
				continue
			var point := pick.point
			# Picks made on a different image, or on this one before it was cropped.
			if point.x < 0 or point.y < 0 or point.x >= width or point.y >= height:
				continue
			seeds.append(point.y * width + point.x)
			seed_tolerances.append(pick.color_tolerance)

	return IWStageKernels.flood_islands(ctx, seeds, seed_tolerances)


## Floods every Add island and marks what it protects.
##
## Its own flood rather than a mode inside the classification, because the two
## cannot share a queue. A background flood claims pixels once and never revisits
## them; this one has to be free to reach pixels that flood already took, since
## those are precisely the ones worth protecting.
func _protect(ctx: IWPipelineContext) -> PackedInt32Array:
	var width := ctx.width
	var height := ctx.height

	# Float64 here where the Subtract side collects float32, because that is what each
	# side always did and the difference reaches the last bit of every tolerance
	# comparison in the flood below.
	var seeds := PackedInt32Array()
	var seed_tolerances := PackedFloat64Array()
	for entry in settings.islands.entries:
		if entry == null or not entry.enabled or entry.mode != IWAlphaMode.Mode.ADD:
			continue
		for pick in entry.picks:
			if pick == null:
				continue
			var point := pick.point
			if point.x < 0 or point.y < 0 or point.x >= width or point.y >= height:
				continue
			seeds.append(point.y * width + point.x)
			seed_tolerances.append(pick.color_tolerance)

	return IWStageKernels.flood_protect(ctx, seeds, seed_tolerances)
