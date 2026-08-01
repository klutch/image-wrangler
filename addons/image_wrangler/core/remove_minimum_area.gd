@tool
class_name RemoveMinimumArea
extends IWStackOperation

## Removes every separate shape smaller than a given area.
##
## [RemoveLines] answers "is this thin", which spares a big ragged blob and takes a long
## clean hairline. This answers "is there enough of this to be anything", which is the
## other half of the same job: the crumbs a keyer leaves behind are rarely thin, they are
## simply small.
##
## [b]Area is summed alpha, not counted pixels.[/b] A half-covered pixel is half a pixel of
## area. A speck made mostly of fringe is mostly not there, and counting it whole would let
## it pass for a solid block of the same width.
##
## [b]It sees fainter things than the packer does.[/b] Anything above zero alpha joins a
## shape here, where an object elsewhere in the addon has to be half opaque somewhere to
## count at all. A speck with no solid pixel anywhere is exactly the thing worth removing,
## so it cannot be the thing the rule cannot see.
##
## [b]It measures nothing by colour, so it needs no background keyed above it.[/b] It reads
## alpha and works on art that arrived with its own transparency.
##
## [b]Order.[/b] Below whatever leaves the crumbs, which is usually the keying. Above
## [EdgeCleanup], since removing a shape changes the silhouette the stroke has to follow.

## The colour this operation's marks are drawn in on the preview.
##
## Written out rather than worked out, and its own rather than the stack's, so it is the
## same colour every session. A unit-length colour, so no operation's marks arrive
## brighter than another's.
const TINT := Color(0.210, 0.397, 0.893)


var settings: RemoveMinimumAreaSettings


func _init() -> void:
    settings = RemoveMinimumAreaSettings.new()


func get_operation_name() -> String:
    return "Remove Minimum Area"


func get_operation_id() -> StringName:
    return &"remove_minimum_area"


func get_tint() -> Color:
    return TINT


func get_settings() -> Resource:
    return settings


func set_settings(new_settings: Resource) -> void:
    var typed := new_settings as RemoveMinimumAreaSettings
    if typed == null:
        push_error("Image Wrangler: RemoveMinimumArea was handed settings of the wrong type.")
        return
    settings = typed


func make_settings() -> Resource:
    return RemoveMinimumAreaSettings.new()


## Nothing, for the reason [RemoveLines] names nothing: the pipeline takes its suffix from
## the first enabled stage that offers one, and a cleanup pass should not be the one naming
## the file.
func get_output_suffix() -> String:
    return ""


func get_settings_schema() -> Array[Dictionary]:
    return [
        {
            "property": &"area_root",
            "label": "Size",
            "type": SettingType.INT,
            "min": 1,
            "max": 64,
            "step": 1,
            "tooltip": "The side of the smallest square that survives, in pixels. Anything covering\nless than that much goes.\n\nSet as a side rather than as an area because a side is something you can\nmeasure off the image. At 3, a shape has to cover 9 pixels to stay.\n\nSemi-transparent pixels count for what they cover, so a half-covered pixel is\nhalf a pixel of area. A speck made mostly of fringe is mostly not there.",
        },
        {
            "property": &"area_root",
            "label": "Area",
            "type": SettingType.READOUT,
            "text_from": &"area_text",
            "tooltip": "What the size above works out to, which is what a shape is actually measured\nagainst.",
        },
        {
            "property": &"area_root",
            "label": "Removed",
            "type": SettingType.READOUT,
            "text_from": &"removed_text",
            "tooltip": "How many separate shapes the last run took out. Each one is outlined on the\npreview, so what disappeared can still be seen.",
        },
    ]


## One labelling pass and two walks over the image, none of which depend on the size.
func stage_weight() -> float:
    return 0.25


## Size is not colour. See the class note.
func needs_keying() -> bool:
    return false


func establishes_keying() -> bool:
    return false


## Never an error, because there is no arrangement in which this cannot run — only one in
## which it is reading something the user may not have realised was there.
func prerequisite_note(ctx: IWPipelineContext) -> String:
    if ctx == null or ctx.has_keying or not ctx.coverage.is_empty():
        return ""
    return "Reading the source's own transparency."


## What it wants outlined: the shapes it took, so what disappeared can still be seen.
func marked_regions() -> Array[Rect2i]:
    return settings.removed_bounds if settings != null else [] as Array[Rect2i]


func absorb_run_report(from: IWStackOperation) -> void:
    var source := from as RemoveMinimumArea
    if source == null or source.settings == null or settings == null:
        return
    settings.removed_bounds = source.settings.removed_bounds.duplicate()
    settings.has_run = source.settings.has_run


## [b]No [method IWPipelineContext.compute_coverage] afterwards[/b], for the reason
## [method RemoveLines.process_context] gives: every pixel whose coverage this changes it
## sets to exactly zero itself, and re-deriving would force every subject pixel it visited
## back to full coverage — flattening the guided filter's work in a halo round everything
## erased. [method IWPipelineContext.rebuild_nearest] is still owed, so the hole bleeds its
## colour from what is left rather than from what has gone.
func process_context(ctx: IWPipelineContext) -> void:
    settings.removed_bounds = []
    settings.has_run = true
    if settings.area_root <= 0:
        return
    if not report_progress(0.05):
        return

    var bounds := IWStageKernels.remove_minimum_area(ctx, settings.min_area())
    if bounds.is_empty():
        report_progress(1.0)
        return
    @warning_ignore("integer_division")
    var found := bounds.size() / 4
    for n in found:
        settings.removed_bounds.append(Rect2i(
                bounds[n * 4], bounds[n * 4 + 1], bounds[n * 4 + 2], bounds[n * 4 + 3]))
    if not report_progress(0.8):
        return

    if ctx.has_classification():
        # The drawn regions have the last word over anything a pass decided, the way they
        # do after every other stage that writes the mask.
        ctx.apply_regions_to_mask()
        ctx.rebuild_nearest()
    report_progress(1.0)
