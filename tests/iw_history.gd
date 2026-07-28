extends SceneTree

## The undo history: the command stack, and what each edit ends up called.
##
## Two halves, and they are independent. [IWHistory] and [IWCommand] are a model with no
## opinion about images — they move between recorded states and can be checked exactly.
## The descriptions are the dock's, and are checked by handing it pairs of states directly
## rather than by driving a form, because a form needs an editor and a description does
## not.
##
## [b]What is deliberately not covered here is the capture itself[/b] — that the dock
## notices an edit at all. It hangs off two funnels every edit already passes through, so
## the thing that could break it is a new route into the stack that bypasses both, and no
## headless test can see one of those coming. [method IWPanel._capture_history] carries the
## note explaining why those two are the right hooks.
##
## Everything is reached through [method load] rather than by [code]class_name[/code], so
## this runs before the editor has rescanned the project.
##
## Run it:
## [codeblock]
## godot --headless --path . --script res://tests/iw_history.gd
## [/codeblock]

const CommandScript := preload("res://addons/image_wrangler/core/iw_command.gd")
const HistoryScript := preload("res://addons/image_wrangler/core/iw_history.gd")
const PanelScript := preload("res://addons/image_wrangler/ui/iw_panel.gd")

var _failures := 0

## Stands in for the dock's stack: applying a state just records it here.
var _state: Array = []


func _initialize() -> void:
	_check_tab_order()
	_check_rewind()
	_check_truncation()
	_check_merge()
	_check_cap()
	_check_descriptions()

	if _failures == 0:
		print("History OK — rewind, fast-forward, truncate, merge, the 1000 cap, and "
				+ "every edit reads as what it was.")
	quit(1 if _failures > 0 else 0)


## History sits between Operations and Rename, and the tab index is the mode.
func _check_tab_order() -> void:
	_expect(PanelScript.Mode.IMAGE == 0, "Operations is not tab 0")
	_expect(PanelScript.Mode.HISTORY == 1, "History is not tab 1")
	_expect(PanelScript.Mode.RENAME == 2, "Rename is not tab 2")


# --- Rewind and fast-forward -------------------------------------------

func _check_rewind() -> void:
	var history: RefCounted = HistoryScript.new()
	_state = [_rec("a")]
	history.seed(_state.duplicate(true))

	_push(history, "one", [_rec("a"), _rec("b")])
	_push(history, "two", [_rec("a"), _rec("b"), _rec("c")])
	_push(history, "three", [_rec("a"), _rec("b"), _rec("c"), _rec("d")])

	_expect(history.size() == 3, "recorded %d commands, not 3" % history.size())
	_expect(history.current_index() == 2, "pointer is at %d, not 2" % history.current_index())
	_expect(_state.size() == 4, "state has %d records, not 4" % _state.size())

	history.go_to(0)
	_expect(history.current_index() == 0, "rewind left the pointer at %d" % history.current_index())
	_expect(_state.size() == 2, "rewinding to command 0 gave %d records, not 2" % _state.size())

	# All the way back to the state the image opened in.
	history.go_to(HistoryScript.BASE_INDEX)
	_expect(_state.size() == 1, "rewinding to the base gave %d records, not 1" % _state.size())

	# And forward again, which is the whole point of not throwing the future away.
	history.go_to(2)
	_expect(_state.size() == 4, "fast-forward gave %d records, not 4" % _state.size())
	_expect(history.current_index() == 2, "fast-forward left the pointer at %d"
			% history.current_index())

	history.go_to(0)
	var rows: Array = history.rows()
	_expect(rows.size() == 4, "rows() gave %d, not 4" % rows.size())
	_expect(rows[0]["index"] == HistoryScript.BASE_INDEX, "row 0 is not the base")
	_expect(rows[0]["label"] == "Opened", "the base row is called %s" % rows[0]["label"])
	_expect(not rows[1]["future"], "the current row is flagged as future")
	_expect(rows[2]["future"] and rows[3]["future"], "the undone rows are not flagged")


# --- A new edit at a rewound pointer drops the future -------------------

func _check_truncation() -> void:
	var history: RefCounted = HistoryScript.new()
	_state = [_rec("a")]
	history.seed(_state.duplicate(true))
	_push(history, "one", [_rec("a"), _rec("b")])
	_push(history, "two", [_rec("a"), _rec("b"), _rec("c")])
	_push(history, "three", [_rec("a"), _rec("b"), _rec("c"), _rec("d")])

	history.go_to(0)
	_push(history, "instead", [_rec("a"), _rec("b"), _rec("z")])

	_expect(history.size() == 2, "the future survived: %d commands" % history.size())
	_expect(history.current_index() == 1, "pointer is at %d, not 1" % history.current_index())
	var rows: Array = history.rows()
	_expect(rows.size() == 3, "rows() gave %d, not 3" % rows.size())
	_expect(rows[2]["label"] == "instead", "the newest row is %s" % rows[2]["label"])

	# The replacement is reversible like any other, and lands where its predecessor left.
	history.go_to(0)
	_expect(_state.size() == 2, "undo after truncation gave %d records" % _state.size())


# --- Consecutive edits of one gesture become one row --------------------

func _check_merge() -> void:
	var history: RefCounted = HistoryScript.new()
	_state = [_rec("a")]
	history.seed(_state.duplicate(true))

	# Three steps of one drag: same key, all inside the window.
	for step: int in [2, 3, 4]:
		var to := [_rec("a")]
		to[0]["settings"] = {"thickness": step}
		var top: RefCounted = history.mergeable_top(&"set:0:thickness", Time.get_ticks_msec())
		var from: Array = top.before if top != null else history.current_state()
		var was := int((from[0] as Dictionary).get("settings", {}).get("thickness", 1))
		history.record(CommandScript.new("Thickness %d → %d" % [was, step],
				&"set:0:thickness", from, to, _apply))

	_expect(history.size() == 1, "a drag became %d rows, not 1" % history.size())
	# Named for the whole gesture rather than for its last step, which is what asking
	# mergeable_top before describing buys.
	_expect(history.rows()[1]["label"] == "Thickness 1 → 4",
			"the merged row reads \"%s\", not the whole span" % history.rows()[1]["label"])

	history.go_to(HistoryScript.BASE_INDEX)
	var landed := int((_state[0] as Dictionary).get("settings", {}).get("thickness", 1))
	_expect(landed == 1, "undoing a merged drag left thickness at %d" % landed)

	history.go_to(0)
	_push(history, "other", [_rec("a"), _rec("b")])
	_expect(history.size() == 2, "an edit with a different key merged anyway")


# --- The cap, and what it does to the starting state --------------------

func _check_cap() -> void:
	var history: RefCounted = HistoryScript.new()
	_state = []
	history.seed([])
	for i in int(HistoryScript.MAX_COMMANDS) + 50:
		var to := []
		for n in i + 1:
			to.append(_rec("s%d" % n))
		history.record(CommandScript.new("edit %d" % i, &"", history.current_state(), to, _apply))

	_expect(history.size() == HistoryScript.MAX_COMMANDS,
			"kept %d commands, not %d" % [history.size(), HistoryScript.MAX_COMMANDS])
	_expect(history.current_index() == int(HistoryScript.MAX_COMMANDS) - 1,
			"the pointer drifted to %d" % history.current_index())

	# The first row stops claiming to be the opening state, because it no longer is.
	var rows: Array = history.rows()
	_expect(rows[0]["label"] == "Earlier edits dropped",
			"the base row still claims to be the opening state: %s" % rows[0]["label"])

	# Rewinding all the way lands on the oldest survivor's own starting point rather than
	# on nothing, which is what makes a trimmed history still usable.
	history.go_to(HistoryScript.BASE_INDEX)
	_expect(_state.size() == 50, "the trimmed base holds %d records, not 50" % _state.size())


# --- What each edit ends up called --------------------------------------

func _check_descriptions() -> void:
	# Detached: _ready and _enter_tree only fire in a tree, and describing a change is a
	# function of two states rather than of anything on screen.
	var panel: Object = PanelScript.new()

	_describes(panel, "Add", [_s("remove_background")],
			[_s("remove_background"), _s("remove_lines")], "Add Remove Lines", false)
	_describes(panel, "Remove", [_s("remove_background"), _s("remove_lines")],
			[_s("remove_background")], "Remove Remove Lines", false)
	_describes(panel, "Reorder", [_s("remove_background"), _s("remove_lines")],
			[_s("remove_lines"), _s("remove_background")], "Reorder operations", false)
	_describes(panel, "Disable", [_s("remove_lines")],
			[_s("remove_lines", false)], "Disable Remove Lines", false)
	_describes(panel, "Enable", [_s("remove_lines", false)],
			[_s("remove_lines")], "Enable Remove Lines", false)

	# An int, under the label its schema gives it rather than the variable's spelling.
	_describes(panel, "int",
			[_s("remove_lines", true, {"thickness": 1})],
			[_s("remove_lines", true, {"thickness": 4})],
			"Thickness 1 → 4", true)
	# A bool reads as on and off.
	_describes(panel, "bool",
			[_s("remove_lines", true, {"detached_only": true})],
			[_s("remove_lines", true, {"detached_only": false})],
			"Detached Only on → off", true)
	# A float without the trailing noise a plain cast leaves.
	_describes(panel, "float",
			[_s("remove_crevice", true, {"crevice_tolerance": 0.25})],
			[_s("remove_crevice", true, {"crevice_tolerance": 0.5})],
			"Crevice Tolerance 0.25 → 0.5", true)
	# Two values at once has no one thing to name, and still merges — which is what makes
	# a dragged polygon vertex one row rather than one per frame.
	_describes(panel, "several",
			[_s("remove_lines", true, {"thickness": 1, "detached_only": true})],
			[_s("remove_lines", true, {"thickness": 4, "detached_only": false})],
			"Remove Lines settings", true)
	# A nested Resource — what every list control produces — is that same case.
	_describes(panel, "nested",
			[_s("polygon_edit", true, {"polygons": {"regions": []}})],
			[_s("polygon_edit", true, {"polygons": {"regions": [{"points": [1, 2]}]}})],
			"Polygon Edit settings", true)

	panel.free()


func _describes(panel: Object, name: String, before: Array, after: Array, expected: String,
		merges: bool) -> void:
	var got: Dictionary = panel._describe_change(before, after)
	_expect(String(got["label"]) == expected,
			"%s reads \"%s\", not \"%s\"" % [name, got["label"], expected])
	_expect((not String(got["merge_key"]).is_empty()) == merges,
			"%s merge key is \"%s\"" % [name, got["merge_key"]])


# --- Helpers ------------------------------------------------------------

func _apply(state: Array) -> void:
	_state = state.duplicate(true)


func _push(history: RefCounted, label: String, to: Array) -> void:
	history.record(CommandScript.new(label, &"", history.current_state(), to, _apply))
	_apply(to)


func _rec(id: String) -> Dictionary:
	return {"id": id, "enabled": true, "settings": {}}


func _s(id: String, enabled := true, settings := {}) -> Dictionary:
	return {"id": id, "enabled": enabled, "settings": settings}


func _expect(condition: bool, message: String) -> bool:
	if not condition:
		printerr("FAIL: %s" % message)
		_failures += 1
	return condition
