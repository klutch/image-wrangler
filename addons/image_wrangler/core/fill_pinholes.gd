@tool
class_name FillPinholes
extends IWStackOperation

## Closes the small transparent specks left inside a subject, painting each one the colour
## of what surrounds it.
##
## A keyer that finds its background colour again inside the subject punches a hole in it —
## a white glint in an eye, a pale speck on a petal, the flat highlight a JPEG leaves on a
## dark shape. They are too small to key around and too many to paint out by hand. This
## finds them and fills them in.
##
## [b]A hole is anything short of solid, with solid image all the way round it.[/b] Not
## just the clear pixels: a speck usually arrives with a soft rim of its own, so anything
## under full alpha joined to it is part of the same hole, counts toward its size, and comes
## out solid with the rest. Plugging a hole up to its rim and stopping would leave a ring of
## half-alpha exactly where the damage was.
##
## Anything reaching an edge of the image is the outside — the margin round a sprite, the
## space the keyer was asked to open, and the subject's own antialiasing where that joins it
## — and is never touched, however small. Only what is enclosed counts, which is what lets
## this sit below [RemoveBackground] without undoing it.
##
## [b]The colour is the plain average of the solid pixels round the rim.[/b] Every fully
## opaque pixel touching the hole counts once, however much of it touches. Nothing under
## full alpha votes, and nothing needs to: a part-transparent pixel is part of the hole
## rather than part of the rim.
##
## [b]It measures shape and alpha, not colour, so it needs no background keyed above
## it.[/b] Pointed at art that arrived with its own transparency it fills the holes in
## that. Pointed at a fully opaque image with nothing above it there is nothing short of
## solid anywhere and it does nothing, which is the failure worth having. Note what that
## means on an image with soft edges and no keying above it: an antialiased edge enclosed by
## opaque pixels is a hole by this definition, so raise [member
## FillPinholesSettings.max_area] there with the preview open.
##
## [b]Order.[/b] Below whatever opened the holes — a keyer, [RefineEdges], the alpha clip —
## since a hole that has not been made yet cannot be found. Above [EdgeCleanup], because a
## stroke follows the silhouette and one drawn around a speck that is then filled leaves a
## ring floating in the middle of the subject.

var settings: FillPinholesSettings


func _init() -> void:
    settings = FillPinholesSettings.new()


func get_operation_name() -> String:
    return "Fill Pinholes"


func get_operation_id() -> StringName:
    return &"fill_pinholes"


func get_settings() -> Resource:
    return settings


func set_settings(new_settings: Resource) -> void:
    var typed := new_settings as FillPinholesSettings
    if typed == null:
        push_error("Image Wrangler: FillPinholes was handed settings of the wrong type.")
        return
    settings = typed


func make_settings() -> Resource:
    return FillPinholesSettings.new()


## Nothing, for the same reason [RemoveLines] names nothing: the pipeline takes its suffix
## from the first enabled stage that offers one, and a repair should not be the one naming
## the file.
func get_output_suffix() -> String:
    return ""


func get_settings_schema() -> Array[Dictionary]:
    return [
        {
            "property": &"max_area",
            "label": "Max Area",
            "type": SettingType.INT,
            "min": 1,
            "max": 100,
            "step": 1,
            "tooltip": "The largest hole that gets filled, counted in pixels of area rather than in\nwidth. At 1 only single-pixel specks go.\n\nAnything bigger is left alone, so raising this until the damage disappears is\nthe way to set it — a gap that is meant to be there is usually far larger than\none that is not.\n\nEvery pixel short of fully solid counts toward the size, not just the clear\nones, so a speck with a soft rim is measured with that rim included and comes\nout solid all through.\n\nOnly a patch with image all the way round it counts as a hole. The space\noutside the subject is never filled, whatever size it is.",
        },
    ]


## One flood over the image and a short pass round each hole it keeps, none of which
## depends on how many holes there turn out to be.
func stage_weight() -> float:
    return 0.25


## Alpha is not colour. See the class note.
func needs_keying() -> bool:
    return false


func establishes_keying() -> bool:
    return false


## Never an error, because there is no arrangement in which this cannot run — only one in
## which the only transparency it can see is the source's own.
func prerequisite_note(ctx: IWPipelineContext) -> String:
    if ctx == null or ctx.has_keying or not ctx.coverage.is_empty():
        return ""
    return "Reading the source's own transparency."


## [b]What it owes the run.[/b] The distance map is measured off the colours it has just
## written, so it is rebuilt rather than left describing pixels that are gone — the same
## debt [RandomHSVTiles] pays, and for the same reason. The nearest-subject map is rebuilt
## as well, since a filled hole is subject now and anything bleeding colour into the
## transparency around it should be free to reach for it.
##
## No [method IWPipelineContext.compute_coverage], for the reason given on
## [method RemoveLines.process_context]: every pixel whose coverage this stage changes it
## sets to exactly one itself, and a re-derivation would flatten the guided filter's work in
## a halo around each fill.
func process_context(ctx: IWPipelineContext) -> void:
    if settings.max_area <= 0:
        return
    if not report_progress(0.05):
        return

    var filled := IWStageKernels.fill_pinholes(ctx, settings.max_area)
    if filled.is_empty():
        report_progress(1.0)
        return
    if not report_progress(0.8):
        return

    ctx.key_dist = PackedFloat32Array()
    ctx.ensure_key_dist()
    if ctx.has_classification():
        # The regions have the last word over anything a pass decided, so a hole the user
        # cut open on purpose is not quietly handed back as subject.
        ctx.apply_regions_to_mask()
        ctx.rebuild_nearest()
    report_progress(1.0)
