@tool
class_name BrushStrokeList
extends Resource

## The hand-painted strokes of an image. See [BrushStroke].
##
## A Resource rather than a bare [code]Array[BrushStroke][/code] for the same reason
## [PolygonRegionList] is one: the dock swaps it as a unit when the selected image changes,
## and wrapping it leaves room to grow without changing the shape of the settings that hold
## it.
##
## [b]Order carries meaning here, unlike in [PolygonRegionList].[/b] There an Add is an
## override that wins every overlap whatever position it holds, which is what lets that
## list be a set of rules. A brush is not a set of rules — it is paint, and paint goes on
## in the order it was applied. So these run top to bottom, each stroke working on what the
## ones above it left, and a Subtract drawn after an Add bites into it.

@export var strokes: Array[BrushStroke] = []


func _init() -> void:
    # Assigned here as well as inline, so a settings Resource duplicated for another
    # image cannot end up sharing the array the original was built with.
    strokes = []


func size() -> int:
    return strokes.size()


func is_empty() -> bool:
    return strokes.is_empty()


func get_at(index: int) -> BrushStroke:
    if index < 0 or index >= strokes.size():
        return null
    return strokes[index]


## Appends an empty stroke at the given brush and returns it, for the drag to fill in.
##
## It starts on the same mode as the stroke before it, so painting several Add strokes in
## a row does not mean resetting the dropdown after each one. The first stroke has nothing
## to follow and takes the default.
func add(radius: int, sharpness: float) -> BrushStroke:
    var stroke := BrushStroke.create(radius, sharpness)
    var previous := get_at(strokes.size() - 1)
    if previous != null:
        stroke.mode = previous.mode
    strokes.append(stroke)
    return stroke


func remove_at(index: int) -> void:
    if index < 0 or index >= strokes.size():
        return
    strokes.remove_at(index)


func clear() -> void:
    strokes.clear()


## Whether anything here would change the image. An empty list, or one holding only
## unstarted or switched-off strokes, paints nothing.
func has_active() -> bool:
    for stroke in strokes:
        if stroke != null and stroke.is_active():
            return true
    return false


## A copy sharing none of its strokes.
##
## [method Resource.duplicate] copies the array's [i]references[/i], so without this two
## settings Resources would hold different lists pointing at the same strokes and painting
## on one would paint on the other.
func duplicate_strokes() -> BrushStrokeList:
    var copy := BrushStrokeList.new()
    for stroke in strokes:
        if stroke != null:
            copy.strokes.append(stroke.duplicate_stroke())
    return copy
