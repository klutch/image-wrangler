@tool
class_name NormalRoundEdges
extends IWNormalLayer

## Rounds every sprite off from its outline inwards.
##
## Reads the silhouette and nothing else, so a flat shape comes out looking carved but the
## whole of it lifts as one lump. [NormalColorRegions] is the same kernel with the colour
## boundaries inside the sprite rounded off as well.

const TINT := Color(0.45, 0.75, 1.0)

var settings: NormalRoundEdgesSettings


func _init() -> void:
    settings = NormalRoundEdgesSettings.new()


func get_operation_name() -> String:
    return "Round Edges"


func get_operation_id() -> StringName:
    return &"normal_round_edges"


func get_description() -> String:
    return "Rounds every sprite off from its outline inwards, so a flat shape reads as one that has been carved. Knows nothing about what is drawn inside the sprite, so the whole of it lifts as one lump."


func get_tint() -> Color:
    return TINT


func get_settings() -> Resource:
    return settings


func set_settings(new_settings: Resource) -> void:
    var typed := new_settings as NormalRoundEdgesSettings
    if typed == null:
        push_error("Image Wrangler: NormalRoundEdges was handed settings of the wrong type.")
        return
    settings = typed


func make_settings() -> Resource:
    return NormalRoundEdgesSettings.new()


## A colour tolerance below zero is what tells the kernel to round off the outline alone,
## which is the whole of what separates this from [NormalColorRegions].
func generate(sheet: Image, rects: PackedInt32Array) -> Image:
    return IWStageKernels.normal_from_shape(sheet, rects, settings.roll_off,
            sanitise_curve(settings.curve), settings.strength, -1.0, false)


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
            "tooltip": "How far in from the outline the rounding reaches, in pixels.\n\nPast this the sprite is flat. Small numbers read as a carved rim on a flat\nobject; numbers approaching half the sprite read as one rounded lump.",
        },
        {
            "property": &"curve",
            "label": "Curve",
            "type": SettingType.ENUM,
            "options": NORMAL_CURVE_LABELS,
            "tooltip": "The shape the rounding takes from the outline inwards.\n\nRound is a quarter circle and the usual choice. Soft eases at both ends so\nthere is no crease where the rounding starts. Straight is a flat chamfer.\nHollow curves the other way, like the inside of a bowl.",
        },
    ]
