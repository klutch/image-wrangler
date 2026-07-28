@tool
class_name RemoveColorList
extends Resource

## The backgrounds [RemoveBackground] keys out, in the order they are tried. Each
## entry is a group of colours; see [RemoveColorEntry].
##
## A Resource rather than a bare [code]Array[RemoveColorEntry][/code] for the same
## reason [IslandList] is one: the dock swaps it as a unit when the selected image
## changes, and wrapping it leaves room to grow without changing the shape of the
## settings that hold it.
##
## Order is what settles a pixel two colours could both claim — the first match
## wins. That makes the list read top to bottom like the rules it is, rather than
## depending on which entry happens to fit more tightly.

## Most colours one swept region may contribute.
##
## Tighter than the island picker's cap, and for a reason that has nothing to do with
## storage: every enabled sample becomes a key, and [method IWPipelineContext.claiming_key]
## walks every key for every pixel it cannot place. Island keys are skipped there and
## these are not — they are the rules — so a colour costs a pass over the image in a way
## a picked pixel does not. Sixty-four is already far more than any real background
## needs once [method add_region] has thinned them.
##
## The colours that survive the cap are the ones most of the region actually was, since
## [method IWRegionScan.colors_in] hands them over most common first.
const MAX_SAMPLES := 64

## Most pixels a swept region is read at, before it is walked on an even stride
## instead. Sized like the island picker's, so a rectangle up to sixty-four by
## sixty-four is read pixel for pixel.
##
## Distinct from [constant MAX_SAMPLES]: this bounds how long looking takes, that
## bounds how much of what was found is kept.
const SCAN_BUDGET := 4096

@export var entries: Array[RemoveColorEntry] = []


func _init() -> void:
	# Assigned here as well as inline, so a settings Resource duplicated for
	# another image cannot end up sharing the array the original was built with.
	entries = []


## Gives every entry the chance to fold a legacy colour of its own.
##
## Called after a settings Resource is decoded. An entry written before entries were
## groups has no samples, and nothing else would notice.
func migrate_legacy() -> void:
	for entry in entries:
		if entry != null:
			entry.migrate_legacy()


func size() -> int:
	return entries.size()


func is_empty() -> bool:
	return entries.is_empty()


func get_at(index: int) -> RemoveColorEntry:
	if index < 0 or index >= entries.size():
		return null
	return entries[index]


## Appends an entry holding the single colour [param color] and returns it.
func add(color: Color, tolerance := RemoveColorSample.DEFAULT_TOLERANCE) -> RemoveColorEntry:
	var entry := RemoveColorEntry.new()
	entry.add_sample(color, tolerance)
	entries.append(entry)
	return entry


## Appends an entry holding whichever of [param colors] this list does not already key
## out, and returns it — or [code]null[/code] when it already keyed out all of them.
##
## [b]Thinned, not stored wholesale.[/b] A swept region hands over every distinct
## colour it found, which for anything photographic is thousands; but a colour within
## another's tolerance can never claim a pixel that other one did not already claim, so
## keeping it would be writing the same rule twice at the cost of a pass over the image
## per pixel it fails to place. What survives is a set of colours no two of which are
## within [param tolerance] of each other — which for a flat background is one, and for
## a speckled or re-compressed one is a handful.
##
## The thinning is done against the rest of the list as well, each existing sample by
## its own tolerance, so sweeping the same background twice adds nothing the second
## time rather than a second copy of it.
##
## One consequence worth knowing: the thinning happens at the tolerance the samples
## start on. Tightening a group afterwards can leave gaps between colours that were
## covered when it was picked, and the answer is to sweep it again rather than to
## widen it back.
func add_region(colors: PackedColorArray, tolerance := RemoveColorSample.DEFAULT_TOLERANCE) -> RemoveColorEntry:
	var kept := PackedColorArray()
	for value in colors:
		if kept.size() >= MAX_SAMPLES:
			break
		if claims(value):
			continue
		if _covered_by(value, kept, tolerance):
			continue
		kept.append(value)
	if kept.is_empty():
		return null

	var entry := RemoveColorEntry.new()
	for value in kept:
		entry.add_sample(value, tolerance)
	entries.append(entry)
	return entry


## Whether anything already listed keys [param color] out, each sample judged by its
## own tolerance.
##
## Switched-off entries count. They are still in the list and still describe what the
## user meant; adding a duplicate of one because it happens to be set aside would leave
## a colour that reappears from nowhere when the entry is switched back on.
func claims(color: Color) -> bool:
	for entry in entries:
		if entry == null:
			continue
		for sample in entry.samples:
			if sample != null and RemoveColorSample.distance(sample.color, color) <= sample.color_tolerance:
				return true
	return false


## Whether [param color] is within [param tolerance] of anything in [param kept].
static func _covered_by(color: Color, kept: PackedColorArray, tolerance: float) -> bool:
	for other in kept:
		if RemoveColorSample.distance(other, color) <= tolerance:
			return true
	return false


## Index of the first entry holding [param color] exactly, or -1.
##
## Exact rather than within tolerance, unlike [method claims]: this answers "which row
## is that colour on", which is what a repeated pick needs so it can highlight the row
## instead of adding a second one saying the same thing.
func find_color(color: Color) -> int:
	for i in entries.size():
		if entries[i] != null and entries[i].has_color(color):
			return i
	return -1


## Index of the first entry keying [param color] out at its own tolerance, or -1.
func find_claiming(color: Color) -> int:
	for i in entries.size():
		if entries[i] == null:
			continue
		for sample in entries[i].samples:
			if sample != null and RemoveColorSample.distance(sample.color, color) <= sample.color_tolerance:
				return i
	return -1


func remove_at(index: int) -> void:
	if index < 0 or index >= entries.size():
		return
	entries.remove_at(index)


func clear() -> void:
	entries.clear()


## Replaces the whole list with a single entry for [param color].
func set_only(color: Color, tolerance := RemoveColorSample.DEFAULT_TOLERANCE) -> void:
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
