@tool
class_name RemoveMinimumAreaSettings
extends Resource

## Every tunable of [RemoveMinimumArea].
##
## Ranges live in [method RemoveMinimumArea.get_settings_schema], not here.

## The side of the smallest square that survives, in pixels.
##
## Set as a side rather than as an area because a side is something you can measure off
## the image. The area it stands for is the square of it, and the form shows that as you
## drag.
@export var area_root: int = 3


## The area a shape has to beat, in pixels.
func min_area() -> int:
    return area_root * area_root


## The same number as a line for the form to show.
func area_text() -> String:
    return "%d pixels" % min_area()


## A copy that belongs to no image. Nothing here is a coordinate and nothing is a
## nested Resource, so the plain duplicate is the whole of it.
func duplicate_for_new_image() -> RemoveMinimumAreaSettings:
    return duplicate()
