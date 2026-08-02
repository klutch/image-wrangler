@tool
class_name PosterizeSettings
extends Resource

## Every tunable of [Posterize].
##
## Ranges live in [method Posterize.get_settings_schema], not here.

## Where the colors that survive come from.
enum Palette {
    ## A fixed ladder per channel, the same for every image.
    EVEN_STEPS,
    ## Picked out of the image itself.
    BEST_COLORS,
}

## What happens to the color a pixel could not have.
enum Dither {
    ## Dropped.
    NONE,
    ## Passed on to the neighbours not yet reached.
    FLOYD_STEINBERG,
}

## Whether the colors come off a fixed ladder or are picked out of the image.
@export var palette_mode: int = Palette.EVEN_STEPS

## How many steps red, green and blue each get. Two gives eight colors in all.
@export var levels: int = 4

## How many colors the palette holds when it is picked out of the image.
@export var color_count: int = 16

## Whether every object gets its own palette instead of the whole sheet sharing one.
@export var per_tile: bool = true

## Whether the color a pixel could not have is passed on to its neighbours.
@export var dither_mode: int = Dither.NONE

## How much of that leftover color is passed on. One is the full pattern.
@export var dither_strength: float = 1.0


## A copy that belongs to no image. Nothing here is a coordinate and nothing is a
## nested Resource, so the plain duplicate is the whole of it.
func duplicate_for_new_image() -> PosterizeSettings:
    return duplicate()
