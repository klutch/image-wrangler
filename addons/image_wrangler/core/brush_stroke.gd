@tool
class_name BrushStroke
extends Resource

## One stroke painted over the preview by hand, to force alpha up or down along a path.
##
## Where a [PolygonRegion] describes an area by its outline, this describes one by
## dragging over it. The two answer different questions: a polygon is the tool for a shape
## with corners you can name, and a brush is the tool for everything that has none — a
## ragged edge to tidy, a speck to take out, a bite to put back.
##
## [b]The points are the path the pointer took, not the pixels it covered.[/b] A drag
## reports wherever the pointer was seen, which on a fast sweep skips whole runs of pixels;
## the gap between two samples is walked a pixel at a time when the stroke is painted, so
## what lands is continuous however quickly it was drawn. Storing the dense version instead
## would be the same picture in a sidecar tens of times the size.
##
## Points are image pixel coordinates, held as [code]Array[Vector2i][/code] rather than a
## [PackedVector2Array] so the sidecar codec round-trips them with no special case — the
## same choice [PolygonRegion] makes, for the same reason.

## Widest and narrowest brush a stroke may be drawn with.
##
## The radius is half a pixel short of what it says when the brush is measured, so 1 is a
## single pixel, 2 is three across, 3 is five, and so on. That is what makes the smallest
## setting the pencil it looks like rather than a five-pixel cross.
const MIN_RADIUS := 1
const MAX_RADIUS := 128

## Saturation and value of a new stroke's swatch. Fully saturated and bright, so the path
## reads over dark art and light art alike — the same pair [PolygonRegion] uses.
const _SWATCH_SATURATION := 0.75
const _SWATCH_VALUE := 1.0

@export var points: Array[Vector2i] = []

## How wide this stroke was drawn, in pixels from the centre.
##
## Kept per stroke rather than shared, and captured at the moment it is drawn: a stroke
## made fine should stay fine after the brush has been turned up for something else. It
## can still be changed afterwards on the selected row, which re-lays the same path at the
## new width.
@export var radius: int = 8

## How hard the edge of the brush is, 0 to 1.
##
## At 1 the stroke has a hard rim; below that it ramps to nothing over the outer part of
## the brush, and at 0 the ramp runs the whole way from the centre. The centre is solid at
## every setting, so a one-pixel brush still paints at any sharpness.
@export var sharpness: float = 1.0

## Identifies this stroke in the list and on the preview.
##
## Random, and stored rather than derived from the row index: a colour computed from
## position would change the moment a stroke above it was removed, and the path you were
## looking at on the preview would appear to become a different one.
@export var color: Color = Color.WHITE

## Off excludes this stroke from the run without losing its path. It still draws on the
## preview when selected, so a stroke can be tried and untried without being redrawn.
@export var enabled: bool = true

## See [IWAlphaMode]. Subtract erases along the path; Add paints it solid.
@export var mode: int = IWAlphaMode.Mode.SUBTRACT


func _init() -> void:
    # Assigned here as well as inline, so a stroke duplicated for another image cannot
    # end up sharing the array the original was built with.
    points = []


## A stroke with a fresh random swatch, at the brush the tool is currently set to.
static func create(with_radius: int, with_sharpness: float) -> BrushStroke:
    var stroke := BrushStroke.new()
    stroke.color = Color.from_hsv(randf(), _SWATCH_SATURATION, _SWATCH_VALUE)
    stroke.radius = clampi(with_radius, MIN_RADIUS, MAX_RADIUS)
    stroke.sharpness = clampf(with_sharpness, 0.0, 1.0)
    return stroke


func size() -> int:
    return points.size()


func is_empty() -> bool:
    return points.is_empty()


## Whether this puts any paint down. One point is a click and a click is one dab, so
## unlike a polygon there is no minimum beyond having been started at all.
func is_drawable() -> bool:
    return not points.is_empty()


## Whether this should affect the image. Drawable and switched on.
func is_active() -> bool:
    return enabled and is_drawable()


## Appends a point, unless it repeats the one before it.
##
## Returns whether anything was added, so a caller redrawing the row can skip the work
## when the pointer has not left the pixel it was already on. A drag reports motion far
## more often than it crosses a pixel boundary, and at low zoom most of those events land
## on the same pixel.
func extend(at: Vector2i) -> bool:
    if not points.is_empty() and points[points.size() - 1] == at:
        return false
    points.append(at)
    return true


## Smallest rectangle containing every point, ignoring the brush width, or an empty one
## when there are none.
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


## An independent copy, so two images never share one stroke.
func duplicate_stroke() -> BrushStroke:
    var copy := BrushStroke.new()
    copy.points = points.duplicate()
    copy.radius = radius
    copy.sharpness = sharpness
    copy.color = color
    copy.enabled = enabled
    copy.mode = mode
    return copy
