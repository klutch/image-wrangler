@tool
extends VBoxContainer

## Rows of entries with a swatch, a label, an optional mode dropdown and an
## on/off box, shared by all three of the dock's list controls.
##
## Replaces the [ItemList] these used to be. An ItemList row is an icon and a
## string and nothing else — there is no way to sit a [CheckBox] or an
## [OptionButton] in one — so once every entry needed a switch the rows had to
## become real controls.
##
## Hand-built rows buy two other things that were awkward before. They size to
## their contents, so a list of two takes the height of two rather than a fixed
## block of dock; and clicking a selected row can clear the selection, which an
## ItemList will not do.
##
## Knows nothing about colours, islands or polygons. The owning control hands it
## plain row data and gets back indices.

## Emitted when the highlighted row changes. -1 means nothing is selected.
signal row_selected(index: int)

## Emitted when a row's on/off box is clicked.
signal enabled_toggled(index: int, on: bool)

## Emitted when a row's mode dropdown changes. See [IWAlphaMode].
signal mode_changed(index: int, mode: int)

const SWATCH_SIZE := 14

## Alpha of the selected row's backing. Enough to read as picked out against the
## dock, little enough that the swatch on it still reads true.
const SELECTION_ALPHA := 0.28

## Dimming on a row that is switched off, so the list says at a glance which
## entries are doing anything.
const DISABLED_MODULATE := Color(1, 1, 1, 0.45)

var _rows: Array[PanelContainer] = []
var _selected := -1

## Whether the rows answer to the pointer at all.
##
## Held as state rather than pushed onto the row controls once, because the rows are
## rebuilt from scratch on every edit — anything set on them from outside would be
## thrown away by the next [method set_rows] and quietly come back live.
var _interactive := true

## Whether rows carry a mode dropdown. Colours have no add/subtract sense — they
## describe what background is, not what to do with an area — so their list asks
## for rows without one.
var _shows_mode := false

## Set while rows are being rebuilt, so the controls being populated do not
## report themselves as user edits.
var _loading := false


func _init() -> void:
	add_theme_constant_override("separation", 1)


## Turns every row's controls, and row selection itself, on or off.
##
## Remembered, so rows built after this call come up in the same state.
func set_interactive(value: bool) -> void:
	_interactive = value
	for row in _rows:
		_apply_interactive(row)


## Applies the current state to one row's controls.
func _apply_interactive(row: PanelContainer) -> void:
	var box := row.get_meta(&"check") as CheckBox
	if box != null:
		box.disabled = not _interactive
	if row.has_meta(&"mode"):
		var choice := row.get_meta(&"mode") as OptionButton
		if choice != null:
			choice.disabled = not _interactive


## Whether rows should carry a mode dropdown. Call before the first [method set_rows].
func configure(shows_mode: bool) -> void:
	_shows_mode = shows_mode


## Rebuilds every row from [param entries], each a Dictionary of
## [code]color[/code], [code]text[/code], [code]enabled[/code] and — when the list
## shows modes — [code]mode[/code].
##
## The selection is kept when it still points at a row, since rebuilding happens
## on edits that should not throw the user's place away.
func set_rows(entries: Array) -> void:
	_loading = true
	for row in _rows:
		remove_child(row)
		row.queue_free()
	_rows.clear()

	for i in entries.size():
		var row := _build_row(i, entries[i])
		add_child(row)
		_rows.append(row)
		_apply_interactive(row)

	if _selected >= _rows.size():
		_selected = -1
	_apply_selection()
	_loading = false


## Rewrites one row without touching the rest, for an edit that changes a label
## or a swatch while the user is working in that row.
func update_row(index: int, entry: Dictionary) -> void:
	if index < 0 or index >= _rows.size():
		return
	var row := _rows[index]
	_loading = true
	var swatch := row.get_meta(&"swatch") as TextureRect
	var label := row.get_meta(&"label") as Label
	swatch.texture = _swatch(entry.get("color", Color.MAGENTA))
	label.text = String(entry.get("text", ""))
	var box := row.get_meta(&"check") as CheckBox
	box.button_pressed = bool(entry.get("enabled", true))
	if _shows_mode:
		var choice := row.get_meta(&"mode") as OptionButton
		choice.selected = IWAlphaMode.sanitise(int(entry.get("mode", 0)))
	row.modulate = Color.WHITE if bool(entry.get("enabled", true)) else DISABLED_MODULATE
	_loading = false


func selected_index() -> int:
	return _selected


func count() -> int:
	return _rows.size()


## Highlights [param index], or clears the selection when it is out of range.
## Silent: the caller already knows, so this does not emit.
func select(index: int) -> void:
	_selected = index if index >= 0 and index < _rows.size() else -1
	_apply_selection()


func _build_row(index: int, entry: Dictionary) -> PanelContainer:
	var row := PanelContainer.new()
	var enabled := bool(entry.get("enabled", true))
	row.modulate = Color.WHITE if enabled else DISABLED_MODULATE
	# The whole row is the hit target for selecting, so the click lands wherever
	# the pointer is rather than only on the text.
	row.gui_input.connect(_on_row_input.bind(index))

	var line := HBoxContainer.new()
	row.add_child(line)

	var swatch := TextureRect.new()
	swatch.texture = _swatch(entry.get("color", Color.MAGENTA))
	swatch.custom_minimum_size = Vector2(SWATCH_SIZE, SWATCH_SIZE)
	swatch.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	line.add_child(swatch)

	var label := Label.new()
	label.text = String(entry.get("text", ""))
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# The dock column is narrow and cannot scroll sideways, so a long label has to
	# give rather than set a floor under the whole panel.
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	label.mouse_filter = Control.MOUSE_FILTER_PASS
	line.add_child(label)

	var choice: OptionButton = null
	if _shows_mode:
		choice = OptionButton.new()
		for option in IWAlphaMode.LABELS:
			choice.add_item(String(option))
		choice.selected = IWAlphaMode.sanitise(int(entry.get("mode", 0)))
		choice.focus_mode = Control.FOCUS_NONE
		choice.tooltip_text = "Subtract makes this area transparent.\nAdd makes it opaque, whatever the keying decided —\nand wins wherever the two overlap."
		choice.item_selected.connect(
			func(selected_mode: int) -> void:
				if not _loading:
					mode_changed.emit(index, selected_mode)
		)
		line.add_child(choice)

	var box := CheckBox.new()
	box.button_pressed = enabled
	box.focus_mode = Control.FOCUS_NONE
	box.tooltip_text = "Include this entry. Unticked leaves it in the list but out of the result."
	box.toggled.connect(
		func(on: bool) -> void:
			if not _loading:
				enabled_toggled.emit(index, on)
	)
	line.add_child(box)

	# Fetched by name on update rather than tracked in parallel arrays, which
	# would need keeping in step with every insert and removal.
	row.set_meta(&"swatch", swatch)
	row.set_meta(&"label", label)
	row.set_meta(&"check", box)
	if choice != null:
		row.set_meta(&"mode", choice)
	return row


func _notification(what: int) -> void:
	# The accent comes out of the theme, so the highlight has to be rebuilt when
	# the theme changes under it.
	if what == NOTIFICATION_THEME_CHANGED and not _rows.is_empty():
		_apply_selection()


func _on_row_input(event: InputEvent, index: int) -> void:
	if not _interactive:
		return
	var button := event as InputEventMouseButton
	if button == null or not button.pressed or button.button_index != MOUSE_BUTTON_LEFT:
		return
	# Clicking the highlighted row clears the selection rather than reasserting
	# it, so there is a way back to nothing selected without reaching elsewhere.
	_selected = -1 if _selected == index else index
	_apply_selection()
	row_selected.emit(_selected)
	_rows[index].accept_event()


func _apply_selection() -> void:
	for i in _rows.size():
		_rows[i].add_theme_stylebox_override(&"panel", _row_style(i == _selected))


## Backing for a row. Flat accent for the selected one, nothing for the rest.
func _row_style(selected: bool) -> StyleBox:
	if not selected:
		return StyleBoxEmpty.new()
	var style := StyleBoxFlat.new()
	# Asked for rather than assumed: rows are built before this control is in the
	# tree, and reading a theme colour that is not there logs an error.
	var accent := Color(0.4, 0.6, 1.0)
	if has_theme_color(&"accent_color", &"Editor"):
		accent = get_theme_color(&"accent_color", &"Editor")
	style.bg_color = Color(accent, SELECTION_ALPHA)
	style.set_corner_radius_all(3)
	return style


## Small bordered colour chip, so a white entry is still visible on its row.
static func _swatch(color: Color) -> Texture2D:
	var image := Image.create_empty(SWATCH_SIZE, SWATCH_SIZE, false, Image.FORMAT_RGBA8)
	image.fill(Color(0, 0, 0, 1))
	image.fill_rect(Rect2i(1, 1, SWATCH_SIZE - 2, SWATCH_SIZE - 2), color)
	return ImageTexture.create_from_image(image)
