@tool
class_name PolygonRegionList
extends Resource

## The hand-drawn regions of an image. See [PolygonRegion].
##
## A Resource rather than a bare [code]Array[PolygonRegion][/code] for the same
## reason [IslandList] is one: the dock swaps it as a unit when the selected image
## changes, and wrapping it leaves room to grow without changing the shape of the
## settings that hold it.
##
## Order carries no meaning here — unlike [RemoveColorList], where the first entry
## to claim a pixel wins, a pixel inside a region is inside, and precedence
## between Add and Subtract is decided by the mode rather than by position.

@export var regions: Array[PolygonRegion] = []


func _init() -> void:
	# Assigned here as well as inline, so a settings Resource duplicated for
	# another image cannot end up sharing the array the original was built with.
	regions = []


func size() -> int:
	return regions.size()


func is_empty() -> bool:
	return regions.is_empty()


func get_at(index: int) -> PolygonRegion:
	if index < 0 or index >= regions.size():
		return null
	return regions[index]


## Appends an empty region with a fresh swatch and returns it, for the drawing
## session to fill in.
##
## It starts on the same mode as the region before it, so drawing several Add
## regions in a row does not mean resetting the dropdown after each one. The first
## region has nothing to follow and takes the default.
func add() -> PolygonRegion:
	var region := PolygonRegion.create()
	var previous := get_at(regions.size() - 1)
	if previous != null:
		region.mode = previous.mode
	regions.append(region)
	return region


func remove_at(index: int) -> void:
	if index < 0 or index >= regions.size():
		return
	regions.remove_at(index)


func clear() -> void:
	regions.clear()


## Whether anything here would change the image. An empty list, or one holding
## only half-drawn or switched-off regions, rasterises to nothing.
func has_active() -> bool:
	for region in regions:
		if region != null and region.is_active():
			return true
	return false


## A copy sharing none of its regions.
##
## [method Resource.duplicate] copies the array's *references*, so without this
## two settings Resources would hold different lists pointing at the same regions
## and dragging a vertex on one would move it on the other.
func duplicate_regions() -> PolygonRegionList:
	var copy := PolygonRegionList.new()
	for region in regions:
		if region != null:
			copy.regions.append(region.duplicate_region())
	return copy
