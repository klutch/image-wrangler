@tool
class_name IWNormalLayer
extends IWStackItem

## One pass of the Export tab's normal map generator.
##
## A layer is handed the finished sheet and where every sprite landed on it, and hands back
## a normal map the same size. The layers above it made one too; [member
## NormalLayerSettings.combine_mode] and [member NormalLayerSettings.combine_strength] say
## how the two are joined. The first layer switched on has nothing to join, so those two
## settings are left off its card entirely — see [member is_first].
##
## [b]Every layer generates with green pointing up.[/b] Green Points Down is applied once to
## the finished stack rather than by each layer, so combining never has to reason about
## which way round its inputs were written. See [method IWPacking.build_normal_map].

## How a layer's map is merged into what the layers above it produced.
enum CombineMode {
    ## Slopes added. The same answer as adding the two height surfaces and working the
    ## normal out once, so neither layer's detail is averaged away.
    SLOPE,
    ## The layer turned to face the way the one above it does, so its detail follows a
    ## curve instead of lying flat across it.
    REORIENTED,
}

## Dropdown labels, in enum order.
const COMBINE_LABELS := ["Slope Blending", "Reoriented Mapping"]

## The shape of a roll-off, from the outline inwards.
##
## Here rather than on [IWPacking], where it used to be, because it describes what a layer
## does rather than what the sheet is — and the two layers that read it both come through
## this class anyway.
enum NormalCurve {
    ## A quarter circle. Steep at the rim and flat in the middle, the usual carved look.
    ROUND,
    ## Eased at both ends, so there is no crease where the rounding starts.
    SOFT,
    ## One constant slope: a flat chamfer.
    STRAIGHT,
    ## Curved the other way, gentle at the rim and steepening inwards, like a bowl.
    HOLLOW,
}

## Dropdown labels, in enum order.
const NORMAL_CURVE_LABELS := ["Round", "Soft", "Straight", "Hollow"]

## Whether nothing switched on sits above this layer, so it has nothing to combine with.
##
## A switched-off layer contributes nothing, so it does not count as being above anything:
## ticking the top card off hands the base to the one under it, and the combine rows move
## with it.
##
## Written by the dock before the card's form is built, because a layer knows nothing about
## where in the stack it sits. Read by [method get_settings_schema] alone.
var is_first := false

## Why the last map could not be made, or empty when it could.
##
## [b]Deliberately not exported.[/b] An observation about one run rather than a setting. Only
## the neural layer ever sets it: the other three either make a map or were switched off.
var last_error := ""


## [param curve] pulled back into range, for a value that came from a hand-edited file
## rather than from the dropdown.
static func sanitise_curve(curve: int) -> int:
    return curve if curve >= 0 and curve < NORMAL_CURVE_LABELS.size() else NormalCurve.ROUND


## The map this layer makes, or null when it cannot make one.
##
## [param rects] is x, y, w, h per sprite, the flattening the packer already keeps. The map
## comes back RGBA8 the size of the sheet, flat wherever no sprite covers.
func generate(_sheet: Image, _rects: PackedInt32Array) -> Image:
    return null


## The settings rows for this layer's card: how it joins the layer above, then its own.
##
## [b]Not overridden by the generators.[/b] They write [method own_schema] instead, so the
## two combine rows cannot be forgotten by one of them or ordered differently by another.
func get_settings_schema() -> Array[Dictionary]:
    if is_first:
        return own_schema()
    var schema := combine_schema()
    schema.append_array(own_schema())
    return schema


## What this layer alone offers.
func own_schema() -> Array[Dictionary]:
    return []


## The two rows every layer but the top one gets.
func combine_schema() -> Array[Dictionary]:
    return [
        {
            "property": &"combine_mode",
            "label": "Combine",
            "type": SettingType.ENUM,
            "options": COMBINE_LABELS,
            "tooltip": "How this layer joins the one above it.\n\nSlope Blending adds the two surfaces' slopes, which is the same answer as\nadding the two heights together and working the shape out once — so neither\nlayer's detail is flattened by the other. Right when both layers describe the\nsame surface.\n\nReoriented Mapping turns this layer to face the way the one above it does, so\nits detail follows a curve instead of lying flat across it. Right when the\nlayer above is a shape and this one is surface detail meant to sit on it.\n\nThe topmost layer that is switched on is the base, and its own Combine setting\ndoes nothing.",
        },
        {
            "property": &"combine_strength",
            "label": "Strength",
            "type": SettingType.FLOAT,
            "min": 0.0,
            "max": 1.0,
            "step": 0.01,
            "tooltip": "How much of this layer reaches the result.\n\nAt zero the layers above come through untouched, whichever way they are being\ncombined. At one this layer is at full strength.",
        },
    ]
