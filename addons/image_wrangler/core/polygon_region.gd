@tool
class_name PolygonRegion
extends Resource

## One region of an image drawn by hand, to force transparent or opaque.
##
## The geometric escape hatch from keying. Everything else [RemoveBackground] does
## works by [i]colour[/i] — even a picked island, which floods from a point and
## stops wherever the colour changes. A watermark, a scan edge or a stray element
## in the corner has no colour in common with itself, so nothing colour-based can
## describe it. A polygon can.
##
## Vertices are image pixel coordinates, held as [code]Array[Vector2i][/code]
## rather than a [PackedVector2Array] so that the sidecar codec round-trips them
## with no special case. Sub-pixel vertices would buy nothing: the interior is
## rasterised to whole pixels and the result is a hard edge either way.

## Fewest vertices that enclose any area. Two points are a line and a line has no
## interior, so anything below this is discarded rather than stored.
const MIN_POINTS := 3

## Saturation and value of a new region's swatch. Fully saturated and bright, so
## the outline reads over dark art and light art alike.
const _SWATCH_SATURATION := 0.75
const _SWATCH_VALUE := 1.0

@export var points: Array[Vector2i] = []

## Identifies this region in the list and on the preview.
##
## Random, and stored rather than derived from the row index: a colour computed
## from position would change the moment a region above it was removed, and the
## shape you were looking at on the preview would appear to become a different
## one.
@export var color: Color = Color.WHITE

## Off excludes this region from the run without losing its shape. It still draws
## on the preview, so a region can be tried and untried without being redrawn —
## which for something built corner by corner is the whole point.
@export var enabled: bool = true

## See [IWAlphaMode]. Subtract cuts the interior away; Add forces it opaque.
@export var mode: int = IWAlphaMode.Mode.SUBTRACT


func _init() -> void:
	# Assigned here as well as inline, so a region duplicated for another image
	# cannot end up sharing the array the original was built with.
	points = []


## A region with a fresh random swatch.
static func create() -> PolygonRegion:
	var region := PolygonRegion.new()
	region.color = Color.from_hsv(randf(), _SWATCH_SATURATION, _SWATCH_VALUE)
	return region


func size() -> int:
	return points.size()


func is_empty() -> bool:
	return points.is_empty()


## Whether this encloses any area, and so is worth drawing or storing.
func is_drawable() -> bool:
	return points.size() >= MIN_POINTS


## Whether this should affect the image. Drawable and switched on — a region that
## is off still shows on the preview but is left out of the rasterisation.
func is_active() -> bool:
	return enabled and is_drawable()


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


## An independent copy, so two images never share one region.
func duplicate_region() -> PolygonRegion:
	var copy := PolygonRegion.new()
	copy.points = points.duplicate()
	copy.color = color
	copy.enabled = enabled
	copy.mode = mode
	return copy
