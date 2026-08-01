@tool
class_name NormalBrightness
extends IWNormalLayer

## Reads the sprite's own light and dark as high and low.
##
## Two scales added together before the shape is worked out once: a fine pass over the
## colours as they are, which picks up line work, and a coarse pass over a mean of them,
## which picks up the large form.

const TINT := Color(1.0, 0.78, 0.3)

var settings: NormalBrightnessSettings


func _init() -> void:
    settings = NormalBrightnessSettings.new()


func get_operation_name() -> String:
    return "Brightness"


func get_operation_id() -> StringName:
    return &"normal_brightness"


func get_description() -> String:
    return "Reads the sprite's own light and dark as high and low. Picks up line work and texture, and is fooled by anything painted dark that was never meant to sit low."


func get_tint() -> Color:
    return TINT


func get_settings() -> Resource:
    return settings


func set_settings(new_settings: Resource) -> void:
    var typed := new_settings as NormalBrightnessSettings
    if typed == null:
        push_error("Image Wrangler: NormalBrightness was handed settings of the wrong type.")
        return
    settings = typed


func make_settings() -> Resource:
    return NormalBrightnessSettings.new()


func generate(sheet: Image, rects: PackedInt32Array) -> Image:
    return IWStageKernels.normal_from_brightness(sheet, rects, settings.coarse_size,
            settings.coarse, settings.fine, false)


func own_schema() -> Array[Dictionary]:
    return [
        {
            "property": &"coarse",
            "label": "Coarse Detail",
            "type": SettingType.FLOAT,
            "min": 0.0,
            "max": 16.0,
            "step": 0.05,
            "tooltip": "How much of the sprite's overall shading becomes shape.\n\nThis is the half that gives a sprite its large form. At zero the pass is skipped\nand only fine detail is left.\n\nThe useful numbers here run to several rather than to fractions: even a hard\npainted edge only changes brightness a little from one pixel to the next.",
        },
        {
            "property": &"coarse_size",
            "label": "Coarse Size",
            "type": SettingType.INT,
            "min": 1,
            "max": 32,
            "step": 1,
            "tooltip": "How far the coarse pass looks to decide what counts as overall shading, in\npixels.\n\nRoughly the size of the smallest thing it will still treat as form rather than\nas detail.",
        },
        {
            "property": &"fine",
            "label": "Fine Detail",
            "type": SettingType.FLOAT,
            "min": 0.0,
            "max": 16.0,
            "step": 0.05,
            "tooltip": "How much of the sprite's line work and texture becomes shape.\n\nRead from the colours as they are rather than from a blur, so it picks up single\npixels. At zero the pass is skipped.\n\nOn the same scale as Coarse Detail.",
        },
    ]
