@tool
class_name RandomHSVTiles
extends IWStackOperation

## Finds every object in the image by itself and turns each one a different colour.
##
## Where [HSVAdjust] waits to be handed a rectangle, this one goes looking. Every island of
## visible pixels is an object, the smallest rectangle containing it is its region, and
## each region gets a random hue, saturation and value of its own. A sheet of forty
## flowers becomes forty colours from one seed and three sliders.
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
            "property": &"hue_amount",
            "label": "Hue",
            "type": SettingType.FLOAT,
            "min": 0.0,
            "max": 1.0,
            "step": 0.01,
            "tooltip": "How far each object's hue is allowed to wander, as a share of the colour wheel.\n\nAt 1 an object can come out any colour at all. At 0 every hue is left where it\nis, which is what to use when only the strength or the brightness should vary.",
        },
        {
            "property": &"saturation_amount",
            "label": "Saturation",
            "type": SettingType.FLOAT,
            "min": 0.0,
            "max": 2.0,
            "step": 0.01,
            "tooltip": "The far end each object's colourfulness may be pulled towards.\n\nAt 1 nothing moves. At 0 an object can come out anywhere between its own\ncolour and grey; at 2, anywhere between its own colour and twice as deep.\nNothing can invent colour in an object that has none.",
        },
        {
            "property": &"value_amount",
            "label": "Value",
            "type": SettingType.FLOAT,
            "min": 0.0,
            "max": 1.0,
            "step": 0.01,
            "tooltip": "How far each object's lightness is allowed to wander, either way.\n\nAt 1 an object can come out anywhere between black and twice as bright.\nAnything already at full brightness stays there.",
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


func process_context(ctx: IWPipelineContext) -> void:
    if is_zero_approx(settings.hue_amount) and is_equal_approx(settings.saturation_amount, 1.0) \
            and is_zero_approx(settings.value_amount):
        return
    if not report_progress(0.05):
        return

    var bounds := IWStageKernels.random_hsv_tiles(
            ctx,
            settings.rng_seed,
            settings.hue_amount,
            settings.saturation_amount,
            settings.value_amount)
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
