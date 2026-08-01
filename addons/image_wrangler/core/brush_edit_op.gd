@tool
class_name BrushEdit
extends IWStackOperation

## Paints alpha up or down by hand, along strokes dragged over the preview.
##
## [PolygonEditOp] is the tool for a shape whose corners you can name. This is the tool for
## everything that has none — a ragged edge to tidy, a speck the keyer left, a bite to put
## back into something a tolerance ate. Drag over it rather than describing it.
##
## [b]A stroke is a path, not a set of pixels.[/b] What is stored is wherever the pointer
## was seen, which on a fast drag skips whole runs; the gap between two samples is walked a
## pixel at a time when the stroke is laid down, so what lands is continuous however
## quickly it was made. Storing the dense version would be the same picture in a sidecar
## tens of times the size.
##
## [b]Strokes run top to bottom, each working on what the ones above it left.[/b] Paint
## goes on in the order it was applied, so a Subtract stroke drawn after an Add bites into
## it. Anything else would leave no way to take back part of a stroke short of deleting
## the whole thing. [PolygonEditOp] settles its shapes the same way, and so does the stack
## as a whole.
##
## [b]Sharpness is a property of the stroke, not of the tool.[/b] So is the radius. Both are
## captured when the stroke is drawn and can be changed afterwards on the selected row,
## which re-lays the same path at the new setting. A stroke made fine stays fine after the
## brush has been turned up for something else.
##
## [b]Within one stroke the brush cannot double up.[/b] Dragging slowly lands twenty
## overlapping dabs on a pixel where dragging fast lands two, and a stroke that came out
## darker for having been drawn carefully would be unusable. So the dabs in a stroke take
## the strongest rather than accumulating. Two separate strokes over the same place do
## accumulate, which is the ordinary way to lean on something.
##
## [b]It measures nothing, so it needs no background keyed above it.[/b] It is an
## instruction about the result rather than a reading of the image, and works on art that
## arrived with its own transparency with nothing above it in the stack.
##
## [b]Order.[/b] Below whatever it is correcting, since a stroke is the last word on the
## pixels it covers and there is no point painting alpha that something below then
## re-derives. Above [EdgeCleanup], because a stroke changes the silhouette the stroke
## drawn there has to follow.

var settings: BrushEditSettings


func _init() -> void:
    settings = BrushEditSettings.new()


func get_operation_name() -> String:
    return "Brush Edit"


func get_operation_id() -> StringName:
    return &"brush_edit"


func get_settings() -> Resource:
    return settings


func set_settings(new_settings: Resource) -> void:
    var typed := new_settings as BrushEditSettings
    if typed == null:
        push_error("Image Wrangler: BrushEdit was handed settings of the wrong type.")
        return
    settings = typed


func make_settings() -> Resource:
    return BrushEditSettings.new()


## Nothing, for the same reason [RemoveLines] names nothing: the pipeline takes its suffix
## from the first enabled stage that offers one, and a hand correction should not be the
## one naming the file.
func get_output_suffix() -> String:
    return ""


func get_settings_schema() -> Array[Dictionary]:
    return [
        {
            "property": &"strokes",
            "type": SettingType.BRUSH_LIST,
            "tooltip": "Strokes dragged over the preview by hand. Subtract erases along the path;\nAdd paints it solid.\n\nThe tool for anything with no corners to name and no colour in common with\nitself — a ragged edge, a speck, a bite to put back into something a tolerance\nate. Strokes go on in the order they were drawn, so a Subtract after an Add\nbites into it.\n\nEach stroke keeps the radius and sharpness it was drawn at. Select a row to\nchange them, which re-lays that path at the new setting.",
        },
    ]


## Cheap: one pass over each stroke's own dabs, and nothing that depends on the size of
## the image.
func stage_weight() -> float:
    return 0.1


## Paint owes the keying nothing. See the class note.
func needs_keying() -> bool:
    return false


func establishes_keying() -> bool:
    return false


## [b]What it owes the run.[/b] A rebuild of the nearest-subject map, since a stroke moves
## pixels between subject and background and anything bleeding colour into the transparency
## should be reaching for what is there now.
##
## No [method IWPipelineContext.compute_coverage], for the reason given on
## [method RemoveLines.process_context]: every pixel whose coverage this stage changes it
## sets itself, and a re-derivation would flatten the guided filter's work — and this
## stage's own — in a halo around every stroke. No distance-map rebuild either: the keys
## are measured against RGB, and paint moves alpha and nothing else.
func process_context(ctx: IWPipelineContext) -> void:
    if settings.strokes == null or not settings.strokes.has_active():
        return
    if not report_progress(0.05):
        return

    var touched := _paint(ctx)
    if touched.is_empty():
        report_progress(1.0)
        return
    if not report_progress(0.8):
        return

    if ctx.has_classification():
        # The drawn regions have the last word over anything a pass decided, the way they
        # do after every other stage that writes the mask.
        ctx.apply_regions_to_mask()
        ctx.rebuild_nearest()
    report_progress(1.0)


## Flattens this stage's strokes and hands them to the painter.
##
## The strokes are walked once here, into plain packed arrays, and the painting itself
## happens in [method IWStageKernels.paint_strokes]. The split is the same one every stage
## makes: reading a [BrushStroke] is a Resource property lookup, and the painter would do
## one per dab.
func _paint(ctx: IWPipelineContext) -> PackedInt32Array:
    var points := PackedInt32Array()
    var starts := PackedInt32Array()
    var counts := PackedInt32Array()
    var radii := PackedInt32Array()
    var adding := PackedByteArray()
    var sharpness := PackedFloat64Array()

    for stroke in settings.strokes.strokes:
        if stroke == null or not stroke.is_active():
            continue
        @warning_ignore("integer_division")
        var start := points.size() / 2
        starts.append(start)
        counts.append(stroke.points.size())
        radii.append(clampi(stroke.radius, BrushStroke.MIN_RADIUS, BrushStroke.MAX_RADIUS))
        adding.append(1 if stroke.mode == IWAlphaMode.Mode.ADD else 0)
        sharpness.append(clampf(stroke.sharpness, 0.0, 1.0))
        for point in stroke.points:
            points.append(point.x)
            points.append(point.y)

    return IWStageKernels.paint_strokes(ctx, points, starts, counts, radii, adding, sharpness)
