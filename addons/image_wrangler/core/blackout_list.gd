@tool
class_name BlackoutList
extends Resource

## The regions of an image to force transparent. See [BlackoutPolygon].
##
## A Resource rather than a bare [code]Array[BlackoutPolygon][/code] for the same
## reason [IslandList] is one: the dock swaps it as a unit when the selected image
## changes, and wrapping it leaves room to grow without changing the shape of the
## settings that hold it.
##
## Polygons union. Order carries no meaning here — unlike [RemoveColorList], where
## the first entry to claim a pixel wins, a pixel inside any polygon is inside,
## and nothing downstream can tell which one put it there.

@export var polygons: Array[BlackoutPolygon] = []


func _init() -> void:
	# Assigned here as well as inline, so a settings Resource duplicated for
	# another image cannot end up sharing the array the original was built with.
	polygons = []


func size() -> int:
	return polygons.size()


func is_empty() -> bool:
	return polygons.is_empty()


func get_at(index: int) -> BlackoutPolygon:
	if index < 0 or index >= polygons.size():
		return null
	return polygons[index]


## Appends an empty polygon with a fresh swatch and returns it, for the drawing
## session to fill in.
func add() -> BlackoutPolygon:
	var polygon := BlackoutPolygon.create()
	polygons.append(polygon)
	return polygon


func remove_at(index: int) -> void:
	if index < 0 or index >= polygons.size():
		return
	polygons.remove_at(index)


func clear() -> void:
	polygons.clear()


## Whether anything here would change the image. An empty list, or one holding
## only half-drawn or switched-off polygons, rasterises to nothing.
func has_active() -> bool:
	for polygon in polygons:
		if polygon != null and polygon.is_active():
			return true
	return false


## A copy sharing none of its polygons.
##
## [method Resource.duplicate] copies the array's *references*, so without this
## two settings Resources would hold different lists pointing at the same
## polygons and dragging a vertex on one would move it on the other.
##
## Named around the polygons rather than the copying because [method
## Resource.duplicate_deep] already exists and takes a mode argument, and an
## override has to match its parent's signature.
func duplicate_polygons() -> BlackoutList:
	var copy := BlackoutList.new()
	for polygon in polygons:
		if polygon != null:
			copy.polygons.append(polygon.duplicate_polygon())
	return copy
