@tool
class_name HSVAdjust
extends IWStackOperation

## Turns the hue and scales the saturation and value of the pixels inside picked
## rectangles.
##
## Pick a region off the preview and it gets a row with three sliders of its own. Regions
## may overlap, and are applied in the order they were picked — each working on what the
## one before it left — so a broad correction can have a local one on top of it.
##
## Alpha is never touched, and nor is any pixel outside every rectangle.
##
## Put it above [RemoveBackground]. It rewrites the source pixels, so anything that has
## already measured them would be measuring colours that are gone.

var settings: HSVAdjustSettings


func _init() -> void:
    settings = HSVAdjustSettings.new()


func get_operation_name() -> String:
    return "HSV Adjustment"


func get_operation_id() -> StringName:
    return &"hsv_adjust"


func get_settings() -> Resource:
    return settings


func set_settings(new_settings: Resource) -> void:
    var typed := new_settings as HSVAdjustSettings
    if typed == null:
        push_error("Image Wrangler: HSVAdjust was handed settings of the wrong type.")
        return
    settings = typed


func make_settings() -> Resource:
    return HSVAdjustSettings.new()


## Nothing, for the same reason [Denoise] names nothing: the pipeline takes its suffix
## from the first enabled stage that offers one, and a colour tweak should not be the
## one naming the file.
func get_output_suffix() -> String:
    return ""


func get_settings_schema() -> Array[Dictionary]:
    return [
        {
            "property": &"regions",
            "label": "Regions",
            "type": SettingType.HSV_LIST,
            "tooltip": "Rectangles picked off the preview, each with its own hue, saturation\nand value.",
        },
    ]


## One pass over the pixels inside the rectangles, and nothing at all outside them.
func stage_weight() -> float:
    return 0.15


## It changes colours rather than measuring against one.
func needs_keying() -> bool:
    return false


func establishes_keying() -> bool:
    return false


func process_context(ctx: IWPipelineContext) -> void:
    if settings.regions == null or not settings.regions.has_active():
        return
    if not report_progress(0.05):
        return

    # Flattened here rather than read per pixel in the kernel, which is what every other
    # stage holding a list does — a Resource lookup inside a per-pixel loop was never
    # affordable.
    var rects := PackedInt32Array()
    var shifts := PackedFloat64Array()
    for region: HSVRegion in settings.regions.regions:
        if region == null or not region.is_active():
            continue
        rects.append(region.rect.position.x)
        rects.append(region.rect.position.y)
        rects.append(region.rect.size.x)
        rects.append(region.rect.size.y)
        shifts.append(region.hue)
        shifts.append(region.saturation)
        shifts.append(region.value)
    if rects.is_empty():
        report_progress(1.0)
        return

    IWStageKernels.adjust_hsv(ctx, rects, shifts)

    # The distance map is measured off the colours that were just changed, so it has to
    # be built again rather than left describing pixels that are gone. Clearing it is not
    # enough: Refine Edges skips its filter entirely when it is empty.
    ctx.key_dist = PackedFloat32Array()
    ctx.ensure_key_dist()
    report_progress(1.0)
