@tool
extends VBoxContainer

## The operation stack: a dropdown to add with, and a draggable column of entries.
##
## Holds the live [IWStackOperation] instances and their order. The dock owns the
## settings behind them and the running of them; this owns what the stack [i]is[/i].
##
## Duplicates are allowed and mean what they look like — two Polygon Edits are two
## independent sets of shapes, and a second Remove Background adds its colours to the
## keys the first registered. So nothing here is keyed by operation id: entries carry
## a uid of their own, because the id is shared between duplicates and the position is
## exactly what a reorder changes.

const StackEntry := preload("res://addons/image_wrangler/ui/iw_stack_entry.gd")

## Room around the column of entries, and between one entry and the next.
##
## The gap is what makes the drop indicator legible: a line drawn on the edge of an
## entry needs somewhere to be that is not already the next entry's edge.
const ENTRY_MARGIN := 4
const ENTRY_GAP := 4

## Emitted when the stack's contents or order changed, so the preview is stale.
signal stack_changed

## Emitted when a value inside one entry's form changed.
signal setting_changed

## Emitted after entries are rebuilt, so the dock can rewire what it cached about
## their controls.
signal entries_rebuilt

## Scripts the dropdown offers, in the order it offers them.
var operation_scripts: Array = []

## Called as [code]build(operation, container, on_changed, fold_state, key)[/code] to
## fill one entry's form. Supplied by the dock so this does not have to know about the
## settings builder.
var form_builder := Callable()

## Which entries are folded, keyed by uid. Held by the dock so a fold outlives a
## rebuild.
var fold_state: Dictionary = {}

## The live stack, in order.
var _entries: Array = []
var _selector: OptionButton
var _list: VBoxContainer
var _next_uid := 1


func _ready() -> void:
	if _list == null:
		_build()


func _build() -> void:
	var add_row := HBoxContainer.new()
	add_child(add_row)

	_selector = OptionButton.new()
	_selector.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_selector.tooltip_text = "Pick an operation to add to the bottom of the stack."
	_selector.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	add_row.add_child(_selector)

	var create := Button.new()
	create.text = "Create"
	create.tooltip_text = "Add the chosen operation to the stack.\nDrag its handle afterwards to move it."
	create.pressed.connect(_on_create)
	add_row.add_child(create)

	# The entries are cards standing off the panel, so they need room around them to
	# read as separate things rather than as one block with lines in it.
	var inset := MarginContainer.new()
	inset.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		inset.add_theme_constant_override(side, ENTRY_MARGIN)
	add_child(inset)

	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", ENTRY_GAP)
	inset.add_child(_list)

	_refresh_selector()


## Fills the dropdown from [member operation_scripts].
##
## Every operation stays offered however many are already in the stack, because a
## second one of anything is a legitimate thing to want.
func _refresh_selector() -> void:
	if _selector == null:
		return
	_selector.clear()
	for path: String in operation_scripts:
		var script: Script = load(path)
		if script == null:
			continue
		var probe: IWOperation = script.new()
		_selector.add_item(probe.get_operation_name())
		_selector.set_item_metadata(_selector.item_count - 1, path)
	if _selector.item_count > 0:
		_selector.selected = 0


func _on_create() -> void:
	if _selector == null or _selector.selected < 0:
		return
	var path: Variant = _selector.get_item_metadata(_selector.selected)
	if not (path is String):
		return
	var script: Script = load(path)
	if script == null:
		return
	add_stage(script.new())
	stack_changed.emit()


## Appends [param stage] to the stack and rebuilds.
func add_stage(stage: IWStackOperation) -> void:
	_entries.append({"uid": _take_uid(), "stage": stage, "entry": null})
	rebuild()


## Replaces the whole stack with [param stages], in order.
func set_stages(stages: Array) -> void:
	_entries.clear()
	for stage: IWStackOperation in stages:
		_entries.append({"uid": _take_uid(), "stage": stage, "entry": null})
	rebuild()


## The live operations, in stack order.
func stages() -> Array[IWStackOperation]:
	var out: Array[IWStackOperation] = []
	for record: Dictionary in _entries:
		out.append(record["stage"])
	return out


## The entry controls, in stack order.
func entries() -> Array:
	var out := []
	for record: Dictionary in _entries:
		if record["entry"] != null:
			out.append(record["entry"])
	return out


func is_empty() -> bool:
	return _entries.is_empty()


## Rebuilds every row from the stack.
##
## Wholesale rather than in place, which is safe because the operations and their
## settings live in [member _entries] rather than in the controls — a rebuilt form is
## repointed at the same objects it was showing before.
func rebuild() -> void:
	if _list == null:
		_build()
	for child in _list.get_children():
		_list.remove_child(child)
		child.queue_free()

	for record: Dictionary in _entries:
		var entry: Control = StackEntry.new()
		_list.add_child(entry)
		entry.setup(record["stage"], record["uid"], bool(fold_state.get(record["uid"], false)))
		entry.remove_requested.connect(_on_remove)
		entry.reorder_requested.connect(_on_reorder)
		entry.enabled_toggled.connect(func(_e: Control, _on: bool) -> void: stack_changed.emit())
		entry.setting_changed.connect(func(_e: Control) -> void: setting_changed.emit())
		record["entry"] = entry
		if form_builder.is_valid():
			form_builder.call(record["stage"], entry.settings_box(), entry, record["uid"])

	entries_rebuilt.emit()


## Captures which entries are folded, so a rebuild does not open them all.
func capture_folds() -> void:
	for record: Dictionary in _entries:
		var entry: Control = record["entry"]
		if entry != null:
			fold_state[record["uid"]] = entry.is_folded()


func _on_remove(entry: Control) -> void:
	capture_folds()
	for i in _entries.size():
		if _entries[i]["entry"] == entry:
			fold_state.erase(_entries[i]["uid"])
			_entries.remove_at(i)
			break
	rebuild()
	stack_changed.emit()


## Moves the dragged entry to just above or below the one it was dropped on.
##
## The removal happens before the target is located again, so the insertion point is
## computed against the list the entry is no longer in — otherwise dragging downwards
## lands one place short of where the indicator was drawn.
func _on_reorder(from_uid: int, to_uid: int, above: bool) -> void:
	if from_uid == to_uid:
		return
	capture_folds()

	var moving: Variant = null
	for i in _entries.size():
		if _entries[i]["uid"] == from_uid:
			moving = _entries[i]
			_entries.remove_at(i)
			break
	if moving == null:
		return

	var target := _entries.size()
	for i in _entries.size():
		if _entries[i]["uid"] == to_uid:
			target = i if above else i + 1
			break
	_entries.insert(target, moving)

	rebuild()
	stack_changed.emit()


func _take_uid() -> int:
	var uid := _next_uid
	_next_uid += 1
	return uid
