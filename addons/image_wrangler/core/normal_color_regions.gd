@tool
class_name NormalColorRegions
extends IWNormalLayer

## Rounds off from the outline and from every colour boundary inside it.
##
## The same kernel [NormalRoundEdges] runs, with the colour test switched on: each flat area
## of colour lifts on its own instead of the sprite rising as one lump.

const TINT := Color(0.55, 1.0, 0.5)

var settings: NormalColorRegionsSettings


func _init() -> void:
    settings = NormalColorRegionsSettings.new()


func get_operation_name() -> String:
    return "Color Regions"


func get_operation_id() -> StringName:
    return &"normal_color_regions"


func get_description() -> String:
    return "Rounds off from the outline and from every colour boundary inside it, so each flat area of colour lifts on its own. Made for cel-shaded art, and turns to mush on anything dithered."


func get_tint() -> Color:
    return TINT


func get_settings() -> Resource:
    return settings


func set_settings(new_settings: Resource) -> void:
    var typed := new_settings as NormalColorRegionsSettings
    if typed == null:
        push_error("Image Wrangler: NormalColorRegions was handed settings of the wrong type.")
        return
    settings = typed


func make_settings() -> Resource:
    return NormalColorRegionsSettings.new()


func generate(sheet: Image, rects: PackedInt32Array) -> Image:
    return IWStageKernels.normal_from_shape(sheet, rects, settings.roll_off,
            sanitise_curve(settings.curve), settings.strength, settings.color_tolerance, false)


func own_schema() -> Array[Dictionary]:
    return [
        {
            "property": &"strength",
            "label": "Strength",
            "type": SettingType.FLOAT,
            "min": 0.0,
            "max": 2.0,
            "step": 0.01,
            "tooltip": "How far the rounding tips the surface over.\n\nMeasured against the roll-off distance rather than in pixels, so the slope stays\nthe same when that distance is dragged. Past about 1 the rim turns over far\nenough to face away from the light.",
        },
        {
            "property": &"roll_off",
            "label": "Roll-off",
            "type": SettingType.INT,
            "min": 1,
            "max": 64,
            "step": 1,
            "tooltip": "How far in from an outline or a colour boundary the rounding reaches, in pixels.\n\nPast this the area is flat. Small numbers read as a carved rim on each flat\ncolour; large ones round each area into a dome.",
        },
        {
            "property": &"curve",
            "label": "Curve",
            "type": SettingType.ENUM,
            "options": NORMAL_CURVE_LABELS,
            "tooltip": "The shape the rounding takes from the outline inwards.\n\nRound is a quarter circle and the usual choice. Soft eases at both ends so\nthere is no crease where the rounding starts. Straight is a flat chamfer.\nHollow curves the other way, like the inside of a bowl.",
        },
        {
            "property": &"color_tolerance",
            "label": "Color Tolerance",
            "type": SettingType.FLOAT,
            "min": 0.0,
            "max": 1.0,
            "step": 0.01,
            "tooltip": "How far apart two neighbouring colours have to be before the boundary between\nthem is rounded off too.\n\nToo low and every speck of dithering counts as a boundary, which leaves the map\nflat — run Smooth Color over the images first if that happens. Too high and only\nthe outline is left.",
        },
    ]
