@tool
class_name IWHistory
extends RefCounted

## One image's undo history: a list of [IWCommand]s and a pointer into it.
##
## [b]Session-only, and one of these per image.[/b] It is never written to a sidecar —
## what an image's settings [i]are[/i] belongs on disk, how they got that way does not,
## and a history that outlived the session would be a record of edits made against an
## image that may since have been changed by something else entirely.
##
## The pointer is what makes rewinding and fast-forwarding the same operation. Everything
## up to and including [member _current] has been applied; everything after it has been
## undone but is still there to go back to. Recording a new command at a rewound pointer
## is what finally throws that future away — see [method record].

## How many commands are kept. The oldest is dropped past this, and the state it left
## behind becomes the new starting point.
const MAX_COMMANDS := 1000

## How close together two edits of the same gesture have to be to become one.
##
## Six hundred milliseconds is long enough that a slider dragged in fits stays one edit
## and short enough that going back to the same control after looking at the preview
## starts a new one. It is measured from the last edit rather than the first, so a slow
## drag does not split halfway down its travel.
const MERGE_WINDOW_MSEC := 600

## The row index that means the state before any recorded command.
const BASE_INDEX := -1

signal changed

var _commands: Array[IWCommand] = []

## Index of the last applied command, or [constant BASE_INDEX] for the state before all
## of them.
var _current := BASE_INDEX

## The state undoing everything arrives back at.
var _base: Array = []

## What the first row is called. Stops being "Opened" once the cap has thrown the real
## opening state away, because at that point it would be a lie.
var _base_label := "Opened"


## Records the state this history starts from. Called once, when the image is first shown.
func seed(state: Array) -> void:
	_base = state
	_commands.clear()
	_current = BASE_INDEX
	_base_label = "Opened"
	changed.emit()


## The command a new edit with this key would be folded into, or null for one that starts
## a fresh entry.
##
## Asked by the dock [i]before[/i] it describes the edit, so the description can be made
## against where the gesture began rather than where its last step did. See
## [method IWCommand.absorb].
func mergeable_top(key: StringName, at_msec: int) -> IWCommand:
	if key.is_empty() or _current < 0 or _current != _commands.size() - 1:
		return null
	var top := _commands[_current]
	if top.merge_key != key or at_msec - top.at_msec > MERGE_WINDOW_MSEC:
		return null
	return top


## Adds [param command] as the newest entry, or folds it into the one it continues.
##
## [b]Recording at a rewound pointer throws the future away.[/b] That is not a policy
## choice so much as the only coherent answer: the commands after the pointer describe
## edits to a state that no longer exists, and keeping them would mean offering to
## fast-forward through a history whose first step could not be applied.
##
## The command is assumed to have already happened — the dock records what it observes
## rather than asking this to carry it out — so nothing is executed here.
func record(command: IWCommand) -> void:
	var top := mergeable_top(command.merge_key, command.at_msec)
	if top != null:
		top.absorb(command)
		changed.emit()
		return

	if _current + 1 < _commands.size():
		_commands.resize(_current + 1)
	_commands.append(command)
	_current = _commands.size() - 1
	_trim()
	changed.emit()


## Moves to [param index], applying or reversing each command in between.
##
## One step at a time, deliberately. Jumping straight to the target state would land in
## the same place by every measure this addon can take — the states are exact — but a
## command that is only ever skipped past is a command nobody would notice had stopped
## working, and undo is not a thing to find out about late.
func go_to(index: int) -> void:
	var target := clampi(index, BASE_INDEX, _commands.size() - 1)
	if target == _current:
		return
	while _current > target:
		_commands[_current].undo()
		_current -= 1
	while _current < target:
		_commands[_current + 1].execute()
		_current += 1
	changed.emit()


func current_index() -> int:
	return _current


func size() -> int:
	return _commands.size()


## Every row the History tab shows, oldest first.
##
## Each is [code]{"index": int, "label": String, "future": bool}[/code], where a future
## row is one that has been undone and is still there to go back to. Row zero is the
## starting state and carries [constant BASE_INDEX].
func rows() -> Array:
	var out := [{"index": BASE_INDEX, "label": _base_label, "future": false}]
	for i in _commands.size():
		out.append({"index": i, "label": _commands[i].label, "future": i > _current})
	return out


## The state at the pointer, for the dock to compare a fresh edit against.
func current_state() -> Array:
	return _base if _current < 0 else _commands[_current].after


## Drops the oldest commands until the cap is met.
##
## The starting state moves forward with them: undoing everything now arrives at whatever
## the oldest surviving command found rather than at how the image opened, and the first
## row says so rather than keeping a name it no longer earns.
func _trim() -> void:
	while _commands.size() > MAX_COMMANDS:
		_base = _commands[0].after
		_commands.remove_at(0)
		_current -= 1
		_base_label = "Earlier edits dropped"
