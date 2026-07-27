@tool
class_name PolygonEditOp
extends IWStackOperation

## Forces regions transparent or opaque by shape rather than by colour.
##
## Everything else here removes background by colour, which leaves no way to say
## "this region goes, whatever is in it" — a watermark, a scan edge, a stray
## element in a corner. This is the geometric escape hatch: shapes drawn over the
## preview whose interiors are settled outright.
##
## [b]Scanline fill under the even-odd rule[/b], not a point-in-polygon test per
## pixel. For each row, the x where every edge crosses that row's centre line is
## collected, sorted, and the spans between alternate pairs are filled. Concave
## shapes fall out of this for free — they are exactly the case where a row has
## more than two crossings — and so do self-intersecting ones, where even-odd gives
## the sensible answer of a hole. A triangle fan, which is what naive polygon
## drawing does, gets both wrong.
##
## Cost is one pass over each shape's own bounding box rather than the image, so a
## small cut-out on a large image is cheap.
##
## [b]Add wins every overlap[/b], whatever order the rows are in: protection is an
## override rather than another layer of paint, which is what lets the list stay a
## set of rules with no way to reorder it. The same holds between two of these
## stages — a later Add overrules an earlier cut, and a later cut yields to an
## earlier Add.
##
## [b]A drawn edge grows no band.[/b] A polygon edge never blended with anything,
## so it is left hard on purpose rather than matted like a keyed edge.
##
## Sits happily above or below a keying stage, and means something slightly
## different in each place. Above, it declares the regions and the keying stage
## folds them in before it estimates any alpha — so the shapes also steer where the
## bleed takes its colours from. Below, it overrules whatever alpha has been worked
## out by then.

var settings: PolygonEditSettings


func _init() -> void:
	settings = PolygonEditSettings.new()


func get_operation_name() -> String:
	return "Polygon Edit"


func get_operation_id() -> StringName:
	return &"polygon_edit"


func get_settings() -> Resource:
	return settings


func set_settings(new_settings: Resource) -> void:
	var typed := new_settings as PolygonEditSettings
	if typed == null:
		push_error("Image Wrangler: PolygonEditOp was handed settings of the wrong type.")
		return
	settings = typed


func make_settings() -> Resource:
	return PolygonEditSettings.new()


func get_settings_schema() -> Array[Dictionary]:
	return [
		{
			"property": &"polygons",
			"type": SettingType.POLYGON_LIST,
			"tooltip": "Regions drawn over the preview by hand. Subtract makes the inside fully\ntransparent whatever color it is; Add makes it fully opaque.\n\nThis is the one thing here that does not work by color, so it is the way to\nedit something that has no color in common with itself — a watermark, a scan\nedge, a stray element in a corner. Shapes may be concave.\n\nThe edge is hard: no antialiasing is rebuilt along it, since there is no\nbackground there to have blended with.",
		},
	]


## Cheap: one pass over each shape's bounding box, and no flood anywhere.
func stage_weight() -> float:
	return 0.05


## Geometry owes the keying nothing, so this works on its own.
func needs_keying() -> bool:
	return false


func process_context(ctx: IWPipelineContext) -> void:
	if settings.polygons == null or not settings.polygons.has_active():
		return

	_merge_into_blacked(ctx)
	if not report_progress(0.6):
		return

	# Only when there is already something to overrule. Placed above the keying
	# stage there is not, and that stage folds the declaration in itself — before
	# it estimates alpha, which is where a cut has to land to steer the bleed.
	if ctx.has_classification():
		ctx.apply_regions_to_mask()
	report_progress(1.0)


## Rasterises this stage's shapes and folds them into whatever is already declared.
func _merge_into_blacked(ctx: IWPipelineContext) -> void:
	var width := ctx.width
	var height := ctx.height

	var marked := ctx.blacked
	if marked.size() != ctx.pixel_count:
		marked = PackedByteArray()
		marked.resize(ctx.pixel_count)

	for region in settings.polygons.regions:
		if region == null or not region.is_active():
			continue
		var adding := region.mode == IWAlphaMode.Mode.ADD
		var value := IWPipelineContext.REGION_KEEP if adding else IWPipelineContext.REGION_CUT
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
					if adding or marked[row + x] != IWPipelineContext.REGION_KEEP:
						marked[row + x] = value
				pair += 2

	ctx.blacked = marked
