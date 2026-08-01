@tool
class_name TilePick
extends Resource

## One tile the user chose, stored as a point on it.
##
## A point rather than a number, because the tiles are worked out fresh on every run and
## their numbering shifts the moment anything above changes what it leaves. A point still
## lands on the same tile.

## The pixel that was clicked.
@export var point: Vector2i = Vector2i.ZERO

## Off leaves this pick in the list without acting on it, so a tile can be tried and
## untried without being picked again. The tile it names is still worked out on every run,
## so switching it back on needs no second click.
@export var enabled: bool = true


## Which tile this landed on during the last run, or -1 for none.
##
## [b]Deliberately not exported.[/b] It is an observation about one run of one image
## rather than part of what the pick is, so the codec leaves it out and the copy the
## worker runs on starts empty every time.
var tile := -1

## That tile's rectangle, or an empty one when the pick landed on nothing.
var bounds := Rect2i()


## Whether the last run found a tile under this pick.
func has_tile() -> bool:
    return tile >= 0 and bounds.size.x > 0 and bounds.size.y > 0
