@tool
class_name BlackoutPolygon
extends Resource

## One region of an image to force fully transparent, whatever is in it.
##
## The geometric escape hatch from keying. Everything else [RemoveBackground]
## does removes background by [i]colour[/i] — even a picked island, which floods
## from a point and stops wherever the colour changes. A watermark, a scan edge or
## a stray element in the corner has no colour in common with itself, so nothing
## colour-based can describe it. A polygon can.
##
## Vertices are image pixel coordinates, held as [code]Array[Vector2i][/code]
## rather than a [PackedVector2Array] so that the sidecar codec round-trips them
## with no special case. Sub-pixel vertices would buy nothing: the interior is
## rasterised to whole pixels and the result is a hard cut either way.

## Fewest vertices that enclose any area. Two points are a line and a line has no
## interior, so anything below this is discarded rather than stored.
const MIN_POINTS := 3

## Saturation and value of a new polygon's swatch. Fully saturated and bright, so
## the outline reads over dark art and light art alike.
const _SWATCH_SATURATION := 0.75
const _SWATCH_VALUE := 1.0

@export var points: Array[Vector2i] = []

## Identifies this polygon in the list and on the preview.
##
## Random, and stored rather than derived from the row index: a colour computed
## from position would change the moment a polygon above it was removed, and the
## shape you were looking at on the preview would appear to become a different
## one.
@export var color: Color = Color.WHITE


func _init() -> void:
	# Assigned here as well as inline, so a polygon duplicated for another image
	# cannot end up sharing the array the original was built with.
	points = []


## A polygon with a fresh random swatch.
static func create() -> BlackoutPolygon:
	var polygon := BlackoutPolygon.new()
	polygon.color = Color.from_hsv(randf(), _SWATCH_SATURATION, _SWATCH_VALUE)
	return polygon


func size() -> int:
	return points.size()


func is_empty() -> bool:
	return points.is_empty()


## Whether this encloses any area, and so is worth rasterising or storing.
func is_drawable() -> bool:
	return points.size() >= MIN_POINTS


func add(at: Vector2i) -> void:
	points.append(at)


## Drops the last vertex placed, for undoing mid-draw.
func remove_last() -> void:
	if not points.is_empty():
		points.remove_at(points.size() - 1)


func set_point(index: int, at: Vector2i) -> void:
	if index < 0 or index >= points.size():
		return
	points[index] = at


## Smallest rectangle containing every vertex, or an empty one when there are
## none. What the scanline fill walks, rather than the whole image.
func bounds() -> Rect2i:
	if points.is_empty():
		return Rect2i()
	var minimum := points[0]
	var maximum := points[0]
	for point in points:
		minimum.x = mini(minimum.x, point.x)
		minimum.y = mini(minimum.y, point.y)
		maximum.x = maxi(maximum.x, point.x)
		maximum.y = maxi(maximum.y, point.y)
	return Rect2i(minimum, maximum - minimum + Vector2i.ONE)


## An independent copy, so two images never share one polygon.
func duplicate_polygon() -> BlackoutPolygon:
	var copy := BlackoutPolygon.new()
	copy.points = points.duplicate()
	copy.color = color
	return copy
