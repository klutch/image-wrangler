@tool
class_name RemoveColorList
extends Resource

## The background colours [RemoveBackground] keys out, in the order they are
## tried.
##
## A Resource rather than a bare [code]Array[RemoveColorEntry][/code] for the same
## reason [IslandList] is one: the dock swaps it as a unit when the selected image
## changes, and wrapping it leaves room to grow without changing the shape of the
## settings that hold it.
##
## Order is what settles a pixel two entries could both claim — the first match
## wins. That makes the list read top to bottom like the rules it is, rather than
## depending on which entry happens to fit more tightly.

@export var entries: Array[RemoveColorEntry] = []


func _init() -> void:
	# Assigned here as well as inline, so a settings Resource duplicated for
	# another image cannot end up sharing the array the original was built with.
	entries = []


func size() -> int:
	return entries.size()


func is_empty() -> bool:
	return entries.is_empty()


func get_at(index: int) -> RemoveColorEntry:
	if index < 0 or index >= entries.size():
		return null
	return entries[index]


## Appends an entry for [param color] and returns it.
func add(color: Color, tolerance := RemoveColorEntry.DEFAULT_TOLERANCE) -> RemoveColorEntry:
	var entry := RemoveColorEntry.new()
	entry.color = color
	entry.color_tolerance = tolerance
	entries.append(entry)
	return entry


## Index of the first entry holding [param color], or -1. Compared on the colour
## alone, since that is what makes a second entry redundant — two tolerances for
## one colour would just mean the first always wins.
func find_color(color: Color) -> int:
	for i in entries.size():
		if entries[i] != null and entries[i].color.is_equal_approx(color):
			return i
	return -1


func remove_at(index: int) -> void:
	if index < 0 or index >= entries.size():
		return
	entries.remove_at(index)


func clear() -> void:
	entries.clear()


## Replaces the whole list with a single entry for [param color].
func set_only(color: Color, tolerance := RemoveColorEntry.DEFAULT_TOLERANCE) -> void:
	clear()
	add(color, tolerance)


## A copy sharing none of its entries.
##
## [method Resource.duplicate] copies the array's *references*, so without this
## two settings Resources would hold different lists pointing at the same entries
## and editing a tolerance on one would move it on the other.
##
## Named around the colours rather than the copying because [method
## Resource.duplicate_deep] already exists and takes a mode argument, and an
## override has to match its parent's signature.
func duplicate_colors() -> RemoveColorList:
	var copy := RemoveColorList.new()
	for entry in entries:
		if entry != null:
			copy.entries.append(entry.duplicate_entry())
	return copy
