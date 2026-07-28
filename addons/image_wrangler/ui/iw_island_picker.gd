@tool
extends VBoxContainer

## The Island Picker: a list of image regions the user sweeps off the preview,
## each standing for an area the operation should act on.
##
## Owns the list and its buttons, but neither the picking nor the storage. Only
## the dock can see the preview, so it listens for [signal pick_toggled], routes
## the swept rectangle back in through [method add_region], and mirrors the entries
## as markers.
##
## A row is a region, not a pixel. Inside it is one [IslandPick] per pixel that region
## seeds from, each with a tolerance of its own; the editor under the list writes all
## of them at once, and the expander below it opens them up for the times one pixel
## needs a different number from its neighbours. See [IslandEntry].
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

## Most per-pixel rows the expander will draw for one region.
##
## A capped view rather than a capped list: the entry keeps every pick it was built
## with, and the editor above reaches all of them. What this bounds is how many
## [EditorSpinSlider]s the dock has to build and lay out, which a four-thousand-pixel
## region would otherwise make it do on every click.
const MAX_PICK_ROWS := 64

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

## Shown when the picks in the highlighted region do not all agree, so the number in
## the slider is never mistaken for a fact about the whole group.
var _mixed_label: Label

## The way into the picks of the highlighted region, and the rows it reveals. Both
## hidden for a region of one pixel, where the editor above already is the pick.
var _picks_toggle: Button
var _picks_box: VBoxContainer
## One per row currently built, in pick order, so a write through the group editor can
## be shown without rebuilding the rows under the pointer.
var _pick_sliders: Array[EditorSpinSlider] = []

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
	_pick_button.tooltip_text = "Drag a rectangle over the preview to add that region to the list,\nor click once for a single pixel.\nPress H over the dock to show or hide the markers."
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
	_tolerance_slider.tooltip_text = "How far a pixel may drift from the color under a picked pixel and still be\npart of the region it floods.\n\nWrites every pixel in the highlighted island at once. Open Pixels below to\nset one of them on its own.\n\nIts own, not shared between islands: how clean one region is says nothing\nabout the one beside it. A new island starts on whatever the last one was\nset to."
	_tolerance_slider.value_changed.connect(_on_tolerance_changed)
	_editor.add_child(_tolerance_slider)

	_mixed_label = Label.new()
	_mixed_label.text = "mixed"
	_mixed_label.modulate = Color(1, 1, 1, 0.6)
	_mixed_label.tooltip_text = "The pixels in this island have different tolerances.\nThe slider shows one of them; moving it sets them all."
	_mixed_label.visible = false
	_editor.add_child(_mixed_label)

	_picks_toggle = Button.new()
	_picks_toggle.toggle_mode = true
	_picks_toggle.flat = true
	_picks_toggle.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_picks_toggle.tooltip_text = "The pixels this island floods from, each with a tolerance of its own."
	_picks_toggle.toggled.connect(func(_pressed: bool) -> void: _rebuild_pick_rows())
	_picks_toggle.visible = false
	add_child(_picks_toggle)

	_picks_box = VBoxContainer.new()
	_picks_box.add_theme_constant_override("separation", 1)
	_picks_box.visible = false
	add_child(_picks_box)

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


## Adds an island covering [param region], and returns how many pixels it seeds from.
##
## Zero means nothing was added, which happens when the region names a spot the list
## already covers — that is a request to look at the entry that is there, not for a
## second copy of it. A one by one region is exactly the single click this control
## started out taking, and behaves as it always did.
func add_region(region: Rect2i) -> int:
	var islands := _island_list()
	if islands == null or region.size.x <= 0 or region.size.y <= 0:
		return 0
	if region.size == Vector2i.ONE:
		var existing := islands.find(region.position)
		if existing >= 0:
			_set_hint("That position is already in the list.")
			_select(existing)
			return 0

	var entry := islands.add_region(region)
	_refresh()
	_select(islands.size() - 1)
	# Said out loud rather than left to be noticed: past the cap the region is seeded
	# on a stride, and a user who has just asked for every pixel of it deserves to
	# know they got a grid instead.
	var area := region.size.x * region.size.y
	if entry.size() < area:
		_set_hint("Region of %s pixels is over the limit; seeded from %s of them, evenly spaced."
				% [area, entry.size()])
	else:
		_set_hint("")
	islands_changed.emit()
	return entry.size()


## Every island's bounds, for the dock to mark on the preview.
func get_islands() -> Array[Rect2i]:
	var out: Array[Rect2i] = []
	var islands := _island_list()
	if islands == null:
		return out
	for entry in islands.entries:
		out.append(entry.bounds() if entry != null else Rect2i())
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


## The highlighted entry, or null.
func _selected_entry() -> IslandEntry:
	var islands := _island_list()
	return islands.get_at(selected_index()) if islands != null else null


func _on_row_selected(_index: int) -> void:
	_load_editor()
	_update_buttons()
	selection_changed.emit()


## Points the tolerance editor at the highlighted row, or hides it when there is
## none.
func _load_editor() -> void:
	var entry := _selected_entry()
	_editor.visible = entry != null
	# Nothing to open for a single pixel: the editor above it is that pixel.
	_picks_toggle.visible = entry != null and entry.size() > 1
	if entry == null:
		_rebuild_pick_rows()
		return
	_picks_toggle.text = "Pixels (%d)" % entry.size()
	_sync_tolerance_slider(entry)
	_rebuild_pick_rows()


## Puts the group slider on whatever the highlighted region says, without letting it
## report the write back as an edit.
func _sync_tolerance_slider(entry: IslandEntry) -> void:
	var shared := entry.shared_tolerance()
	var shown := shared
	if shared < 0.0:
		var sample := entry.representative()
		shown = sample.color_tolerance if sample != null else IslandPick.DEFAULT_TOLERANCE
	# The control is being told what the row holds, not the other way round.
	_loading_editor = true
	_tolerance_slider.set_value_no_signal(shown)
	# EditorSpinSlider paints its own value, and the no-signal setter deliberately
	# skips the notification that would repaint it.
	_tolerance_slider.queue_redraw()
	_loading_editor = false
	_mixed_label.visible = shared < 0.0


## Rebuilds the per-pixel rows for the highlighted region, or clears them when there
## is nothing to show.
##
## Only while the expander is open, so a list of regions costs nothing to click
## through — building sixty-four sliders per selection change is exactly the sort of
## work a control should not do until it has been asked for.
func _rebuild_pick_rows() -> void:
	for child in _picks_box.get_children():
		_picks_box.remove_child(child)
		child.queue_free()
	_pick_sliders.clear()

	var entry := _selected_entry()
	_picks_box.visible = _picks_toggle.visible and _picks_toggle.button_pressed and entry != null
	if not _picks_box.visible:
		return

	var shown := mini(entry.size(), MAX_PICK_ROWS)
	for i in shown:
		_picks_box.add_child(_build_pick_row(i, entry.get_pick(i)))
	if entry.size() > shown:
		var more := Label.new()
		more.text = "…and %d more. The slider above sets every pixel." % (entry.size() - shown)
		more.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		more.modulate = Color(1, 1, 1, 0.6)
		_picks_box.add_child(more)


## One pixel of the highlighted region: its colour, where it is, and its own tolerance.
func _build_pick_row(index: int, pick: IslandPick) -> Control:
	var row := HBoxContainer.new()

	var swatch := TextureRect.new()
	var color := Color.MAGENTA
	if pick != null and _color_provider.is_valid():
		color = _color_provider.call(pick.point)
	swatch.texture = EntryList.make_swatch(color)
	swatch.custom_minimum_size = Vector2(EntryList.SWATCH_SIZE, EntryList.SWATCH_SIZE)
	swatch.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	row.add_child(swatch)

	var label := Label.new()
	if pick != null:
		label.text = "(%d, %d)" % [pick.point.x, pick.point.y]
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	row.add_child(label)

	var slider := EditorSpinSlider.new()
	slider.min_value = 0.0
	slider.max_value = RemoveColorEntry.MAX_TOLERANCE
	slider.step = 0.005
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.read_only = not _interactive
	slider.set_value_no_signal(pick.color_tolerance if pick != null else IslandPick.DEFAULT_TOLERANCE)
	slider.value_changed.connect(_on_pick_tolerance_changed.bind(index))
	row.add_child(slider)

	_pick_sliders.append(slider)
	return row


## The group editor moved: every pick in the region takes the new number.
func _on_tolerance_changed(value: float) -> void:
	if _loading_editor:
		return
	var index := selected_index()
	var entry := _selected_entry()
	if entry == null:
		return
	entry.set_tolerance(value)
	_mixed_label.visible = false
	# The open rows are showing values this just overwrote. Written into rather than
	# rebuilt, so dragging the group slider does not tear down the list under it.
	_loading_editor = true
	for slider in _pick_sliders:
		slider.set_value_no_signal(value)
		slider.queue_redraw()
	_loading_editor = false
	# Redrawn rather than rebuilt, so dragging the slider does not pull the row
	# out from under the selection driving it.
	_list.update_row(index, _row_data(index, entry))
	_set_hint("")
	islands_changed.emit()


## One pixel's own editor moved. The group may now disagree with itself, which is
## what the mixed marker is for.
func _on_pick_tolerance_changed(value: float, pick_index: int) -> void:
	if _loading_editor:
		return
	var index := selected_index()
	var entry := _selected_entry()
	if entry == null:
		return
	var pick := entry.get_pick(pick_index)
	if pick == null:
		return
	pick.color_tolerance = value
	_sync_tolerance_slider(entry)
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
## than stored, so it always shows a colour this island would actually key out.
##
## A region says where it is and how many pixels it seeds from; a single pick says
## where it is and what its tolerance is, which is what a row has always said and
## what there is room for.
func _row_data(index: int, entry: IslandEntry) -> Dictionary:
	var bounds := entry.bounds() if entry != null else Rect2i()
	var sample := entry.representative() if entry != null else null
	var color := Color.MAGENTA
	if sample != null and _color_provider.is_valid():
		color = _color_provider.call(sample.point)
	var tolerance := sample.color_tolerance if sample != null else IslandPick.DEFAULT_TOLERANCE

	var text := ""
	if entry == null or entry.size() <= 1:
		text = "%d.  (%d, %d)   %.3f" % [index + 1, bounds.position.x, bounds.position.y, tolerance]
	else:
		var shared := entry.shared_tolerance()
		var reading := "%.3f" % shared if shared >= 0.0 else "mixed"
		text = "%d.  (%d, %d)–(%d, %d)   %d px   %s" % [
			index + 1,
			bounds.position.x,
			bounds.position.y,
			bounds.end.x - 1,
			bounds.end.y - 1,
			entry.size(),
			reading,
		]

	return {
		"color": color,
		"text": text,
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
	if _picks_toggle != null:
		_picks_toggle.disabled = not _interactive
	for slider in _pick_sliders:
		slider.read_only = not _interactive
