@tool
class_name SmoothColorSettings
extends Resource

## Every tunable of [SmoothColor].
##
## Ranges live in [method SmoothColor.get_settings_schema], not here.

## How far the smoothing reaches, in pixels. Two covers the smear a JPEG leaves.
@export var radius: int = 2

## How much color change counts as noise rather than a real edge. Higher flattens
## more and follows edges less.
@export var strength: float = 0.5

## How much of the smoothed color is mixed back over the original. Zero changes
## nothing.
@export var amount: float = 1.0


## A copy that belongs to no image. Nothing here is a coordinate and nothing is a
## nested Resource, so the plain duplicate is the whole of it.
func duplicate_for_new_image() -> SmoothColorSettings:
    return duplicate()
