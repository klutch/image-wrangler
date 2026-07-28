@tool
class_name SmoothHalosSettings
extends Resource

## Every tunable of [SmoothHalos].
##
## Ranges live in [method SmoothHalos.get_settings_schema], not here.

## How much light-to-dark change a block needs before it counts as holding an edge.
## Blocks below this are left alone.
@export var threshold: float = 0.15

## How far the smoothing reaches, in pixels. The knob that decides how much it can do.
@export var radius: int = 2

## How much of the smoothed value is taken. Zero changes nothing.
@export var strength: float = 1.0


## A copy that belongs to no image. Nothing here is a coordinate and nothing is a
## nested Resource, so the plain duplicate is the whole of it.
func duplicate_for_new_image() -> SmoothHalosSettings:
    return duplicate()
