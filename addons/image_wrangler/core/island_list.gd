@tool
class_name IslandList
extends Resource

## Image positions the user picked off the preview, each standing for a region an
## operation should act on.
##
## A Resource rather than a bare [code]Array[Vector2i][/code] so that it can be
## swapped as a unit when the dock changes image, and so per-island data — a
## pinned key colour, a label — can be added later without changing the shape of
## the settings that hold it.

@export var points: Array[Vector2i] = []


func _init() -> void:
	# Assigned here as well as inline. A settings Resource duplicated for another
	# image gets a fresh list, and this is the one place that guarantees the
	# fresh one is not still pointing at the array the original was built with.
	points = []


func size() -> int:
	return points.size()


func is_empty() -> bool:
	return points.is_empty()


func has(at: Vector2i) -> bool:
	return points.has(at)


func find(at: Vector2i) -> int:
	return points.find(at)


func add(at: Vector2i) -> void:
	points.append(at)


func remove_at(index: int) -> void:
	if index < 0 or index >= points.size():
		return
	points.remove_at(index)


func clear() -> void:
	points.clear()
