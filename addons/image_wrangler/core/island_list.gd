@tool
class_name IslandList
extends Resource

## Image positions the user picked off the preview, each standing for a region an
## operation should act on. See [IslandEntry].
##
## A Resource rather than a bare array so that it can be swapped as a unit when
## the dock changes image, and so per-island data can be added without changing
## the shape of the settings that hold it — which is exactly what happened when a
## pick grew an on/off switch and an add/subtract mode.

@export var entries: Array[IslandEntry] = []

## Read only, and only from files written before islands carried anything but a
## position. [method migrate_legacy] empties it into [member entries].
##
## Exported because the codec reflects over storage properties and would not see
## it otherwise, which would mean quietly dropping every island anyone had picked
## before the format changed.
@export var points: Array[Vector2i] = []


func _init() -> void:
	# Assigned here as well as inline, so a settings Resource duplicated for
	# another image cannot end up sharing the array the original was built with.
	entries = []
	points = []


## Folds any legacy [member points] into [member entries], newest format wins.
##
## Called after a settings Resource is decoded. Entries already present mean the
## file was written in the new format and the legacy array is either absent or
## stale, so it is discarded rather than appended.
func migrate_legacy() -> void:
	if points.is_empty():
		return
	if entries.is_empty():
		for point in points:
			add(point)
	points = []


func size() -> int:
	return entries.size()


func is_empty() -> bool:
	return entries.is_empty()


func get_at(index: int) -> IslandEntry:
	if index < 0 or index >= entries.size():
		return null
	return entries[index]


## Index of the first entry at [param at], or -1. Compared on position alone,
## since that is what makes a second pick there redundant.
func find(at: Vector2i) -> int:
	for i in entries.size():
		if entries[i] != null and entries[i].point == at:
			return i
	return -1


func has(at: Vector2i) -> bool:
	return find(at) >= 0


## Appends an entry at [param at] and returns it.
##
## It starts on the same mode and tolerance as the entry before it. Picking
## islands is repetitive work — several spots in one image, wanted the same way —
## and setting the same two controls again after every click is exactly the sort
## of thing the list should remember for you. The first entry has nothing to
## follow and takes the defaults.
func add(at: Vector2i) -> IslandEntry:
	var entry := IslandEntry.new()
	entry.point = at
	var previous := get_at(entries.size() - 1)
	if previous != null:
		entry.mode = previous.mode
		entry.color_tolerance = previous.color_tolerance
	entries.append(entry)
	return entry


func remove_at(index: int) -> void:
	if index < 0 or index >= entries.size():
		return
	entries.remove_at(index)


func clear() -> void:
	entries.clear()


## A copy sharing none of its entries.
##
## [method Resource.duplicate] copies the array's *references*, so without this
## two settings Resources would hold different lists pointing at the same entries
## and switching one off would switch it off on both.
func duplicate_islands() -> IslandList:
	var copy := IslandList.new()
	for entry in entries:
		if entry != null:
			copy.entries.append(entry.duplicate_entry())
	return copy
