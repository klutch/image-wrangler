@tool
class_name IslandList
extends Resource

## Image regions the user picked off the preview, each standing for an area an
## operation should act on. See [IslandEntry].
##
## A Resource rather than a bare array so that it can be swapped as a unit when
## the dock changes image, and so per-island data can be added without changing
## the shape of the settings that hold it — which is exactly what happened when a
## pick grew an on/off switch and a mode, and again when it grew from one pixel
## into a dragged rectangle.

## Most picks one dragged region may hold.
##
## A cap rather than a promise to store every pixel, because there is nothing to stop
## a drag covering the whole image: a thousand by thousand rectangle is a million
## picks, which is a megabyte of sidecar per island and a list the dock cannot draw.
## Past the cap the rectangle is sampled on an even stride instead — see
## [method add_region] — which loses nothing a flood would have found, since a seed
## only has to land inside a region rather than on every pixel of it.
##
## Sized so that anything up to sixty-four by sixty-four is stored pixel for pixel,
## which covers the eyes, gaps and highlights this tool is actually pointed at.
const MAX_PICKS := 4096

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


## Folds any legacy [member points] into [member entries], newest format wins, and
## gives every entry the same chance to fold a legacy point of its own.
##
## Called after a settings Resource is decoded. Entries already present mean the
## file was written in the new format and the legacy array is either absent or
## stale, so it is discarded rather than appended.
func migrate_legacy() -> void:
	if not points.is_empty():
		if entries.is_empty():
			for point in points:
				add(point)
		points = []
	# Two formats back the entries themselves were single points. An entry decoded
	# from such a file has no picks, and nothing else would notice.
	for entry in entries:
		if entry != null:
			entry.migrate_legacy()


func size() -> int:
	return entries.size()


func is_empty() -> bool:
	return entries.is_empty()


func get_at(index: int) -> IslandEntry:
	if index < 0 or index >= entries.size():
		return null
	return entries[index]


## Index of the first entry covering [param at], or -1. See [method IslandEntry.covers].
func find(at: Vector2i) -> int:
	for i in entries.size():
		if entries[i] != null and entries[i].covers(at):
			return i
	return -1


func has(at: Vector2i) -> bool:
	return find(at) >= 0


## Appends an entry holding the single pixel [param at] and returns it.
func add(at: Vector2i) -> IslandEntry:
	return add_region(Rect2i(at, Vector2i.ONE))


## Appends an entry covering [param region] and returns it.
##
## Every pixel of the rectangle becomes a pick, up to [constant MAX_PICKS]; past that
## the rectangle is walked on an even stride wide enough to fit. See [IWRegionScan],
## which is also what the Remove Colors list sweeps a region with, so the two pickers
## cannot come to different conclusions about the same gesture.
##
## The entry starts on the same mode and tolerance as the one before it. Picking
## islands is repetitive work — several regions in one image, wanted the same way —
## and setting the same two controls again after every gesture is exactly the sort
## of thing the list should remember for you. The first entry has nothing to
## follow and takes the defaults.
func add_region(region: Rect2i) -> IslandEntry:
	var entry := IslandEntry.new()
	var tolerance := IslandPick.DEFAULT_TOLERANCE
	var previous := get_at(entries.size() - 1)
	if previous != null:
		entry.mode = previous.mode
		# A group the user has since tuned pick by pick has no one tolerance to
		# inherit, so the new entry falls back to the one it shows for that group.
		var inherited := previous.shared_tolerance()
		tolerance = inherited if inherited >= 0.0 else previous.representative().color_tolerance

	if region.size.x > 0 and region.size.y > 0:
		var step := IWRegionScan.stride_for(region, MAX_PICKS)
		var xs := IWRegionScan.stops(region.position.x, region.size.x, step)
		var ys := IWRegionScan.stops(region.position.y, region.size.y, step)
		# Reading order, so the middle of the list is the middle of the rectangle;
		# see [method IslandEntry.representative].
		for y in ys:
			for x in xs:
				entry.add_pick(Vector2i(x, y), tolerance)

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
