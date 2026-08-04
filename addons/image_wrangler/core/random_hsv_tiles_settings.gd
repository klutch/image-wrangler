@tool
class_name RandomHSVTilesSettings
extends Resource

## Every tunable of [RandomHSVTiles].
##
## Ranges live in [method RandomHSVTiles.get_settings_schema], not here.

## Which set of random colours comes out.
##
## The same seed on the same image always gives the same answer, so a sheet can be
## re-rolled until it looks right and then left alone. Named [code]rng_seed[/code] rather
## than [code]seed[/code] because that is a built-in function.
@export var rng_seed: int = 0

## How far each island's hue is allowed to wander, as a share of the colour wheel.
##
## At 1 an island can come out any colour at all; at 0 every hue is left alone. Starts at
## 1, since a random hue per object is what this stage is for.
@export var hue_amount: float = 1.0

## The far end each island's colourfulness may be pulled towards, as a scale.
##
## At 1 nothing moves. At 0 an island can come out anywhere between its own colour and
## grey; at 2, anywhere between its own colour and twice as deep. Starts at 1: a random
## saturation reads as damage rather than as a colour, so it is asked for rather than
## arrived at.
@export var saturation_amount: float = 1.0

## How far each island's lightness is allowed to wander, as a share either way.
##
## At 1 an island can come out anywhere between black and twice as bright. Starts at 0, so
## nothing moves until it is asked for.
@export var value_amount: float = 0.0


## A copy that belongs to no image. Nothing here is a coordinate and nothing is a nested
## Resource, so the plain duplicate is the whole of it.
func duplicate_for_new_image() -> RandomHSVTilesSettings:
    return duplicate()
