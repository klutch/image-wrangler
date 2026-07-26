@tool
extends VBoxContainer

## The Remove Colors list: the background colours an operation keys out, each with
## a tolerance of its own.
##
## Built on the same shape as the Island Picker, and for the same reason — both
## answer "which of these did you mean", and a list with a Pick button is the one
## control that lets the image itself supply the answer. The two differ in what a
## row holds: an island is a place, and is only ever picked; a colour is a value,
## so it can also be typed in, and it carries a tolerance the row has to expose.
##
## Owns the list and its buttons, but neither the picking nor the storage. Only
## the dock can see the preview, so it listens for [signal pick_toggled] and
## routes the sampled colour back in through [method add_color].
##
## The [RemoveColorList] it edits is resolved through the operation's settings on
## every access, so when the dock swaps in another image's settings this control
## follows without being told — it only needs a [method refresh] to redraw.

## Emitted when the pick button is toggled. The dock puts the preview into
## crosshair mode in response, and switches any other picker off.
signal pick_toggled(enabled: bool)

## Emitted whenever the list or any entry on it changes, so the dock can re-run
## the preview and save the settings against the current image.
signal colors_changed

const SWATCH_SIZE := 14
const LIST_MIN_HEIGHT := 84

## Caption width for the editor row, matching [code]iw_settings_builder.gd[/code]
## so the tolerance slider lines up with the sliders above and below it.
const LABEL_WIDTH := 92

var _operation: IWOperation
var _property: StringName

var _list: ItemList
var _pick_button: Button
var _add_button: Button
var _remove_button: Button
var _clear_button: Button

## Editor for the highlighted row. Hidden rather than disabled when nothing is
## selected, so the group does not show controls that edit nothing.
var _editor: HBoxContainer
var _color_button: ColorPickerButton
var _tolerance_slider: EditorSpinSlider

var _hint: Label

## Set while the editor is being pointed at another row, so its change signals do
## not write the row that was selected a moment ago.
var _loading_editor := false


## Binds this control to [param property] on [param operation].
func setup(operation: IWOperation, property: StringName) -> void:
	_operation = operation
	_property = property
	_build()
	_refresh()


func _build() -> void:
	# Buttons first so they sit flush under the group heading. This control has no
	# title of its own — the settings form already provides one.
	var buttons := HBoxContainer.new()
	add_child(buttons)

	_pick_button = Button.new()
	_pick_button.text = "Pick"
	_pick_button.toggle_mode = true
	_pick_button.tooltip_text = "Click a color in the preview to add it to the list."
	_pick_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_pick_button.toggled.connect(func(pressed: bool) -> void: pick_toggled.emit(pressed))
	buttons.add_child(_pick_button)

	_add_button = Button.new()
	_add_button.text = "Add"
	_add_button.tooltip_text = "Add an entry to set by hand, without picking off the image."
	_add_button.pressed.connect(_on_add_pressed)
	buttons.add_child(_add_button)

	_remove_button = Button.new()
	_remove_button.text = "Remove"
	_remove_button.tooltip_text = "Remove the highlighted color."
	_remove_button.pressed.connect(_on_remove_pressed)
	buttons.add_child(_remove_button)

	_clear_button = Button.new()
	_clear_button.text = "Clear"
	_clear_button.tooltip_text = "Remove every color for this image.\nAn empty list keys nothing out from the border."
	_clear_button.pressed.connect(_on_clear_pressed)
	buttons.add_child(_clear_button)

	_list = ItemList.new()
	_list.custom_minimum_size = Vector2(0, LIST_MIN_HEIGHT)
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.item_selected.connect(_on_item_selected)
	add_child(_list)

	_editor = HBoxContainer.new()
	add_child(_editor)

	_color_button = ColorPickerButton.new()
	_color_button.edit_alpha = false
	_color_button.custom_minimum_size = Vector2(LABEL_WIDTH, 24)
	_color_button.tooltip_text = "The background color this entry keys out.\nThe picker's eyedropper can sample it off the screen."
	_color_button.color_changed.connect(_on_color_changed)
	_editor.add_child(_color_button)

	_tolerance_slider = EditorSpinSlider.new()
	_tolerance_slider.label = "Tolerance"
	_tolerance_slider.min_value = 0.0
	_tolerance_slider.max_value = RemoveColorEntry.MAX_TOLERANCE
	_tolerance_slider.step = 0.005
	_tolerance_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tolerance_slider.tooltip_text = "How far a pixel may drift from this color and still be keyed out.\nRaise it if a re-compressed background leaves speckles behind."
	_tolerance_slider.value_changed.connect(_on_tolerance_changed)
	_editor.add_child(_tolerance_slider)

	_hint = Label.new()
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint.modulate = Color(1, 1, 1, 0.6)
	add_child(_hint)


# --- Public API ---------------------------------------------------------

## Adds an entry for [param color], or highlights the one already holding it.
func add_color(color: Color) -> void:
	var colors := _color_list()
	if colors == null:
		return

	var existing := colors.find_color(color)
	if existing >= 0:
		# Silently adding a duplicate would look like nothing happened, and the
		# second entry could never claim a pixel the first had not already taken.
		_hint.text = "That color is already in the list."
		_select(existing)
		return

	colors.add(color)
	_refresh()
	_select(colors.size() - 1)
	_hint.text = ""
	colors_changed.emit()


## Redraws the rows from whatever list the operation now points at. Called when
## the settings Resource is swapped for another image.
func refresh() -> void:
	_hint.text = ""
	_refresh()


## Lets the dock switch picking off without echoing back a [signal pick_toggled] —
## used when the island picker claims the preview instead.
func set_pick_active(enabled: bool) -> void:
	_pick_button.set_pressed_no_signal(enabled)


# --- Internals ----------------------------------------------------------

## The list this control edits, resolved through the operation every time so that
## swapping the settings Resource for another image needs no re-pointing here.
func _color_list() -> RemoveColorList:
	if _operation == null:
		return null
	var settings := _operation.get_settings()
	if settings == null:
		return null
	return settings.get(_property) as RemoveColorList


func _selected_index() -> int:
	var selection := _list.get_selected_items()
	return selection[0] if not selection.is_empty() else -1


func _selected_entry() -> RemoveColorEntry:
	var colors := _color_list()
	return colors.get_at(_selected_index()) if colors != null else null


func _on_item_selected(_index: int) -> void:
	_load_editor()
	_update_buttons()


## Adds an entry at the default colour for the user to set by hand.
##
## White rather than anything cleverer: it is what a fresh image starts at, and
## guessing from the image would be picking without the user having pointed at
## anything.
func _on_add_pressed() -> void:
	var colors := _color_list()
	if colors == null:
		return
	colors.add(Color.WHITE)
	_refresh()
	_select(colors.size() - 1)
	_hint.text = "Set the color with the swatch, or use Pick to take one off the image."
	colors_changed.emit()


func _on_remove_pressed() -> void:
	var index := _selected_index()
	var colors := _color_list()
	if colors == null or index < 0 or index >= colors.size():
		return
	colors.remove_at(index)
	_refresh()
	if _list.item_count > 0:
		_select(mini(index, _list.item_count - 1))
	else:
		_load_editor()
	_hint.text = ""
	colors_changed.emit()


func _on_clear_pressed() -> void:
	var colors := _color_list()
	if colors == null or colors.is_empty():
		return
	colors.clear()
	_refresh()
	_load_editor()
	_hint.text = "Nothing is keyed out from the border now. Islands still apply."
	colors_changed.emit()


func _on_color_changed(color: Color) -> void:
	if _loading_editor:
		return
	var entry := _selected_entry()
	if entry == null:
		return
	entry.color = color
	# The row carries the swatch and the value, so it has to be redrawn — but not
	# rebuilt, which would drop the selection the editor is pointing at.
	_redraw_row(_selected_index())
	colors_changed.emit()


func _on_tolerance_changed(value: float) -> void:
	if _loading_editor:
		return
	var entry := _selected_entry()
	if entry == null:
		return
	entry.color_tolerance = value
	_redraw_row(_selected_index())
	colors_changed.emit()


func _select(index: int) -> void:
	if index < 0 or index >= _list.item_count:
		return
	_list.select(index)
	_load_editor()
	_update_buttons()


## Points the editor at the highlighted row, or hides it when there is none.
func _load_editor() -> void:
	var entry := _selected_entry()
	_editor.visible = entry != null
	if entry == null:
		return
	# The controls are being told what the row holds, not the other way round.
	_loading_editor = true
	_color_button.color = entry.color
	_tolerance_slider.set_value_no_signal(entry.color_tolerance)
	# EditorSpinSlider paints its own value, and the no-signal setter deliberately
	# skips the notification that would repaint it.
	_tolerance_slider.queue_redraw()
	_loading_editor = false


## Rebuilds every row, dropping the selection with them.
##
## Editing a row does not come through here — [method _redraw_row] rewrites one in
## place, precisely so that changing a colour or a tolerance does not deselect the
## row being edited out from under the editor.
func _refresh() -> void:
	if _list == null:
		return
	var colors := _color_list()
	_list.clear()
	if colors != null:
		for i in colors.size():
			var entry := colors.get_at(i)
			_list.add_item(_row_text(entry))
			_list.set_item_icon(i, _swatch(entry))
	_load_editor()
	_update_buttons()


## Rewrites one row in place, leaving the selection alone.
func _redraw_row(index: int) -> void:
	var colors := _color_list()
	if colors == null or index < 0 or index >= _list.item_count:
		return
	var entry := colors.get_at(index)
	_list.set_item_text(index, _row_text(entry))
	_list.set_item_icon(index, _swatch(entry))


## Hex rather than floats: it is what a colour is written as everywhere else the
## user meets one, and it fits a narrow dock column where three decimals do not.
static func _row_text(entry: RemoveColorEntry) -> String:
	if entry == null:
		return "—"
	return "#%s    %.3f" % [entry.color.to_html(false), entry.color_tolerance]


func _update_buttons() -> void:
	_remove_button.disabled = _selected_index() < 0
	_clear_button.disabled = _list.item_count == 0


## Small bordered colour chip, so a white entry is still visible on the row.
static func _swatch(entry: RemoveColorEntry) -> Texture2D:
	var color := entry.color if entry != null else Color.MAGENTA
	var image := Image.create_empty(SWATCH_SIZE, SWATCH_SIZE, false, Image.FORMAT_RGBA8)
	image.fill(Color(0, 0, 0, 1))
	image.fill_rect(Rect2i(1, 1, SWATCH_SIZE - 2, SWATCH_SIZE - 2), color)
	return ImageTexture.create_from_image(image)
