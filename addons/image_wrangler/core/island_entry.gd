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

## Tolerance a freshly picked island starts at.
##
## Its own number rather than the one a Remove Color starts at, and a much looser one,
## because the two are aimed at different things. A Remove Color is a colour the user
## chose and can see; it starts tight so it takes only what was asked for. An island is
## a spot the user pointed at, and what they meant was the [i]region[/i] under the
## pointer — so it has to swallow that region's own variation without being told what
## that variation is. Starting tight means every island comes out as a handful of
## pixels and has to be widened by hand, which is the wrong default for a control
## whose whole point is one click.
##
## Loose is also the safer direction here. An island only floods where it is put, so
## overreaching costs the region it is in rather than the image; and anywhere it
## reaches by straying is matted by the ordinary coverage maths rather than cut out.
const DEFAULT_TOLERANCE := 0.2

## How far a pixel may drift from the colour under this island and still be part
## of the region it floods.
##
## Its own, rather than the constant every island used to share. An island is
## pointed at one region of one image, and how clean that region is has nothing to
## do with how clean the one next to it is — a speckled patch wants a loose
## tolerance where the flat panel beside it would be eaten by the same number.
@export var color_tolerance: float = DEFAULT_TOLERANCE


## An independent copy, so two images never share one entry.
func duplicate_entry() -> IslandEntry:
	var copy := IslandEntry.new()
	copy.point = point
	copy.enabled = enabled
	copy.mode = mode
	copy.color_tolerance = color_tolerance
	return copy
