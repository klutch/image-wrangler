@tool
class_name TileSelectorSettings
extends Resource

## Every tunable of [TileSelector].

## The tiles the user chose, each as a point on one.
@export var picks: Array[TilePick] = []

## Which of [enum TileSelector.TileSelection] is in force.
@export var mode: int = 0


## Every tile the last run found, in the order it found them.
##
## [b]Deliberately not exported.[/b] An observation about one run rather than part of what
## the operation is. It is what the preview outlines, including the tiles nobody chose,
## which is what keeps a removed tile reachable.
var found_bounds: Array[Rect2i] = []


## Whether the tile numbered [param tile] survives this operation.
##
## Which is what the preview draws at full strength: a tile on its way out is faded, so the
## picture and the outlines say the same thing.
func survives(tile: int) -> bool:
    var picked := chose(tile)
    return not picked if mode == TileSelector.TileSelection.EXCLUDE_SELECTED else picked


## Whether the tile numbered [param tile] was chosen.
func chose(tile: int) -> bool:
    if tile < 0:
        return false
    for pick in picks:
        if pick != null and pick.tile == tile:
            return true
    return false


## The pick sitting on tile [param tile], or -1.
func pick_on(tile: int) -> int:
    if tile < 0:
        return -1
    for i in picks.size():
        var pick: TilePick = picks[i]
        if pick != null and pick.tile == tile:
            return i
    return -1


## A copy that belongs to no image.
##
## The picks are points on one image, so they go rather than travelling: a tile at those
## coordinates in the next image is a different tile, and carrying them over would hold
## back something nobody chose.
func duplicate_for_new_image() -> TileSelectorSettings:
    var copy := TileSelectorSettings.new()
    copy.mode = mode
    return copy
