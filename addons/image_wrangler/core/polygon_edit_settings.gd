@tool
class_name PolygonEditSettings
extends Resource

## Every tunable of [PolygonEditOp].

## Hand-drawn regions forced transparent or opaque. See [PolygonRegion].
##
## The one thing in the stack that does not work by colour, and so the only way to
## describe something that has no colour in common with itself — a watermark, a scan
## edge, a stray element in a corner. Coordinates, and just as meaningless applied to
## another image as a picked island is.
@export var polygons: PolygonRegionList


func _init() -> void:
	polygons = PolygonRegionList.new()


## A copy that belongs to no image: the list starts empty, since the image its shapes
## were drawn over is gone.
func duplicate_for_new_image() -> PolygonEditSettings:
	var copy: PolygonEditSettings = duplicate()
	copy.polygons = PolygonRegionList.new()
	return copy
