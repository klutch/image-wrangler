@tool
class_name IWCommand
extends RefCounted

## One reversible edit to an image's operation stack.
##
## [b]It records the state either side of the edit rather than the edit itself.[/b] The
## classic command holds an intent — "set thickness to 4", "move stage 2 above stage 1" —
## and reverses it by inverting that intent. This one holds the stack as it was and as it
## became, and reverses by putting the old one back.
##
## That is the right trade here for one reason: the dock has no single place where an
## intent exists. A setting arrives through a generated control that knows only a property
## name, an island arrives through a list control that rewrote a nested Resource, and a
## drawn polygon arrives through a session that touched several at once. Writing an
## intent-carrying command per route would mean a class per control, and — worse — every
## operation added later would have to remember to add its own. The whole premise of this
## addon is that a new operation needs no plumbing beyond itself, and a history that
## silently missed the edits of an operation nobody wired up would break that promise in
## the least visible way possible.
##
## What it costs is memory: a few kilobytes a command, against a stack that holds a
## thousand. What it buys is that nothing can be missed.
##
## [param before] and [param after] are encoded stack records — the same shape
## [method IWSettingsIO.encode_stack] writes into a sidecar — so nothing here holds a
## live [Resource] and no amount of later editing can reach back into a recorded state.

## What the History tab calls this, in the imperative: "Add Remove Lines", "Thickness 1 →
## 4". Worked out by whoever built the command, from the difference between the two
## states.
var label := ""

## Which consecutive edits are the same gesture, or [code]&""[/code] for one that is
## never merged.
##
## A slider dragged across its range emits a change per pixel of travel, and a thousand of
## those would be the entire history. Two commands sharing a key, arriving close enough
## together, are folded into one — see [method absorb] and [member IWHistory.MERGE_WINDOW_MSEC].
var merge_key := &""

## When this was recorded, for the merge window. Milliseconds since engine start.
var at_msec := 0

var before: Array = []
var after: Array = []

## Called with a state to put the stack into. Supplied by the dock, which is the only
## thing that knows how to rebuild a form from records.
var _apply := Callable()


func _init(command_label: String, key: StringName, from: Array, to: Array,
		applier: Callable) -> void:
	label = command_label
	merge_key = key
	before = from
	after = to
	_apply = applier
	at_msec = Time.get_ticks_msec()


## Puts the stack into the state this edit produced.
func execute() -> void:
	if _apply.is_valid():
		_apply.call(after)


## Puts the stack back into the state this edit found.
func undo() -> void:
	if _apply.is_valid():
		_apply.call(before)


## Folds a later edit of the same gesture into this one.
##
## The result reads as one edit from where the gesture started to where it ended: this
## keeps its own [member before] and takes the newer [member after].
##
## [b]It takes the newer label, and that is only right because of where the label came
## from.[/b] The dock asks [method IWHistory.mergeable_top] before it describes anything,
## and describes the change against [i]this[/i] command's [member before] when there is
## one — so a drag from 1 to 5 through 4 reads "Thickness 1 → 5" rather than "4 → 5".
## Describing first and merging afterwards would give the last step's label to the whole
## gesture, which is the wrong number in the place a reader is most likely to trust it.
##
## [member at_msec] moves forward too, so a slow drag keeps merging for as long as it
## keeps moving rather than for a fixed time from when it started.
func absorb(newer: IWCommand) -> void:
	after = newer.after
	label = newer.label
	at_msec = newer.at_msec
