@tool
class_name Pivot
extends Resource

## One sprite's pivot on a packed sheet: where it turns, and which way it faces.
##
## Held against the sprite's own rectangle rather than against the sheet, so a repack that
## moves every sprite leaves these where they were. The lookup table adds the rectangle back
## on; see [method IWPacking.build_lookup_image].

## Which way a sprite faces when nothing has said otherwise.
##
## [b]Y points up here[/b], the opposite way round from image coordinates, so this is
## straight up the sheet. [method as_image_vector] flips it back for drawing.
const DEFAULT_DIRECTION := Vector2(0, 1)

## Which sprite this belongs to, by the number the lookup table gives it.
@export var sprite: int = -1

## Where the pivot sits inside that sprite's rectangle, in pixels from its top-left corner.
@export var offset: Vector2 = Vector2.ZERO

## Which way the sprite faces, as a unit vector. See [constant DEFAULT_DIRECTION] for which
## way round Y runs.
@export var direction: Vector2 = DEFAULT_DIRECTION

## Whether this entry is used. Off leaves it on the list and gives the sprite the middle of
## its rectangle facing [constant DEFAULT_DIRECTION] back.
@export var enabled: bool = true


static func create(for_sprite: int, at: Vector2, facing: Vector2) -> Pivot:
    var pivot := Pivot.new()
    pivot.sprite = for_sprite
    pivot.offset = at
    pivot.direction = sanitise_direction(facing)
    return pivot


## [param facing] as a unit vector, or [constant DEFAULT_DIRECTION] when it has no length —
## which is what a click that never moved gives.
static func sanitise_direction(facing: Vector2) -> Vector2:
    return facing.normalized() if facing.length_squared() > 0.0 else DEFAULT_DIRECTION


## A drag measured in image pixels as a direction to store.
##
## Y is flipped, because a drag upwards on screen is a fall in image coordinates and up is
## what it means.
static func direction_from(delta: Vector2) -> Vector2:
    return sanitise_direction(Vector2(delta.x, -delta.y))


## A stored direction back the way image coordinates run, for drawing it over the sheet.
static func as_image_vector(facing: Vector2) -> Vector2:
    return Vector2(facing.x, -facing.y)


## Where [param facing] points as a compass bearing in degrees: zero straight up, rising
## clockwise. For naming a pivot on its row.
static func bearing_of(facing: Vector2) -> float:
    return fposmod(rad_to_deg(atan2(facing.x, facing.y)), 360.0)


func duplicate_pivot() -> Pivot:
    var copy := create(sprite, offset, direction)
    copy.enabled = enabled
    return copy
