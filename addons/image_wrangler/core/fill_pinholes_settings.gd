@tool
class_name FillPinholesSettings
extends Resource

## Every tunable of [FillPinholes].
##
## Ranges live in [method FillPinholes.get_settings_schema], not here.

## The largest hole that gets filled, in pixels of area.
##
## Every pixel short of fully solid counts toward that area, not only the clear ones.
## Anything bigger is left as it is, on the grounds that a wide gap is more likely to be
## part of the picture than damage. Starts at 1, which takes the single-pixel specks and
## nothing else.
@export var max_area: int = 1


## A copy that belongs to no image. Nothing here is a coordinate and nothing is a nested
## Resource, so the plain duplicate is the whole of it.
func duplicate_for_new_image() -> FillPinholesSettings:
    return duplicate()
