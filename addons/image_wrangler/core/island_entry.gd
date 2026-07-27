@tool
class_name IslandEntry
extends Resource

## One position picked off the preview, and what it does to the alpha there.
##
## Was a bare [Vector2i] until a picked spot needed more than a place: whether it
## is switched on, and which way it moves alpha. A Resource for the same reason
## [RemoveColorEntry] is one — the row has to carry state the point alone cannot.

@export var point: Vector2i = Vector2i.ZERO

## Off excludes this entry without losing where it was, so a pick can be tried
## and untried without being picked again.
@export var enabled: bool = true

## See [IWAlphaMode]. Subtract floods the region away; Add floods the same region
## and forces it opaque instead.
@export var mode: int = IWAlphaMode.Mode.SUBTRACT

## How far a pixel may drift from the colour under this island and still be part
## of the region it floods.
##
## Its own, rather than the constant every island used to share. An island is
## pointed at one region of one image, and how clean that region is has nothing to
## do with how clean the one next to it is — a speckled patch wants a loose
## tolerance where the flat panel beside it would be eaten by the same number.
@export var color_tolerance: float = RemoveColorEntry.DEFAULT_TOLERANCE


## An independent copy, so two images never share one entry.
func duplicate_entry() -> IslandEntry:
	var copy := IslandEntry.new()
	copy.point = point
	copy.enabled = enabled
	copy.mode = mode
	copy.color_tolerance = color_tolerance
	return copy
