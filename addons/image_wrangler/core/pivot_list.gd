@tool
class_name PivotList
extends Resource

## The pivots set by hand on a packed sheet. See [Pivot].
##
## Only the sprites that were edited are on it. Everything else takes the middle of its
## rectangle facing [constant Pivot.DEFAULT_DIRECTION], which is what the lookup table held
## for every sprite before there was an editor.
##
## A Resource rather than a bare array, for the reason [PolygonRegionList] is one: it is
## swapped as a unit when the batch changes.

@export var pivots: Array[Pivot] = []


func _init() -> void:
    # Assigned here as well as inline, so a settings Resource duplicated for another batch
    # cannot end up sharing the array the original was built with.
    pivots = []


func size() -> int:
    return pivots.size()


func is_empty() -> bool:
    return pivots.is_empty()


func get_at(index: int) -> Pivot:
    if index < 0 or index >= pivots.size():
        return null
    return pivots[index]


## The row holding [param sprite]'s pivot, or -1 when it has none.
func row_of(sprite: int) -> int:
    for i in pivots.size():
        var pivot := pivots[i]
        if pivot != null and pivot.sprite == sprite:
            return i
    return -1


## Points [param sprite]'s pivot at [param at] facing [param facing], adding a row when it
## has none. Returns the row.
##
## One row per sprite: editing the same sprite again moves the pivot it already has, rather
## than leaving two entries claiming it.
func set_pivot(sprite: int, at: Vector2, facing: Vector2) -> int:
    var row := row_of(sprite)
    if row < 0:
        pivots.append(Pivot.create(sprite, at, facing))
        return pivots.size() - 1
    var pivot := pivots[row]
    pivot.offset = at
    pivot.direction = Pivot.sanitise_direction(facing)
    # Redrawing a switched-off pivot is a request to use it again.
    pivot.enabled = true
    return row


func remove_at(index: int) -> void:
    if index < 0 or index >= pivots.size():
        return
    pivots.remove_at(index)


func clear() -> void:
    pivots.clear()


## Where every sprite's pivot sits and which way it faces, given where the sprites landed.
##
## [param rects] is one [Rect2i] per sprite in the order they were found — the array the
## lookup table is built from. Returns positions in sheet pixels first, directions second,
## both one entry per rectangle, so the result lines up with the numbers the table uses.
##
## Sprites with no entry, a switched-off one, or one left over from a sheet with more
## sprites on it all fall back to the middle facing [constant Pivot.DEFAULT_DIRECTION].
func resolve(rects: Array) -> Array:
    var positions := PackedVector2Array()
    var directions := PackedVector2Array()
    positions.resize(rects.size())
    directions.resize(rects.size())
    for i in rects.size():
        var rect: Rect2i = rects[i]
        positions[i] = Vector2(rect.position) + Vector2(rect.size) * 0.5
        directions[i] = Pivot.DEFAULT_DIRECTION
    for pivot in pivots:
        if pivot == null or not pivot.enabled:
            continue
        if pivot.sprite < 0 or pivot.sprite >= rects.size():
            continue
        positions[pivot.sprite] = Vector2(rects[pivot.sprite].position) + pivot.offset
        directions[pivot.sprite] = Pivot.sanitise_direction(pivot.direction)
    return [positions, directions]


## A copy sharing none of its pivots.
##
## [method Resource.duplicate] copies the array's references, so without this two settings
## Resources would hold different lists pointing at the same pivots.
func duplicate_pivots() -> PivotList:
    var copy := PivotList.new()
    for pivot in pivots:
        if pivot != null:
            copy.pivots.append(pivot.duplicate_pivot())
    return copy
