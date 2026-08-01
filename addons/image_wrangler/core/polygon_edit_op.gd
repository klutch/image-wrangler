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
## [b]Shapes resolve in the order they are listed[/b], a later one overwriting the
## part of an earlier one it covers, Add and Cut alike. Neither mode outranks the
## other; what settles an overlap is position, the same as everywhere else in the
## stack. The same holds between two of these stages, and between one of these and
## anything below it.
##
## [b]A drawn edge grows no band.[/b] A polygon edge never blended with anything,
## so it is left hard on purpose rather than matted like a keyed edge.
##
## Sits happily above or below a keying stage, and means something slightly
## different in each place. Above, it declares the regions and the keying stage
## folds them in before it estimates any alpha — so the shapes also steer where the
## bleed takes its colours from. Below, it overrules whatever alpha has been worked
## out by then. Either way what it settles can be settled again by anything under it.

## The colour this operation's marks are drawn in on the preview.
##
## Written out rather than worked out, and its own rather than the stack's, so it is the
## same colour every session. A unit-length colour, so no operation's marks arrive
## brighter than another's.
const TINT := Color(0.853, 0.094, 0.513)


var settings: PolygonEditSettings


func _init() -> void:
    settings = PolygonEditSettings.new()


func get_operation_name() -> String:
    return "Polygon Edit"


func get_operation_id() -> StringName:
    return &"polygon_edit"


func get_tint() -> Color:
    return TINT


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
    # Here rather than at the end of the run, for the reason given in
    # [method IslandPickerOp.process_context]: a shape settles the pixels it covers where
    # the user put the operation, and a stage below is free to settle them again.
    ctx.apply_regions_to_coverage()
    report_progress(1.0)


## Flattens this stage's shapes and hands them to the scanline fill.
##
## The regions are walked once here, into plain packed arrays, and the rasterising
## itself happens in [method IWStageKernels.rasterise_regions]. The split is the same
## one every stage makes: reading a [PolygonRegion] is a Resource property lookup, and a
## scanline fill would do one per vertex per row.
func _merge_into_blacked(ctx: IWPipelineContext) -> void:
    var points := PackedInt32Array()
    var starts := PackedInt32Array()
    var counts := PackedInt32Array()
    var adding := PackedByteArray()

    for region in settings.polygons.regions:
        if region == null or not region.is_active():
            continue
        @warning_ignore("integer_division")
        var start := points.size() / 2
        starts.append(start)
        counts.append(region.points.size())
        adding.append(1 if region.mode == IWAlphaMode.Mode.ADD else 0)
        for point in region.points:
            points.append(point.x)
            points.append(point.y)

    IWStageKernels.rasterise_regions(ctx, points, starts, counts, adding)
