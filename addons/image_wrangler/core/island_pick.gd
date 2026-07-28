@tool
class_name IslandPick
extends Resource

## One pixel inside a picked island, and how far a flood starting there may drift.
##
## Split out of [IslandEntry] when picking stopped being a single click. Dragging a
## rectangle names a region rather than a spot, and every pixel in it is somewhere the
## flood can start from — so what used to be a point on the entry is now a list of
## these, and the entry is the group they are managed as.
##
## [b]The tolerance sits here rather than on the group[/b] for the same reason it sits
## on a [RemoveColorEntry] rather than on the settings: one number cannot describe two
## things. A dragged region routinely straddles a flat panel and the speckle beside it,
## and the pixel that needs 0.05 is in the same rectangle as the one that needs 0.3.
## The group editor writes every pick at once, which is what makes the common case one
## gesture; this is what makes the uncommon one possible at all.
##
## [b]No colour is stored.[/b] It is read off [member point] at the moment the island
## runs, so an island always keys out exactly what is there rather than what was there
## when it was picked. See [IslandPickerOp].

## Tolerance a freshly picked island starts at.
##
## Its own number rather than the one a Remove Color starts at, and a much looser one,
## because the two are aimed at different things. A Remove Color is a colour the user
## chose and can see; it starts tight so it takes only what was asked for. An island is
## a spot the user pointed at, and what they meant was the [i]region[/i] under the
## pointer — so it has to swallow that region's own variation without being told what
## that variation is. Starting tight means every island comes out as a handful of
## pixels and has to be widened by hand, which is the wrong default for a control
## whose whole point is one gesture.
##
## Loose is also the safer direction here. An island only floods where it is put, so
## overreaching costs the region it is in rather than the image; and anywhere it
## reaches by straying is matted by the ordinary coverage maths rather than cut out.
const DEFAULT_TOLERANCE := 0.2

## Where in the image this pick sits. Both a seed for the flood and the spot its
## colour is sampled from.
@export var point: Vector2i = Vector2i.ZERO

## How far a pixel may drift from the colour under this pick and still be part of the
## region it floods.
@export var color_tolerance: float = DEFAULT_TOLERANCE


## An independent copy, so two entries never share one pick.
func duplicate_pick() -> IslandPick:
	var copy := IslandPick.new()
	copy.point = point
	copy.color_tolerance = color_tolerance
	return copy
