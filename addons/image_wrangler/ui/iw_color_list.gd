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
## A row is a background, not a colour. Inside it is a [RemoveColorSample] per colour
## that background turned out to be, each with its own tolerance; the editor under the
## list writes all of them at once, and the expander below it opens them up. Sweeping a
## rectangle over a scanned white gives one row and the several near-whites it really
## is. See [RemoveColorEntry].
##
## Owns the list and its buttons, but neither the picking nor the storage. Only
## the dock can see the preview, so it listens for [signal pick_toggled] and
## routes the sampled colours back in through [method add_region].
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

const ToolButton := preload("res://addons/image_wrangler/ui/iw_tool_button.gd")
const EntryList := preload("res://addons/image_wrangler/ui/iw_entry_list.gd")

## Caption width for the editor row, matching [code]iw_settings_builder.gd[/code]
## so the tolerance slider lines up with the sliders above and below it.
const LABEL_WIDTH := 92

## Width of the swatch on a per-colour row. Narrower than the editor's, since it sits
## in an indented list rather than at the head of a form row.
const SAMPLE_SWATCH_WIDTH := 48

## What the route hint says. Said on the way in rather than left to the tooltip:
## picking a colour the flood has no route to looks like it should work and does
## nothing, and adding one is the moment that misunderstanding happens.
const ROUTE_HINT := "Reached through the other colors in the list, so keep the ones around it. Background walled off by the subject needs the Island Picker."

var _operation: IWOperation
var _property: StringName

## Whether this control answers to the pointer.
##
## Its own state rather than something set on the buttons from outside, because
## [method _update_buttons] rewrites them whenever the selection or the list changes
## and would put back whatever it worked out for itself.
var _interactive := true

var _list: EntryList
var _pick_button: Button
var _add_button: Button
var _remove_button: Button
var _clear_button: Button

## Editor for the highlighted row. Hidden rather than disabled when nothing is
## selected, so the group does not show controls that edit nothing.
var _editor: HBoxContainer
var _color_button: ColorPickerButton
var _tolerance_slider: EditorSpinSlider

## Shown when the colours in the highlighted row do not all share a tolerance, so the
## number in the slider is never mistaken for a fact about the whole group.
var _mixed_label: Label

## The way into the colours of the highlighted row, and the rows it reveals. Both
## hidden for an entry of one colour, where the editor above already is that colour.
var _picks_toggle: Button
var _samples_box: VBoxContainer
## One per row currently built, in sample order, so a write through the group editor
## can be shown without rebuilding the rows under the pointer, and so a form switched
## off reaches them.
var _sample_sliders: Array[EditorSpinSlider] = []
var _sample_swatches: Array[ColorPickerButton] = []
var _sample_removes: Array[Button] = []

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
	_pick_button.tooltip_text = "Drag a region over the preview to take every color in it,\nor click once for a single pixel."
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

	_list = EntryList.new()
	# No mode dropdown: a colour describes what background *is*, where add and
	# subtract describe what to do with an area. There is nothing for a colour to
	# add.
	_list.configure(false)
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.row_selected.connect(_on_row_selected)
	_list.enabled_toggled.connect(_on_enabled_toggled)
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
	_tolerance_slider.tooltip_text = "How far a pixel may drift from this color and still be keyed out.\nRaise it if a re-compressed background leaves speckles behind.\n\nWrites every color in the highlighted row at once. Open Colors below\nto set one of them on its own."
	_tolerance_slider.value_changed.connect(_on_tolerance_changed)
	_editor.add_child(_tolerance_slider)

	_mixed_label = Label.new()
	_mixed_label.text = "mixed"
	_mixed_label.modulate = Color(1, 1, 1, 0.6)
	_mixed_label.tooltip_text = "The colors in this row have different tolerances.\nThe slider shows one of them; moving it sets them all."
	_mixed_label.visible = false
	_editor.add_child(_mixed_label)

	_picks_toggle = Button.new()
	_picks_toggle.toggle_mode = true
	_picks_toggle.flat = true
	_picks_toggle.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_picks_toggle.tooltip_text = "The colors this row keys out, each with a tolerance of its own."
	_picks_toggle.toggled.connect(func(_pressed: bool) -> void: _rebuild_sample_rows())
	_picks_toggle.visible = false
	add_child(_picks_toggle)

	_samples_box = VBoxContainer.new()
	_samples_box.add_theme_constant_override("separation", 1)
	_samples_box.visible = false
	add_child(_samples_box)

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
	# The editor theme is only reachable once the control is in the tree, and the
	# icon depends on it, so it is resolved here rather than at construction.
	if what == NOTIFICATION_THEME_CHANGED and _pick_button != null:
		ToolButton.apply_pick_icon(_pick_button)
		ToolButton.style_armed(_pick_button)


# --- Public API ---------------------------------------------------------

## Adds an entry holding [param colors], swept off [param region], and returns how many
## of them it kept.
##
## Zero means nothing was added: either the region was entirely transparent, or the
## list already keys out everything in it, which is a request to look at the row that
## does rather than for a second copy of it.
##
## The list does the thinning — see [method RemoveColorList.add_region] — because it is
## the list that knows what it already covers. What arrives here is every distinct
## colour the sweep found; what survives is the handful that are actually different
## rules.
func add_region(colors: PackedColorArray, region: Rect2i) -> int:
	var list := _color_list()
	if list == null:
		return 0
	if colors.is_empty():
		# Either it was transparent to begin with, or the stack above has already taken
		# everything under it. Both mean the same thing to the user — there is nothing
		# left there to key out — and neither is worth two messages.
		_set_hint("Nothing there to take: no pixel under that region is still solid.")
		return 0

	var entry := list.add_region(colors)
	if entry == null:
		# Silently adding a duplicate would look like nothing happened, and the
		# second entry could never claim a pixel the first had not already taken.
		var existing := list.find_claiming(colors[0])
		_set_hint("Already keyed out by the list as it stands.")
		if existing >= 0:
			_select(existing)
		return 0

	_refresh()
	_select(list.size() - 1)
	var summary := ""
	if region.size != Vector2i.ONE:
		if entry.size() >= RemoveColorList.MAX_SAMPLES:
			summary = "%d colors, which is the limit for one sweep — take what is left with another. " \
					% entry.size()
		else:
			summary = "%d colors from that region. " % entry.size()
	_set_hint(summary + ROUTE_HINT)
	colors_changed.emit()
	return entry.size()


## Redraws the rows from whatever list the operation now points at. Called when
## the settings Resource is swapped for another image.
func refresh() -> void:
	_set_hint("")
	_refresh()


## Turns every control here on or off, for a stack entry that has been switched off.
##
## Handled here rather than by walking the children from outside: the buttons are
## rewritten by [method _update_buttons] on every selection change, and the rows are
## rebuilt on every edit, so anything set from outside would survive neither.
func set_controls_enabled(value: bool) -> void:
	_interactive = value
	if _list != null:
		_list.set_interactive(value)
	_update_buttons()


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
	return _list.selected_index()


func _selected_entry() -> RemoveColorEntry:
	var colors := _color_list()
	return colors.get_at(_selected_index()) if colors != null else null


func _on_row_selected(_index: int) -> void:
	_load_editor()
	_update_buttons()


func _on_enabled_toggled(index: int, on: bool) -> void:
	var colors := _color_list()
	var entry := colors.get_at(index) if colors != null else null
	if entry == null:
		return
	entry.enabled = on
	_list.update_row(index, _row_data(index, entry))
	_set_hint("")
	colors_changed.emit()


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
	_set_hint("Set the color with the swatch, or use Pick to take one off the image.")
	colors_changed.emit()


func _on_remove_pressed() -> void:
	var index := _selected_index()
	var colors := _color_list()
	if colors == null or index < 0 or index >= colors.size():
		return
	colors.remove_at(index)
	_refresh()
	if _list.count() > 0:
		_select(mini(index, _list.count() - 1))
	else:
		_load_editor()
	_set_hint("")
	colors_changed.emit()


func _on_clear_pressed() -> void:
	var colors := _color_list()
	if colors == null or colors.is_empty():
		return
	colors.clear()
	_refresh()
	_load_editor()
	_set_hint("Nothing is keyed out from the border now. Islands still apply.")
	colors_changed.emit()


## The editor's swatch moved. Only ever shown for a row of one colour, so there is no
## question which sample it writes.
func _on_color_changed(color: Color) -> void:
	if _loading_editor:
		return
	var entry := _selected_entry()
	var sample := entry.representative() if entry != null else null
	if sample == null:
		return
	sample.color = color
	# The row carries the swatch and the value, so it has to be redrawn — but not
	# rebuilt, which would drop the selection the editor is pointing at.
	_redraw_row(_selected_index())
	colors_changed.emit()


## The group editor moved: every colour in the row takes the new tolerance.
func _on_tolerance_changed(value: float) -> void:
	if _loading_editor:
		return
	var entry := _selected_entry()
	if entry == null:
		return
	entry.set_tolerance(value)
	_mixed_label.visible = false
	# The open rows are showing values this just overwrote. Written into rather than
	# rebuilt, so dragging the group slider does not tear down the list under it.
	_loading_editor = true
	for slider in _sample_sliders:
		slider.set_value_no_signal(value)
		slider.queue_redraw()
	_loading_editor = false
	_redraw_row(_selected_index())
	colors_changed.emit()


## One colour's own swatch moved.
func _on_sample_color_changed(color: Color, sample_index: int) -> void:
	if _loading_editor:
		return
	var entry := _selected_entry()
	var sample := entry.get_sample(sample_index) if entry != null else null
	if sample == null:
		return
	sample.color = color
	# The first sample is what the row's swatch shows and what the editor above edits,
	# so changing it has to reach both.
	if sample_index == 0:
		_loading_editor = true
		_color_button.color = color
		_loading_editor = false
	_redraw_row(_selected_index())
	colors_changed.emit()


## One colour's own tolerance moved. The group may now disagree with itself, which is
## what the mixed marker is for.
func _on_sample_tolerance_changed(value: float, sample_index: int) -> void:
	if _loading_editor:
		return
	var entry := _selected_entry()
	var sample := entry.get_sample(sample_index) if entry != null else null
	if sample == null:
		return
	sample.color_tolerance = value
	_sync_tolerance_slider(entry)
	_redraw_row(_selected_index())
	colors_changed.emit()


## One colour dropped out of the highlighted row.
##
## A swept region takes what it finds, and what it finds is not always what was meant —
## a rim, a shadow, one petal the rectangle clipped. Being able to drop that one colour
## is the difference between fixing a sweep and doing it again.
func _on_sample_removed(sample_index: int) -> void:
	var index := _selected_index()
	var entry := _selected_entry()
	if entry == null:
		return
	entry.remove_sample(sample_index)

	# The last colour of a row *is* the row. An entry with no samples keys nothing out,
	# and the loader would read it as a file written before entries held more than one
	# colour and put the legacy one back — so it goes, and the selection lands somewhere
	# sensible the way Remove already does.
	if entry.is_empty():
		var colors := _color_list()
		if colors != null:
			colors.remove_at(index)
		_refresh()
		if _list.count() > 0:
			_select(mini(index, _list.count() - 1))
		else:
			_load_editor()
		_set_hint("")
		colors_changed.emit()
		return

	# Every row below the one that went is now bound to the wrong index, so they are
	# rebuilt rather than redrawn. _load_editor does that, and re-reads the group's
	# tolerance and count while it is there.
	_load_editor()
	_redraw_row(index)
	_set_hint("")
	colors_changed.emit()


func _select(index: int) -> void:
	_list.select(index)
	_load_editor()
	_update_buttons()


## Points the editor at the highlighted row, or hides it when there is none.
func _load_editor() -> void:
	var entry := _selected_entry()
	_editor.visible = entry != null
	# Nothing for one swatch to mean on a row of several. The expander below is where
	# a group's colours are edited, one at a time.
	_color_button.visible = entry != null and entry.size() <= 1
	_picks_toggle.visible = entry != null and entry.size() > 1
	if entry == null:
		_rebuild_sample_rows()
		return
	_picks_toggle.text = "Colors (%d)" % entry.size()
	var sample := entry.representative()
	# The controls are being told what the row holds, not the other way round.
	_loading_editor = true
	_color_button.color = sample.color if sample != null else Color.WHITE
	_loading_editor = false
	_sync_tolerance_slider(entry)
	_rebuild_sample_rows()


## Puts the group slider on whatever the highlighted row says, without letting it
## report the write back as an edit.
func _sync_tolerance_slider(entry: RemoveColorEntry) -> void:
	var shared := entry.shared_tolerance()
	var shown := shared
	if shared < 0.0:
		var sample := entry.representative()
		shown = sample.color_tolerance if sample != null else RemoveColorSample.DEFAULT_TOLERANCE
	_loading_editor = true
	_tolerance_slider.set_value_no_signal(shown)
	# EditorSpinSlider paints its own value, and the no-signal setter deliberately
	# skips the notification that would repaint it.
	_tolerance_slider.queue_redraw()
	_loading_editor = false
	_mixed_label.visible = shared < 0.0


## Rebuilds the per-colour rows for the highlighted entry, or clears them when there is
## nothing to show.
##
## Only while the expander is open, so a list of backgrounds costs nothing to click
## through. There is no cap on the rows because there is already one on the colours:
## see [constant RemoveColorList.MAX_SAMPLES].
func _rebuild_sample_rows() -> void:
	for child in _samples_box.get_children():
		_samples_box.remove_child(child)
		child.queue_free()
	_sample_sliders.clear()
	_sample_swatches.clear()
	_sample_removes.clear()

	var entry := _selected_entry()
	_samples_box.visible = _picks_toggle.visible and _picks_toggle.button_pressed and entry != null
	if not _samples_box.visible:
		return
	for i in entry.size():
		_samples_box.add_child(_build_sample_row(i, entry.get_sample(i)))


## One colour of the highlighted entry: its swatch and its own tolerance.
func _build_sample_row(index: int, sample: RemoveColorSample) -> Control:
	var row := HBoxContainer.new()

	var swatch := ColorPickerButton.new()
	swatch.edit_alpha = false
	swatch.custom_minimum_size = Vector2(SAMPLE_SWATCH_WIDTH, 20)
	swatch.color = sample.color if sample != null else Color.WHITE
	swatch.disabled = not _interactive
	swatch.color_changed.connect(_on_sample_color_changed.bind(index))
	row.add_child(swatch)

	var slider := EditorSpinSlider.new()
	slider.min_value = 0.0
	slider.max_value = RemoveColorEntry.MAX_TOLERANCE
	slider.step = 0.005
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.read_only = not _interactive
	slider.set_value_no_signal(
			sample.color_tolerance if sample != null else RemoveColorSample.DEFAULT_TOLERANCE)
	slider.value_changed.connect(_on_sample_tolerance_changed.bind(index))
	row.add_child(slider)

	# The same cross the stack entries carry, and grey for the same reason: a column of
	# these next to every colour a sweep found would read as a column of warnings if it
	# were red. It brightens under the pointer, which is the moment it matters.
	var remove := Button.new()
	remove.flat = true
	remove.focus_mode = Control.FOCUS_NONE
	remove.text = "✕"
	remove.add_theme_color_override(&"font_color", Color(0.62, 0.62, 0.62))
	remove.add_theme_color_override(&"font_hover_color", Color(0.92, 0.92, 0.92))
	remove.add_theme_color_override(&"font_pressed_color", Color(1.0, 1.0, 1.0))
	remove.disabled = not _interactive
	remove.tooltip_text = "Remove this color from the row.\nRemoving the last one removes the row."
	remove.pressed.connect(_on_sample_removed.bind(index))
	row.add_child(remove)

	_sample_sliders.append(slider)
	_sample_swatches.append(swatch)
	_sample_removes.append(remove)
	return row


## Rebuilds every row.
##
## Editing a row does not come through here — [method _redraw_row] rewrites one in
## place, precisely so that changing a colour or a tolerance does not disturb the
## row the editor below is pointing at.
func _refresh() -> void:
	if _list == null:
		return
	var colors := _color_list()
	var rows := []
	if colors != null:
		for i in colors.size():
			rows.append(_row_data(i, colors.get_at(i)))
	_list.set_rows(rows)
	_load_editor()
	_update_buttons()


## Rewrites one row in place, leaving the selection alone.
func _redraw_row(index: int) -> void:
	var colors := _color_list()
	var entry := colors.get_at(index) if colors != null else null
	if entry == null:
		return
	_list.update_row(index, _row_data(index, entry))


## Hex rather than floats: it is what a colour is written as everywhere else the
## user meets one, and it fits a narrow dock column where three decimals do not.
##
## A row of several says how many rather than naming one of them, since no single hex
## value would be the truth about a background that turned out to be a dozen of them.
## The swatch still shows the one most of the region was.
func _row_data(index: int, entry: RemoveColorEntry) -> Dictionary:
	if entry == null:
		return {"color": Color.MAGENTA, "text": "%d.  —" % (index + 1), "enabled": false}
	var sample := entry.representative()
	var color := sample.color if sample != null else Color.MAGENTA
	var shared := entry.shared_tolerance()
	var reading := "%.3f" % shared if shared >= 0.0 else "mixed"
	var text := ""
	if entry.size() <= 1:
		text = "%d.  #%s   %s" % [index + 1, color.to_html(false), reading]
	else:
		text = "%d.  %d colors   %s" % [index + 1, entry.size(), reading]
	return {
		"color": color,
		"text": text,
		"enabled": entry.enabled,
	}


func _update_buttons() -> void:
	_remove_button.disabled = not _interactive or _selected_index() < 0
	_clear_button.disabled = not _interactive or _list.count() == 0
	_pick_button.disabled = not _interactive
	_add_button.disabled = not _interactive
	if _color_button != null:
		_color_button.disabled = not _interactive
	if _tolerance_slider != null:
		_tolerance_slider.read_only = not _interactive
	if _picks_toggle != null:
		_picks_toggle.disabled = not _interactive
	for slider in _sample_sliders:
		slider.read_only = not _interactive
	for swatch in _sample_swatches:
		swatch.disabled = not _interactive
	for remove in _sample_removes:
		remove.disabled = not _interactive
