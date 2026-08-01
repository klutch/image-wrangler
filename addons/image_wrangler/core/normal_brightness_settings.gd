@tool
class_name NormalBrightnessSettings
extends NormalLayerSettings

## Every tunable of [NormalBrightness].
##
## Ranges live in [method NormalBrightness.own_schema], not here.

## How much of the sprite's overall shading becomes shape, and how far the pass looks to
## decide what counts as overall rather than as detail.
##
## Zero strength skips the pass. The strength is a plain multiplier on a gradient of
## brightness, and the gradient across even a hard painted edge is small — so the useful
## numbers are several, not fractions.
@export var coarse: float = 4.0
@export var coarse_size: int = 6

## How much of the sprite's line work and texture becomes shape.
##
## Read from the colours as they are rather than from a blur, so it picks up single pixels.
## Zero skips the pass. On the same scale as [member coarse].
@export var fine: float = 3.0
