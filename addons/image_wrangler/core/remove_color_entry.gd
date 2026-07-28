@tool
class_name RemoveColorEntry
extends Resource

## One background [RemoveBackground] keys out: a group of colours, each with the
## tolerance that belongs to it. See [RemoveColorSample].
##
## Was a single colour until picking became a gesture rather than a click. Sweeping a
## rectangle over a background samples what is actually there, and what is actually
## there is rarely one value — a scanned white is a cloud of near-whites, a
## re-compressed flat panel is a dozen colours that all look like one. Making that one
## row rather than a dozen is the point: the thing the user pointed at was a
## background, and switching it off, or loosening it, is something they mean for all
## of it.
##
## A single picked pixel is the same thing one colour wide, which keeps the old
## behaviour intact rather than special-cased: an entry of one sample is exactly the
## Remove Color this class used to be.

## Widest tolerance offered. The max-channel metric this is compared against
## cannot exceed 1.0, and half of that already keys out most of any image.
##
## Kept here rather than beside [constant RemoveColorSample.DEFAULT_TOLERANCE] because
## it is not this list's number: it is the ceiling every tolerance in the addon is
## clamped and drawn against, islands included.
const MAX_TOLERANCE := 0.5

## The colours this entry keys out. Never empty for an entry the list built — see
## [method RemoveColorList.add_region] — which is what lets [method migrate_legacy]
## read an empty list as "written before an entry was a group".
@export var samples: Array[RemoveColorSample] = []

## Off excludes this entry from the run without losing it, so a tolerance worth
## keeping can be set aside and brought back rather than retyped.
@export var enabled: bool = true

## Read only, and only from files written before an entry became a group of colours.
## [method migrate_legacy] folds them into [member samples].
##
## Exported because the codec reflects over storage properties and would not see them
## otherwise, which would mean quietly dropping every colour anyone had listed before
## the format changed.
@export var color: Color = Color.WHITE
@export var color_tolerance: float = RemoveColorSample.DEFAULT_TOLERANCE


func _init() -> void:
	# Assigned here as well as inline, so an entry duplicated for another image
	# cannot end up sharing the array the original was built with.
	samples = []


## Folds a legacy [member color] into [member samples], newest format wins.
##
## Samples already present mean the file was written in the new format and the legacy
## pair is either absent or stale, so it is discarded rather than appended.
func migrate_legacy() -> void:
	if not samples.is_empty():
		return
	add_sample(color, color_tolerance)


func size() -> int:
	return samples.size()


func is_empty() -> bool:
	return samples.is_empty()


func get_sample(index: int) -> RemoveColorSample:
	if index < 0 or index >= samples.size():
		return null
	return samples[index]


## Drops the sample at [param index].
##
## Emptying an entry this way is the caller's problem to notice rather than this
## method's to prevent: an entry with no samples keys nothing out, and
## [method migrate_legacy] would read it on the next load as a file written before
## entries were groups and quietly put [member color] back. Whoever removes the last
## one should remove the entry.
func remove_sample(index: int) -> void:
	if index < 0 or index >= samples.size():
		return
	samples.remove_at(index)


## Appends a sample for [param value] and returns it.
func add_sample(value: Color, tolerance: float) -> RemoveColorSample:
	var sample := RemoveColorSample.new()
	sample.color = value
	sample.color_tolerance = tolerance
	samples.append(sample)
	return sample


## The sample that stands for the group, for the row swatch: the first, which for a
## swept region is the colour most of that region was. See [method IWRegionScan.colors_in].
func representative() -> RemoveColorSample:
	return get_sample(0)


## The tolerance every sample shares, or -1.0 when they differ.
##
## The group editor needs to say which of the two it is looking at: writing one number
## into a control that is really showing several would let a stray click flatten
## tolerances the user set colour by colour.
func shared_tolerance() -> float:
	if samples.is_empty():
		return RemoveColorSample.DEFAULT_TOLERANCE
	var first := samples[0].color_tolerance
	for sample in samples:
		if sample != null and not is_equal_approx(sample.color_tolerance, first):
			return -1.0
	return first


## Writes [param value] into every sample.
func set_tolerance(value: float) -> void:
	for sample in samples:
		if sample != null:
			sample.color_tolerance = value


## Whether any sample here holds [param value].
func has_color(value: Color) -> bool:
	for sample in samples:
		if sample != null and sample.color.is_equal_approx(value):
			return true
	return false


## An independent copy, so two images never share one entry.
func duplicate_entry() -> RemoveColorEntry:
	var copy := RemoveColorEntry.new()
	copy.enabled = enabled
	# The legacy pair travels too. It is dead weight on an entry that has been
	# migrated, and the only thing an entry that has not carries.
	copy.color = color
	copy.color_tolerance = color_tolerance
	for sample in samples:
		if sample != null:
			copy.samples.append(sample.duplicate_sample())
	return copy
