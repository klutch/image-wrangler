@tool
class_name RandomHSVTiles
extends IWStackOperation

## Finds every object in the image by itself and turns each one a different colour.
##
## Where [HSVAdjust] waits to be handed a rectangle, this one goes looking. Every island of
## visible pixels is an object, the smallest rectangle containing it is its region, and
## each region gets a random hue, saturation, value and colorize of its own. A sheet of
## forty flowers becomes forty colours from one seed and four sliders.
##
## [b]Every slider is a span, not a number.[/b] Each has a low end and a high end, and each
## object draws its own number between the two. Pull the ends apart to spread a sheet out,
## or put them together to give every object the same fixed adjustment.
##
## [b]An island is whatever the alpha says it is.[/b] The stage reads what the run
## currently shows — the source's own transparency, times whatever the stages above have
## keyed out — so where it sits in the stack decides what it finds. On a sheet with an
## opaque background and nothing above it, the whole image is one island and comes out one
## flat shift. The same sheet below [RemoveBackground] is one island per flower. That is
## the placement this stage is for.
##
## [b]Thickness and extent are asked separately.[/b] What counts as one object is decided
## on the solid part, where alpha is at least a half; the shift is then applied out through
## everything still visible around it, so an object's antialiased fringe is recoloured with
## it. A fringe left behind would ring every object in the colour it used to be. The same
## split [RemoveLines] makes, for the same reason — and an island with no solid pixel
## anywhere is left alone entirely.
##
## [b]Corner to corner counts as joined.[/b] The keying floods are 4-connected so that
## background cannot leak through a diagonal hairline. The question here is the opposite
## one — whether two parts touching at a corner are the same object — so this is
## 8-connected. Two petals that meet only diagonally are one flower, and giving them two
## colours would be the obvious bug.
##
## [b]Same seed, same answer.[/b] Each island's three numbers are a hash of the seed and
## the island's own place in the scan, so re-running an image reproduces it exactly.
##
## Above [EdgeCleanup], which draws its stroke from colours this stage moves. It rewrites
## the source pixels, so anything that has already measured them would be measuring
## colours that are gone.

## The colour this operation's marks are drawn in on the preview.
##
## Written out rather than worked out, and its own rather than the stack's, so it is the
## same colour every session. A unit-length colour, so no operation's marks arrive
## brighter than another's.
const TINT := Color(0.918, 0.323, 0.230)


var settings: RandomHSVTilesSettings


func _init() -> void:
    settings = RandomHSVTilesSettings.new()


func get_operation_name() -> String:
    return "Random HSV Tiles"


func get_operation_id() -> StringName:
    return &"random_hsv_tiles"


func get_tint() -> Color:
    return TINT


func get_settings() -> Resource:
    return settings


func set_settings(new_settings: Resource) -> void:
    var typed := new_settings as RandomHSVTilesSettings
    if typed == null:
        push_error("Image Wrangler: RandomHSVTiles was handed settings of the wrong type.")
        return
    settings = typed


func make_settings() -> Resource:
    return RandomHSVTilesSettings.new()


## Nothing, for the same reason [HSVAdjust] names nothing: the pipeline takes its suffix
## from the first enabled stage that offers one, and a colour tweak should not be the one
## naming the file.
func get_output_suffix() -> String:
    return ""


func get_settings_schema() -> Array[Dictionary]:
    return [
        {
            "property": &"rng_seed",
            "label": "Seed",
            "type": SettingType.INT,
            "min": 0,
            "max": 999999,
            "step": 1,
            "tooltip": "Which set of random colours comes out.\n\nThe same seed on the same image always gives the same answer, so a sheet can\nbe re-rolled until it looks right and then left alone. Change it and every\nobject changes together.",
        },
        {
            "property": &"hue_range",
            "label": "Hue",
            "type": SettingType.FLOAT_RANGE,
            "min": -0.5,
            "max": 0.5,
            "step": 1.0 / 360.0,
            "tooltip": "How far round the colour wheel each object is turned, in turns.\n\nThe whole span is the whole wheel, so any object can come out any colour.\nPull the ends together for a sheet that stays in one part of the wheel, or\nput both at 0 to leave every hue where it is.",
        },
        {
            "property": &"saturation_range",
            "label": "Saturation",
            "type": SettingType.FLOAT_RANGE,
            "min": 0.0,
            "max": 2.0,
            "step": 0.01,
            "tooltip": "How much more or less colourful each object comes out, as a multiplier.\n\n1 leaves it alone, 0 drains it to grey and 2 is twice as deep. Nothing can\ninvent colour in an object that has none.",
        },
        {
            "property": &"value_range",
            "label": "Value",
            "type": SettingType.FLOAT_RANGE,
            "min": 0.0,
            "max": 3.0,
            "step": 0.01,
            "tooltip": "How much lighter or darker each object comes out, as a multiplier.\n\n1 leaves it alone, 0 is black and 3 is three times as bright. Anything\nalready at full brightness stays there.",
        },
        {
            "property": &"colorize_range",
            "label": "Colorize",
            "type": SettingType.FLOAT_RANGE,
            "min": 0.0,
            "max": 1.0,
            "step": 0.01,
            "tooltip": "How far each object is mixed towards one flat colour, keeping each pixel's\nown lightness.\n\nThe tint an object takes is its own random hue, so Hue decides how much the\ntints differ from one another. Put both ends at 1 to make every object flat.\nBlack and white stay where they are.",
        },
    ]


## Two passes to find the islands and one over the pixels inside them, none of which
## depends on how many islands there turn out to be.
func stage_weight() -> float:
    return 0.3


## Alpha is not colour. See the class note.
func needs_keying() -> bool:
    return false


func establishes_keying() -> bool:
    return false


## Never an error, because there is no arrangement in which this cannot run — only one in
## which every object it can see is the whole image.
func prerequisite_note(ctx: IWPipelineContext) -> String:
    if ctx == null or ctx.has_keying or not ctx.coverage.is_empty():
        return ""
    return "Reading the source's own transparency."


## Whether every span sits where it does nothing, so the stage can be skipped outright.
func _is_neutral() -> bool:
    return _spans_at(settings.hue_range, 0.0) and _spans_at(settings.saturation_range, 1.0) \
            and _spans_at(settings.value_range, 1.0) and _spans_at(settings.colorize_range, 0.0)


func _spans_at(span: Vector2, resting: float) -> bool:
    return is_equal_approx(span.x, resting) and is_equal_approx(span.y, resting)


func process_context(ctx: IWPipelineContext) -> void:
    if _is_neutral():
        return
    if not report_progress(0.05):
        return

    var spans := PackedFloat64Array([
        settings.hue_range.x, settings.hue_range.y,
        settings.saturation_range.x, settings.saturation_range.y,
        settings.value_range.x, settings.value_range.y,
        settings.colorize_range.x, settings.colorize_range.y,
    ])
    var bounds := IWStageKernels.random_hsv_tiles(ctx, settings.rng_seed, spans)
    if bounds.is_empty():
        report_progress(1.0)
        return

    # The distance map is measured off the colours that were just changed, so it has to be
    # measured again rather than left describing pixels that are gone — but only inside the
    # island bounds the kernel just handed back, which contain everything it recoloured. A
    # pixel's distance depends on its own colour and the first key and on nothing else, so
    # this is the map a full rebuild would give, at the cost of the islands rather than of
    # the sheet.
    ctx.refresh_key_dist_rects(bounds)
    report_progress(1.0)
