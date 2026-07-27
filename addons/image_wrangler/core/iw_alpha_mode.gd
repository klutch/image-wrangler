@tool
class_name IWAlphaMode
extends RefCounted

## Which way a picked island or a drawn region moves alpha.
##
## Its own file because two unrelated resources need the same enum and the same
## labels, and having either of them own it would make the other depend on
## something it has no other business with.

enum Mode {
	## Make the affected area transparent. What both tools were before there was
	## a choice, and still the default: removing is the job.
	SUBTRACT,
	## Make the affected area opaque, whatever the keying decided. The way back
	## from a tolerance that ate something it should not have.
	ADD,
}

## Dropdown labels, in enum order.
const LABELS := ["Subtract", "Add"]


## [param mode] pulled back into range, for a value that came from a hand-edited
## file rather than from the dropdown.
static func sanitise(mode: int) -> int:
	return mode if mode == Mode.ADD else Mode.SUBTRACT
