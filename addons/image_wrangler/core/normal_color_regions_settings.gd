@tool
class_name NormalColorRegionsSettings
extends NormalLayerSettings

## Every tunable of [NormalColorRegions].
##
## Ranges live in [method NormalColorRegions.own_schema], not here.

## How far the rounding tips the surface over, against the roll-off distance.
@export var strength: float = 0.5

## How far in from an outline or a colour boundary the rounding reaches, in pixels.
@export var roll_off: int = 8

## The shape the rounding takes. See [enum IWNormalLayer.NormalCurve].
@export var curve: int = 0

## How far apart two neighbouring colours have to be before the boundary between them is
## rounded off as well as the outline.
##
## The whole of what separates this layer from [NormalRoundEdges].
@export var color_tolerance: float = 0.15
