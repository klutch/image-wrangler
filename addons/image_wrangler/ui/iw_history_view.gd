@tool
extends VBoxContainer

## The History tab: every edit made to this image's stack this session, in order.
##
## Reading rather than doing. The rows are a record, and clicking one is the only thing
## that can be done here — which is what makes it safe for it to be a plain list rather
## than something with buttons on it.

## Emitted when a row is clicked, with [constant IWHistory.BASE_INDEX] for the starting
## state and the command's own index otherwise.
signal revert_requested(index: int)

## How far the undone rows are faded.
##
## Still legible, not merely present: their whole job is to say what is still there to go
## back to, and a row too faint to read is one the user has to click to find out about.
const FUTURE_ALPHA := 0.45

var _list: ItemList
var _hint: Label

## Set while the list is being rebuilt, so selecting the current row does not read as the
## user asking to go there.
var _refreshing := false


func _ready() -> void:
	if _list == null:
		_build()


func _build() -> void:
	var title := Label.new()
	title.text = "History"
	add_child(title)

	_hint = Label.new()
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint.modulate = Color(1, 1, 1, 0.6)
	add_child(_hint)

	_list = ItemList.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list.auto_height = false
	_list.allow_reselect = true
	_list.item_selected.connect(_on_item_selected)
	add_child(_list)


## Redraws the rows and puts the selection on the current one.
##
## [param rows] is [method IWHistory.rows]. An empty Array means there is no image
## selected, which is a different thing from an image with no edits — that one still has
## its starting row.
func set_rows(rows: Array, current: int) -> void:
	if _list == null:
		_build()
	_refreshing = true
	_list.clear()

	for row: Dictionary in rows:
		var index: int = row.get("index", IWHistory.BASE_INDEX)
		_list.add_item(String(row.get("label", "")))
		var at := _list.item_count - 1
		_list.set_item_metadata(at, index)
		# Undone rows are dimmed rather than removed: they are exactly what fast-forward
		# is for, and a list that hid them would make going back look impossible.
		if bool(row.get("future", false)):
			_list.set_item_custom_fg_color(at, Color(1, 1, 1, FUTURE_ALPHA))
		if index == current:
			_list.select(at)
			_list.ensure_current_is_visible()

	_hint.text = _hint_for(rows, current)
	_refreshing = false


## What the line under the title says, which is different in each of the three states this
## list can be in.
func _hint_for(rows: Array, current: int) -> String:
	if rows.is_empty():
		return "Select an image to see its history."
	if rows.size() == 1:
		return "No edits yet. Every change to the stack lands here."
	var undone := 0
	for row: Dictionary in rows:
		if bool(row.get("future", false)):
			undone += 1
	if undone > 0:
		return ("Rewound. Pick a faded row to go forward again — editing anything now "
				+ "drops %s." % ("that row" if undone == 1 else "those %d rows" % undone))
	return "Click a row to rewind to it. Session only, and never saved."


func _on_item_selected(at: int) -> void:
	if _refreshing:
		return
	var index: Variant = _list.get_item_metadata(at)
	if index is int:
		revert_requested.emit(int(index))
