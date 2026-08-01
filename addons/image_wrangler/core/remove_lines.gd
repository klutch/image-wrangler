@tool
class_name RemoveLines
extends IWStackOperation

## Erases every structure the silhouette is too thin to have earned: hairlines, scan
## borders, leftover grid rules, specks.
##
## [b]It is a morphological opening, and the setting is a width rather than a radius.[/b]
## A shape counts as thick enough where a square of side [code]thickness + 1[/code] fits
## inside it, so a structure of [member RemoveLinesSettings.thickness] pixels or fewer has
## nowhere to put one. Erode by that square to find where it fits, then either put the
## square back — every thin part goes, wherever it is — or flood each shape back from
## wherever a square did fit, so a shape thick anywhere survives whole. That second one is
## what [member RemoveLinesSettings.detached_only] selects.
##
## [b]An explicit square rather than a threshold on a distance map.[/b] The largest
## distance to background across a structure of width [code]w[/code] is
## [code]ceil(w / 2)[/code], so one pixel and two pixels give the same answer and no
## threshold can separate them — which is precisely the distinction this stage exists to
## make at its default. An erosion separates them exactly.
##
## [b]Thickness is measured on the solid part and the erase is applied to all of it.[/b]
## Those are two different sets on purpose. Measuring on everything above zero alpha would
## make a one-pixel antialiased line read as three wide, and erasing only the solid part
## would leave its skirt behind as exactly the faint ghost this is here to avoid — the
## thing the Alpha Floor in [RefineEdges] does instead of removing anything. So what
## survives is grown back out through its own antialiasing by a flood that may cross
## nothing but partly transparent pixels, bounded by the skirt rather than by a number.
## That is the only way a kept shape comes out with its edge untouched however soft that
## edge is; reclaiming a fixed pixel or two would harden every edge in the image.
##
## [b]It needs no background, and that is not an oversight.[/b] Every other stage that
## removes something measures colour, and colour is meaningless without a key. This one
## measures shape, which exists as soon as there is an alpha channel — so it works on art
## that arrived transparent, with nothing above it in the stack. Pointed at an opaque JPEG
## with no keying above it nothing is thin, and it does nothing, which is the failure worth
## having.
##
## [b]Order.[/b] It must be above [EdgeCleanup]. A stroke brings its own alpha and is
## composited over the result, so a stroke drawn around a hairline and then erased leaves
## the stroke behind as a floating outline — the artefact this stage exists to prevent,
## wearing a ring. Against [RefineEdges] it is free: above, the guided filter smooths what
## is left; below, it judges the alpha the filter settled on. Both are legitimate, and
## neither undoes the other. [Denoise] moves colour rather than alpha and does not interact
## with it at all.

## The colour this operation's marks are drawn in on the preview.
##
## Written out rather than worked out, and its own rather than the stack's, so it is the
## same colour every session. A unit-length colour, so no operation's marks arrive
## brighter than another's.
const TINT := Color(0.621, 0.784, 0.003)


var settings: RemoveLinesSettings


func _init() -> void:
    settings = RemoveLinesSettings.new()


func get_operation_name() -> String:
    return "Remove Lines"


func get_operation_id() -> StringName:
    return &"remove_lines"


func get_tint() -> Color:
    return TINT


func get_settings() -> Resource:
    return settings


func set_settings(new_settings: Resource) -> void:
    var typed := new_settings as RemoveLinesSettings
    if typed == null:
        push_error("Image Wrangler: RemoveLines was handed settings of the wrong type.")
        return
    settings = typed


func make_settings() -> Resource:
    return RemoveLinesSettings.new()


## Nothing, for the same reason [Denoise] names nothing: the pipeline takes its suffix
## from the first enabled stage that offers one, and a corrective stage that happens to
## sit at the top of a stack should not be the one naming the file.
func get_output_suffix() -> String:
    return ""


func get_settings_schema() -> Array[Dictionary]:
    return [
        {
            "property": &"thickness",
            "label": "Thickness",
            "type": SettingType.INT,
            "min": 1,
            "max": 16,
            "step": 1,
            "tooltip": "The widest structure that gets removed, in pixels. At 1 a one-pixel hairline\ngoes and a two-pixel line stays.\n\nMeasured in every direction, so a diagonal or a curve counts as much as a row\nor a column, and it makes no distinction between a line and a speck — anything\nthinner than this goes, however short it is.\n\nMeasured on the solid part of the shape, where alpha is at least a half. A\nshape that is wide but faint everywhere has no solid part, so it counts as thin\nand goes at any setting — unless it touches something that stayed, which brings\nit back with it.",
        },
        {
            "property": &"detached_only",
            "label": "Detached Only",
            "type": SettingType.BOOL,
            "tooltip": "Spares any shape that is thick enough somewhere, however thin the rest of it\ngets. A whisker hanging off a subject stays; a hairline lying beside it in the\ntransparency goes.\n\nThis is the usual job — debris that has nothing to do with the subject — and\nwhy it is on. Turn it off when the thin parts are themselves the problem, and\nevery run of pixels narrower than the thickness goes wherever it is, including\nthe fine detail on the subject's own edge.\n\nWith it off, a subject running off the edge of the image keeps its border: the\nsquare that measures it is allowed to sit inward. Only a structure genuinely\nthin in the image is removed there.",
        },
    ]


## Cheaper than the squeeze: four running-extreme sweeps and at most two floods, none of
## which cost anything per pixel that depends on the thickness.
func stage_weight() -> float:
    return 0.25


## Shape is not colour. See the class note.
func needs_keying() -> bool:
    return false


func establishes_keying() -> bool:
    return false


## Never an error, because there is no arrangement in which this cannot run — only one
## in which it is reading something the user may not have realised was there.
func prerequisite_note(ctx: IWPipelineContext) -> String:
    if ctx == null or ctx.has_keying or not ctx.coverage.is_empty():
        return ""
    return "Reading the source's own transparency."


## [b]No [method IWPipelineContext.compute_coverage] afterwards, and that is the one
## deliberate departure from [RemoveCrevice].[/b] The trio at the end of that stage exists
## because a squeeze [i]creates[/i] edge pixels that have never been matted, and computing
## the ring around them is what mattes them. This stage creates nothing: every pixel whose
## coverage it changes it sets to exactly zero itself, and the mask it leaves behind says
## so. Running the recompute anyway would not be a fix-up, it would be a re-derivation —
## and [method IWPipelineContext.compute_coverage] forces every subject pixel it visits to
## a coverage of one. That would flatten the guided filter's work, the alpha clip's, and
## the edge restoration's in a [member IWPipelineContext.search_radius]-wide halo around
## everything erased, which is exactly the halo where those stages had the most to say.
## RemoveCrevice can afford it because it belongs above them. This one is placeable
## anywhere, and stays placeable anywhere only by leaving that call out.
##
## [method IWPipelineContext.rebuild_nearest] is still owed: the hole left behind has to
## bleed its colour from what is still there rather than from the line that is gone.
func process_context(ctx: IWPipelineContext) -> void:
    if settings.thickness <= 0:
        return
    if not report_progress(0.05):
        return

    var touched := IWStageKernels.remove_lines(
            ctx, settings.thickness, settings.detached_only)
    if touched.is_empty():
        report_progress(1.0)
        return
    if not report_progress(0.8):
        return

    if ctx.has_classification():
        # The regions have the last word over anything a pass decided. The kernel already
        # refuses to erase a protected pixel, so this repairs nothing today — it is what
        # keeps the mask honest if that ever stops being true.
        ctx.apply_regions_to_mask()
        ctx.rebuild_nearest()
    report_progress(1.0)
