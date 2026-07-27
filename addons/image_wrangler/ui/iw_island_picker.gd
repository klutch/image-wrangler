@tool
extends VBoxContainer

## The Island Picker: a list of image positions the user clicks off the preview,
## each standing for a region the operation should act on.
##
## Owns the list and its buttons, but neither the picking nor the storage. Only
## the dock can see the preview, so it listens for [signal pick_toggled], routes
## the click back in through [method add_island], and mirrors the entries as
## markers.
##
## The [IslandList] it edits is resolved through the operation's settings on
## every access, so when the dock swaps in another image's settings this control
## follows without being told — it only needs a [method refresh] to redraw.

## Emitted when the pick button is toggled. The dock puts the preview into
## crosshair mode in response.
signal pick_toggled(enabled: bool)

## Emitted whenever the underlying list changes, so the dock can re-run the
## preview and write the list back against the current image.
signal islands_changed

## Emitted when a different row is highlighted, so the matching marker can be.
signal selection_changed

const ToolButton := preload("res://addons/image_wrangler/ui/iw_tool_button.gd")
const EntryList := preload("res://addons/image_wrangler/ui/iw_entry_list.gd")

var _operation: IWOperation
var _property: StringName

## Supplied by the dock: maps a position to its colour in the image on screen.
## Swatches are sampled through this rather than stored, so they can never go
## stale against whichever image is currently selected — and for the background
## remover the swatch is not decoration, it is the colour that island keys out.
var _color_provider := Callable()

## Whether this control answers to the pointer.
##
## Its own state rather than something set on the buttons from outside, because
## [method _update_buttons] rewrites them whenever the selection or the list changes
## and would put back whatever it worked out for itself.
var _interactive := true

var _list: EntryList
var _pick_button: Button
var _remove_button: Button
var _clear_button: Button

## Tolerance editor for the highlighted row. Hidden rather than disabled when
## nothing is selected, so the group does not show a control that edits nothing.
var _editor: HBoxContainer
var _tolerance_slider: EditorSpinSlider

## Set while the editor is being pointed at another row, so its change signal does
## not write the row that was selected a moment ago.
var _loading_editor := false

var _hint: Label


## Binds this control to [param property] on [param operation].
func setup(operation: IWOperation, property: StringName) -> void:
	_operation = operation
	_property = property
	_build()
	_refresh()


func _build() -> void:
	# The buttons come first so they sit flush under the group heading. This
	# control has no title of its own — the settings form already provides one.
	var buttons := HBoxContainer.new()
	add_child(buttons)

	_pick_button = Button.new()
	_pick_button.text = "Pick"
	_pick_button.toggle_mode = true
	_pick_button.tooltip_text = "Click a region in the preview to add it to the list.\nPress H over the dock to show or hide the markers."
	_pick_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_pick_button.toggled.connect(func(pressed: bool) -> void: pick_toggled.emit(pressed))
	buttons.add_child(_pick_button)

	_remove_button = Button.new()
	_remove_button.text = "Remove"
	_remove_button.tooltip_text = "Remove the highlighted island."
	_remove_button.pressed.connect(_on_remove_pressed)
	buttons.add_child(_remove_button)

	_clear_button = Button.new()
	_clear_button.text = "Clear"
	_clear_button.tooltip_text = "Remove every island for this image."
	_clear_button.pressed.connect(_on_clear_pressed)
	buttons.add_child(_clear_button)

	_list = EntryList.new()
	_list.configure(true)
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.row_selected.connect(_on_row_selected)
	_list.enabled_toggled.connect(_on_enabled_toggled)
	_list.mode_changed.connect(_on_mode_changed)
	add_child(_list)

	_editor = HBoxContainer.new()
	add_child(_editor)

	_tolerance_slider = EditorSpinSlider.new()
	_tolerance_slider.label = "Tolerance"
	_tolerance_slider.min_value = 0.0
	_tolerance_slider.max_value = RemoveColorEntry.MAX_TOLERANCE
	_tolerance_slider.step = 0.005
	_tolerance_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tolerance_slider.tooltip_text = "How far a pixel may drift from the color under this island and still be\npart of the region it floods.\n\nIts own, not shared: how clean one region is says nothing about the one\nbeside it. A new island starts on whatever the last one was set to."
	_tolerance_slider.value_changed.connect(_on_tolerance_changed)
	_editor.add_child(_tolerance_slider)

	_hint = Label.new()
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint.modulate = Color(1, 1, 1, 0.6)
	_hint.visible = false
	add_child(_hint)


## Shows [param text] under the list, or gives the line back when it is empty.
##
## Hidden rather than blanked. An empty Label still claims a line's height, and
## three of these controls in one form is a visible band of nothing in a dock with
## no room to spare.
func _set_hint(text: String) -> void:
	_hint.text = text
	_hint.visible = not text.is_empty()


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED and _pick_button != null:
		ToolButton.apply_pick_icon(_pick_button)
		ToolButton.style_armed(_pick_button)


# --- Public API ---------------------------------------------------------

## Lets the dock supply the colour behind a position, for the row swatches.
func set_color_provider(provider: Callable) -> void:
	_color_provider = provider
	_refresh()


## Adds an island at [param at].
func add_island(at: Vector2i) -> void:
	var islands := _island_list()
	if islands == null:
		return
	var existing := islands.find(at)
	if existing >= 0:
		_set_hint("That position is already in the list.")
		_select(existing)
		return

	islands.add(at)
	_refresh()
	_select(islands.size() - 1)
	_set_hint("")
	islands_changed.emit()


## Every island's position, for the dock to mark on the preview.
func get_islands() -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var islands := _island_list()
	if islands == null:
		return out
	for entry in islands.entries:
		out.append(entry.point if entry != null else Vector2i(-1, -1))
	return out


## Whether each island is switched on, in the same order, so the dock can draw a
## disabled one differently rather than hiding it.
func get_enabled_flags() -> PackedByteArray:
	var out := PackedByteArray()
	var islands := _island_list()
	if islands == null:
		return out
	for entry in islands.entries:
		out.append(1 if entry != null and entry.enabled else 0)
	return out


## Redraws the rows from whatever list the operation now points at. Called when
## the settings Resource is swapped for another image.
## Turns every control here on or off, for a stack entry that has been switched off.
## See [method IWColorList.set_controls_enabled].
func set_controls_enabled(value: bool) -> void:
	_interactive = value
	if _list != null:
		_list.set_interactive(value)
	_update_buttons()


func refresh() -> void:
	_set_hint("")
	_refresh()


## Row currently highlighted, or -1. Drives which marker is emphasised.
func selected_index() -> int:
	return _list.selected_index()


## Lets the dock switch picking off without echoing back a [signal pick_toggled].
func set_pick_active(enabled: bool) -> void:
	_pick_button.set_pressed_no_signal(enabled)


# --- Internals ----------------------------------------------------------

## The list this picker edits, resolved through the operation every time so that
## swapping the settings Resource for another image needs no re-pointing here.
func _island_list() -> IslandList:
	if _operation == null:
		return null
	var settings := _operation.get_settings()
	if settings == null:
		return null
	return settings.get(_property) as IslandList


func _on_row_selected(_index: int) -> void:
	_load_editor()
	_update_buttons()
	selection_changed.emit()


## Points the tolerance slider at the highlighted row, or hides it when there is
## none.
func _load_editor() -> void:
	var islands := _island_list()
	var entry := islands.get_at(selected_index()) if islands != null else null
	_editor.visible = entry != null
	if entry == null:
		return
	# The control is being told what the row holds, not the other way round.
	_loading_editor = true
	_tolerance_slider.set_value_no_signal(entry.color_tolerance)
	# EditorSpinSlider paints its own value, and the no-signal setter deliberately
	# skips the notification that would repaint it.
	_tolerance_slider.queue_redraw()
	_loading_editor = false


func _on_tolerance_changed(value: float) -> void:
	if _loading_editor:
		return
	var islands := _island_list()
	var index := selected_index()
	var entry := islands.get_at(index) if islands != null else null
	if entry == null:
		return
	entry.color_tolerance = value
	# Redrawn rather than rebuilt, so dragging the slider does not pull the row
	# out from under the selection driving it.
	_list.update_row(index, _row_data(index, entry))
	_set_hint("")
	islands_changed.emit()


func _on_enabled_toggled(index: int, on: bool) -> void:
	var islands := _island_list()
	var entry := islands.get_at(index) if islands != null else null
	if entry == null:
		return
	entry.enabled = on
	_list.update_row(index, _row_data(index, entry))
	_set_hint("")
	islands_changed.emit()
	selection_changed.emit()


func _on_mode_changed(index: int, mode: int) -> void:
	var islands := _island_list()
	var entry := islands.get_at(index) if islands != null else null
	if entry == null:
		return
	entry.mode = IWAlphaMode.sanitise(mode)
	_list.update_row(index, _row_data(index, entry))
	_set_hint("")
	islands_changed.emit()


func _on_remove_pressed() -> void:
	var index := selected_index()
	var islands := _island_list()
	if islands == null or index < 0 or index >= islands.size():
		return
	islands.remove_at(index)
	_refresh()
	if _list.count() > 0:
		_select(mini(index, _list.count() - 1))
	_set_hint("")
	islands_changed.emit()
	selection_changed.emit()


func _on_clear_pressed() -> void:
	var islands := _island_list()
	if islands == null or islands.is_empty():
		return
	islands.clear()
	_refresh()
	_set_hint("")
	islands_changed.emit()
	selection_changed.emit()


func _select(index: int) -> void:
	_list.select(index)
	_load_editor()
	_update_buttons()
	selection_changed.emit()


## One row's worth of display data. The swatch is sampled through the dock rather
## than stored, so it always shows the colour this island would actually key out.
func _row_data(index: int, entry: IslandEntry) -> Dictionary:
	var point := entry.point if entry != null else Vector2i(-1, -1)
	var color := Color.MAGENTA
	if _color_provider.is_valid():
		color = _color_provider.call(point)
	var tolerance := entry.color_tolerance if entry != null else IslandEntry.DEFAULT_TOLERANCE
	return {
		"color": color,
		"text": "%d.  (%d, %d)   %.3f" % [index + 1, point.x, point.y, tolerance],
		"enabled": entry != null and entry.enabled,
		"mode": entry.mode if entry != null else IWAlphaMode.Mode.SUBTRACT,
	}


func _refresh() -> void:
	if _list == null:
		return
	var islands := _island_list()
	var rows := []
	if islands != null:
		for i in islands.size():
			rows.append(_row_data(i, islands.get_at(i)))
	_list.set_rows(rows)
	_load_editor()
	_update_buttons()


func _update_buttons() -> void:
	_remove_button.disabled = not _interactive or selected_index() < 0
	_clear_button.disabled = not _interactive or _list.count() == 0
	_pick_button.disabled = not _interactive
	if _tolerance_slider != null:
		_tolerance_slider.read_only = not _interactive
