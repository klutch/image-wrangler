@tool
class_name RandomHSVTilesSettings
extends Resource

## Every tunable of [RandomHSVTiles].
##
## Ranges live in [method RandomHSVTiles.get_settings_schema], not here.
##
## The four adjustments are spans rather than single numbers: x is the low end, y the high,
## and each object draws its own number somewhere between them. Both ends together means
## every object gets the same fixed adjustment.

## Which set of random colours comes out.
##
## The same seed on the same image always gives the same answer, so a sheet can be
## re-rolled until it looks right and then left alone. Named [code]rng_seed[/code] rather
## than [code]seed[/code] because that is a built-in function.
@export var rng_seed: int = 0

## How far round the colour wheel each object is turned, in turns.
##
## Starts at the whole wheel, since a random hue per object is what this stage is for. Both
## ends at 0 leaves every hue alone.
@export var hue_range: Vector2 = Vector2(-0.5, 0.5)

## How much more or less colourful each object comes out, as a multiplier.
##
## 1 leaves it alone, 0 drains it to grey, 2 is twice as deep. Starts at 1 to 1: a random
## saturation reads as damage rather than as a colour, so it is asked for rather than
## arrived at.
@export var saturation_range: Vector2 = Vector2(1.0, 1.0)

## How much lighter or darker each object comes out, as a multiplier.
##
## Reads the same way as [HSVAdjust]'s value slider. 1 leaves it alone, 0 is black, 3 is
## three times as bright. Starts at 1 to 1, so nothing moves until it is asked for.
@export var value_range: Vector2 = Vector2(1.0, 1.0)

## How far each object is mixed towards one flat colour, keeping each pixel's lightness.
##
## The tint an object takes is its own random hue, so [member hue_range] decides how much
## the tints differ from one another. Starts at 0 to 0.
@export var colorize_range: Vector2 = Vector2(0.0, 0.0)


## A copy that belongs to no image. Nothing here is a coordinate and nothing is a nested
## Resource, so the plain duplicate is the whole of it.
func duplicate_for_new_image() -> RandomHSVTilesSettings:
    return duplicate()
