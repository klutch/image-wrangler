@tool
class_name SmoothBlocks
extends IWStackOperation

## Flattens the grid a JPEG leaves every eight pixels.
##
## The encoder cuts an image into squares of eight by eight and rounds each one off on
## its own, so neighbouring squares end up sitting at slightly different levels. The eye
## reads the joins as a grid, and it shows worst on the wide flat areas a key has to
## measure against — there is nothing else there for it to hide behind.
##
## Each seam is looked at in turn. A seam is only flattened where the step across it is
## small and both sides of it are nearly flat: a large step is a real edge that happens
## to land on the grid, and anything busy is detail, which survives compression far
## better than the level a block sits at.
##
## This is the partner of [SmoothColor] rather than a replacement for it. That one
## repairs color and leaves brightness alone; the grid is mostly in the brightness, so
## it needs its own pass. Run both on a bad JPEG.
##
## Put it above [RemoveBackground]. It rewrites the source pixels, so anything that has
## already measured them would be measuring pixels that are gone.

var settings: SmoothBlocksSettings


func _init() -> void:
    settings = SmoothBlocksSettings.new()


func get_operation_name() -> String:
    return "Smooth Blocks"


func get_operation_id() -> StringName:
    return &"smooth_blocks"


func get_settings() -> Resource:
    return settings


func set_settings(new_settings: Resource) -> void:
    var typed := new_settings as SmoothBlocksSettings
    if typed == null:
        push_error("Image Wrangler: SmoothBlocks was handed settings of the wrong type.")
        return
    settings = typed


func make_settings() -> Resource:
    return SmoothBlocksSettings.new()


## Nothing, for the same reason [Denoise] names nothing: the pipeline takes its suffix
## from the first enabled stage that offers one, and a repair stage should not be the
## one naming the file.
func get_output_suffix() -> String:
    return ""


func get_settings_schema() -> Array[Dictionary]:
    return [
        {
            "property": &"threshold",
            "label": "Threshold",
            "type": SettingType.FLOAT,
            "min": 0.0,
            "max": 0.3,
            "step": 0.01,
            "tooltip": "How big a step across a block seam still counts as an artifact.\n\nRoughly how badly the image was compressed: a lightly compressed image\nneeds very little, a heavily compressed one needs more. Too high and real\nedges that happen to land on the grid get flattened too, so raise it until\nthe grid goes and then stop.",
        },
        {
            "property": &"amount",
            "label": "Amount",
            "type": SettingType.FLOAT,
            "min": 0.0,
            "max": 1.0,
            "step": 0.05,
            "tooltip": "How much of each seam is flattened.\n\n0 changes nothing. 1 removes about half of every step it accepts and\nspreads the rest over the three pixels either side, which is what stops\nthe repair leaving a line of its own.",
        },
    ]


## Two passes that only touch the seams, so most of the image is never read.
func stage_weight() -> float:
    return 0.2


## It measures the image against itself, which needs no key.
func needs_keying() -> bool:
    return false


func establishes_keying() -> bool:
    return false


func process_context(ctx: IWPipelineContext) -> void:
    if settings.amount <= 0.0 or settings.threshold <= 0.0:
        return
    if not report_progress(0.05):
        return

    IWStageKernels.smooth_blocks(ctx, settings.threshold, settings.amount)

    # The distance map is measured off the colors that were just replaced, so it has to
    # be built again rather than left describing pixels that are gone. Clearing it is not
    # enough: Refine Edges skips its filter entirely when it is empty.
    ctx.key_dist = PackedFloat32Array()
    ctx.ensure_key_dist()
    report_progress(1.0)
