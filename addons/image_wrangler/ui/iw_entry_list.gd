@tool
extends VBoxContainer

## Rows of entries with a swatch, a label, an optional mode dropdown, an on/off
## box and a remove cross, shared by all of the dock's list controls.
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

## Emitted when a row's remove cross is clicked.
##
## The owning control does the removing, because what a row stands for and what has to
## happen to the rest of the list when one goes are both its business — a drawing session
## to close, a selection to move, a settings Resource to write.
signal remove_requested(index: int)

## One row's controls. The scene is the source of truth for how a row looks.
const RowScene := preload("res://addons/image_wrangler/scenes/iw_entry_row.tscn")

const SWATCH_SIZE := 14

## The remove cross: what it says, and the two shades it says it in.
##
## Grey at rest so a list of eight does not read as eight buttons, white under the pointer
## so it is unmistakably a thing you can press. Flat, and the last control on the row, so
## the eye reaches the swatch and the label first — removing an entry is not what the row
## is for.
##
## The live values are on the Remove button in the row scene; these copies are what the
## test checks the scene against.
const REMOVE_GLYPH := "✕"
const REMOVE_COLOR := Color(1, 1, 1, 0.45)
const REMOVE_HOVER_COLOR := Color(1, 1, 1, 1)

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
    (row.get_node("%Check") as CheckBox).disabled = not _interactive
    (row.get_node("%Mode") as OptionButton).disabled = not _interactive
    (row.get_node("%Remove") as Button).disabled = not _interactive


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
    (row.get_node("%Swatch") as TextureRect).texture = make_swatch(entry.get("color", Color.MAGENTA))
    (row.get_node("%Text") as Label).text = String(entry.get("text", ""))
    (row.get_node("%Check") as CheckBox).button_pressed = bool(entry.get("enabled", true))
    if _shows_mode:
        var choice := row.get_node("%Mode") as OptionButton
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


## One row, instanced from the row scene and filled from [param entry]. The nodes are
## fetched by unique name on update rather than tracked in parallel arrays, which would
## need keeping in step with every insert and removal.
func _build_row(index: int, entry: Dictionary) -> PanelContainer:
    var row: PanelContainer = RowScene.instantiate()
    var enabled := bool(entry.get("enabled", true))
    row.modulate = Color.WHITE if enabled else DISABLED_MODULATE
    # The whole row is the hit target for selecting, so the click lands wherever
    # the pointer is rather than only on the text.
    row.gui_input.connect(_on_row_input.bind(index))

    (row.get_node("%Swatch") as TextureRect).texture = make_swatch(entry.get("color", Color.MAGENTA))
    (row.get_node("%Text") as Label).text = String(entry.get("text", ""))

    if _shows_mode:
        var choice := row.get_node("%Mode") as OptionButton
        choice.visible = true
        for option in IWAlphaMode.LABELS:
            choice.add_item(String(option))
        choice.selected = IWAlphaMode.sanitise(int(entry.get("mode", 0)))
        choice.item_selected.connect(
            func(selected_mode: int) -> void:
                if not _loading:
                    mode_changed.emit(index, selected_mode)
        )

    var box := row.get_node("%Check") as CheckBox
    box.button_pressed = enabled
    box.toggled.connect(
        func(on: bool) -> void:
            if not _loading:
                enabled_toggled.emit(index, on)
    )

    var cross := row.get_node("%Remove") as Button
    cross.pressed.connect(
        func() -> void:
            if not _loading and _interactive:
                remove_requested.emit(index)
    )
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
##
## Public because the island picker draws the same chip beside each pixel inside a
## group, and two of these drifting apart would be two sizes of the same thing in one
## control.
static func make_swatch(color: Color) -> Texture2D:
    var image := Image.create_empty(SWATCH_SIZE, SWATCH_SIZE, false, Image.FORMAT_RGBA8)
    image.fill(Color(0, 0, 0, 1))
    image.fill_rect(Rect2i(1, 1, SWATCH_SIZE - 2, SWATCH_SIZE - 2), color)
    return ImageTexture.create_from_image(image)
