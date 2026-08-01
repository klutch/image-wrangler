@tool
class_name NormalRoundEdgesSettings
extends NormalLayerSettings

## Every tunable of [NormalRoundEdges].
##
## Ranges live in [method NormalRoundEdges.own_schema], not here.

## How far the rounding tips the surface over, against the roll-off distance.
##
## Measured that way rather than in pixels so the slope holds when [member roll_off] is
## dragged.
@export var strength: float = 0.5

## How far in from the outline the rounding reaches, in pixels.
##
## Past this the sprite is flat.
@export var roll_off: int = 8

## The shape the rounding takes. See [enum IWNormalLayer.NormalCurve].
@export var curve: int = 0
