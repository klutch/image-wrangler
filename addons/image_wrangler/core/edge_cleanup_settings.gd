@tool
class_name EdgeCleanupSettings
extends Resource

## Every tunable of [EdgeCleanup].
##
## The antialiasing restoration has none of its own and never will: it only touches a
## solid pixel sitting straight against a clear one, so a properly matted edge is
## invisible to it and there is nothing to tune it down with. Everything here belongs
## to the stroke.
##
## Ranges live in [method EdgeCleanup.get_settings_schema], not here.

## Width of the stroke drawn inside the silhouette, in pixels, or zero for none.
##
## Inside means it never extends the shape: it follows interior holes as well as the
## outer contour, and leaves the alpha channel exactly as it found it. Only colour
## changes.
@export var inner_stroke_width: float = 0.5

## Width of the stroke drawn outside the silhouette, in pixels, or zero for none.
##
## The counterpart to [member inner_stroke_width], and unlike it this one [i]adds
## alpha[/i]: outside the shape there is nothing to colour, so the stroke has to bring
## its own. The result is a subject that has grown by this many pixels.
##
## Composited underneath the subject rather than over it, so the shape's own soft edge
## stays on top and the stroke shows through it — which is what an outer stroke looks
## like, and what stops it eating the antialiasing it is meant to sit behind.
@export var outer_stroke_width: float = 0.5

## How soft the stroke's inner edge is, from a hard step at zero to the widest feather
## at one.
##
## Only the inner edge. The outer one is the silhouette itself, and its softness
## belongs to the image's own alpha — feathering it would let the stroke bleed past
## the shape, which is the one thing an inside stroke must not do.
@export var stroke_softness: float = 0.75

## Take the stroke colour from the image rather than from [member stroke_color].
##
## Sampled per pixel from a heavily blurred, alpha-weighted copy of the subject and
## then darkened, so the stroke is a darker relative of whatever it is running
## alongside.
@export var auto_stroke_color: bool = false

## Colour of the inside stroke, alpha included. Ignored while
## [member auto_stroke_color] is on.
##
## The alpha is how strongly it is laid over what is already there rather than how
## transparent the result is — a stroke at half alpha tints the art beneath it, and
## does not make the silhouette half-transparent.
@export var stroke_color: Color = Color(0, 0, 0, 1)


## A copy that belongs to no image. Nothing here is a coordinate and nothing is a
## nested Resource, so the plain duplicate is the whole of it.
func duplicate_for_new_image() -> EdgeCleanupSettings:
	return duplicate()
