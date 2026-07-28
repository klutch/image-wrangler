@tool
class_name IslandEntry
extends Resource

## One region picked off the preview, and what it does to the alpha inside it.
##
## Was a bare [Vector2i], then a point with a switch and a mode, and is now a group:
## a list of [IslandPick]s — one per pixel of the rectangle that was dragged, each
## with a tolerance of its own — under one switch and one mode.
##
## [b]Grouped rather than flattened[/b] because a region is one decision. A forty by
## forty drag names sixteen hundred places a flood may start, and sixteen hundred rows
## in the dock would be unusable: what the user switches off, or turns from Subtract to
## Add, is the patch they drew, not its nine-hundredth pixel. Every pick still carries
## its own tolerance, so the group is a convenience over the picks rather than a lid on
## them.
##
## A single click is the same thing one pixel wide, which is what keeps the old
## behaviour intact rather than special-cased: an entry of one pick is exactly the
## island this class used to be.

## Every pixel this island seeds from. Never empty for an entry the picker built —
## see [method IslandList.add_region] — which is what lets [method migrate_legacy]
## read an empty list as "written before islands were groups".
@export var picks: Array[IslandPick] = []

## Off excludes this entry without losing where it was, so a pick can be tried
## and untried without being picked again.
@export var enabled: bool = true

## See [IWAlphaMode]. Subtract floods the region away; Add floods the same region
## and forces it opaque instead.
##
## On the group rather than on each pick, because a region drawn in one gesture is
## one intention. Wanting half a rectangle removed and the other half protected is
## two rectangles.
@export var mode: int = IWAlphaMode.Mode.SUBTRACT

## Read only, and only from files written before an island became a group of pixels.
## [method migrate_legacy] folds them into [member picks].
##
## Exported for the same reason [member IslandList.points] is: the codec reflects over
## storage properties and would not see them otherwise, which would mean quietly
## dropping every island anyone had picked before the format changed.
@export var point: Vector2i = Vector2i.ZERO
@export var color_tolerance: float = IslandPick.DEFAULT_TOLERANCE


func _init() -> void:
	# Assigned here as well as inline, so an entry duplicated for another image
	# cannot end up sharing the array the original was built with.
	picks = []


## Folds a legacy [member point] into [member picks], newest format wins.
##
## Picks already present mean the file was written in the new format and the legacy
## point is either absent or stale, so it is discarded rather than appended. The
## picker never builds an empty group, so an empty list here can only mean an older
## file.
func migrate_legacy() -> void:
	if not picks.is_empty():
		return
	add_pick(point, color_tolerance)


func size() -> int:
	return picks.size()


func is_empty() -> bool:
	return picks.is_empty()


func get_pick(index: int) -> IslandPick:
	if index < 0 or index >= picks.size():
		return null
	return picks[index]


## Appends a pick at [param at] and returns it.
func add_pick(at: Vector2i, tolerance: float) -> IslandPick:
	var pick := IslandPick.new()
	pick.point = at
	pick.color_tolerance = tolerance
	picks.append(pick)
	return pick


## The rectangle this island covers, or a zero-sized one when it holds nothing.
##
## The picker builds picks in reading order across a rectangle, so this is the
## rectangle that was dragged — including when a cap thinned the picks inside it, since
## the first and last row and column are always kept. It is what the list row names and
## what the preview outlines.
func bounds() -> Rect2i:
	if picks.is_empty():
		return Rect2i()
	var from := picks[0].point
	var to := from
	for pick in picks:
		if pick == null:
			continue
		from.x = mini(from.x, pick.point.x)
		from.y = mini(from.y, pick.point.y)
		to.x = maxi(to.x, pick.point.x)
		to.y = maxi(to.y, pick.point.y)
	return Rect2i(from, to - from + Vector2i.ONE)


## The pick that best stands for the group, for the row swatch: the one nearest the
## middle of the list, which for a rectangle built in reading order is near the middle
## of the rectangle. A corner pixel is the one most likely to have caught the edge the
## user was dragging past.
func representative() -> IslandPick:
	@warning_ignore("integer_division")
	return get_pick(picks.size() / 2)


## The tolerance every pick shares, or -1.0 when they differ.
##
## The group editor needs to say which of the two it is looking at: writing one number
## into a control that is really showing several would let a stray click flatten
## tolerances the user set pick by pick.
func shared_tolerance() -> float:
	if picks.is_empty():
		return IslandPick.DEFAULT_TOLERANCE
	var first := picks[0].color_tolerance
	for pick in picks:
		if pick != null and not is_equal_approx(pick.color_tolerance, first):
			return -1.0
	return first


## Writes [param value] into every pick.
func set_tolerance(value: float) -> void:
	for pick in picks:
		if pick != null:
			pick.color_tolerance = value


## Whether [param at] falls inside [method bounds].
##
## Containment rather than an exact pick, because the list is about regions now: a
## click inside a rectangle already picked is a request to look at that entry, not a
## request for a second one. For a single-pick island the two readings coincide, which
## is what keeps a repeated click behaving exactly as it always did.
func covers(at: Vector2i) -> bool:
	var box := bounds()
	return box.size.x > 0 and box.size.y > 0 and box.has_point(at)


## An independent copy, so two images never share one entry.
func duplicate_entry() -> IslandEntry:
	var copy := IslandEntry.new()
	copy.enabled = enabled
	copy.mode = mode
	# The legacy pair travels too. It is dead weight on an entry that has been
	# migrated, and the only thing an entry that has not carries.
	copy.point = point
	copy.color_tolerance = color_tolerance
	for pick in picks:
		if pick != null:
			copy.picks.append(pick.duplicate_pick())
	return copy
