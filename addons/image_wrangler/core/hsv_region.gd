@tool
class_name HSVRegion
extends Resource

## One rectangle of pixels, and what it does to their colour.

## The pixels this covers, in image coordinates.
@export var rect: Rect2i = Rect2i()

## Off leaves the region on the list without applying it, so an adjustment can be
## tried and untried without picking the area again.
@export var enabled: bool = true

## How far round the colour wheel to turn, in turns. Wraps, so 0 and 1 are the same.
@export var hue: float = 0.0

## How much more or less colourful, as a multiplier. 1 leaves it alone.
@export var saturation: float = 1.0

## How much lighter or darker, as a multiplier. 1 leaves it alone.
@export var value: float = 1.0


## Whether this would change anything if it ran.
func is_active() -> bool:
    return enabled and rect.size.x > 0 and rect.size.y > 0 and not is_neutral()


## Whether the three sliders are all sitting where they do nothing.
func is_neutral() -> bool:
    return is_zero_approx(hue) and is_equal_approx(saturation, 1.0) \
            and is_equal_approx(value, 1.0)


## What the row calls itself: where it is, and which sliders are off neutral.
func describe() -> String:
    var parts := PackedStringArray()
    if not is_zero_approx(hue):
        parts.append("H%+d" % roundi(hue * 360.0))
    if not is_equal_approx(saturation, 1.0):
        parts.append("S%+d%%" % roundi((saturation - 1.0) * 100.0))
    if not is_equal_approx(value, 1.0):
        parts.append("V%+d%%" % roundi((value - 1.0) * 100.0))
    var where := "(%d, %d) %d×%d" % [rect.position.x, rect.position.y, rect.size.x, rect.size.y]
    return where if parts.is_empty() else "%s  %s" % [where, " ".join(parts)]
