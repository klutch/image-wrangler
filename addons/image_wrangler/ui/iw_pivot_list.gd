@tool
extends VBoxContainer

## The Pivots list on the Export tab: the sprites whose pivot has been set by hand.
##
## Built on the same shape as the Polygon Edit list — an arming button, a Clear, and a row
## per entry. What differs is that the sheet already has a pivot for every sprite whether or
## not it is on this list: a row is an override of the middle-and-facing-up default, so an
## empty list is a full set of pivots rather than none.
##
## The [PivotList] it edits is resolved through the packing settings on every access, so a
## batch swapped underneath this control needs only a [method refresh].

## Emitted when the Edit button is toggled. The dock arms the preview in response.
signal edit_toggled(enabled: bool)

## Emitted whenever the list changes, so the dock can save it and redraw the overlay.
signal pivots_changed

## Emitted when a different row is highlighted, so the dock can redraw the overlay.
signal selection_changed

const ToolButton := preload("res://addons/image_wrangler/ui/iw_tool_button.gd")
const EntryList := preload("res://addons/image_wrangler/ui/iw_entry_list.gd")
const PreviewView := preload("res://addons/image_wrangler/ui/iw_preview_view.gd")

## Editor icon for the Edit button.
const EDIT_ICON := &"EditorPivot"

var _operation: IWOperation
var _property: StringName

## Whether this control answers to the pointer. See [code]IWPolygonList._interactive[/code].
var _interactive := true

var _list: EntryList
var _edit_button: Button
var _clear_button: Button
var _hint: Label


## Binds this control to [param property] on [param operation]. Safe to call again: the
## rows are rebuilt, the buttons are not.
func setup(operation: IWOperation, property: StringName) -> void:
    _operation = operation
    _property = property
    if _list == null:
        _build()
    _refresh()


## The tree lives in scenes/iw_pivot_list.tscn; this fetches it and wires it up.
func _build() -> void:
    _edit_button = %EditButton
    _clear_button = %ClearButton
    _list = %List
    _hint = %Hint

    _edit_button.toggled.connect(func(pressed: bool) -> void: edit_toggled.emit(pressed))
    _clear_button.pressed.connect(_on_clear_pressed)
    _list.configure(false)
    _list.row_selected.connect(_on_row_selected)
    _list.enabled_toggled.connect(_on_enabled_toggled)
    _list.remove_requested.connect(_remove_entry)


## Shows [param text] under the list, or gives the line back when it is empty. See
## [code]IWPolygonList._set_hint[/code].
func _set_hint(text: String) -> void:
    _hint.text = text
    _hint.visible = not text.is_empty()


func _notification(what: int) -> void:
    if what == NOTIFICATION_THEME_CHANGED and _edit_button != null:
        ToolButton.apply_theme_icon(_edit_button, EDIT_ICON)
        ToolButton.style_armed(_edit_button)


# --- Public API ---------------------------------------------------------

## Turns every control here on or off, for a tab with no sheet to point at.
func set_controls_enabled(value: bool) -> void:
    _interactive = value
    if _list != null:
        _list.set_interactive(value)
    _update_buttons()


func refresh() -> void:
    _set_hint("")
    _refresh()


## Lets the dock switch editing off without echoing back an [signal edit_toggled].
func set_pick_active(enabled: bool) -> void:
    if _edit_button != null:
        _edit_button.set_pressed_no_signal(enabled)


func selected_index() -> int:
    return _list.selected_index() if _list != null else -1


## The sprite the highlighted row belongs to, or -1 when no row is picked.
##
## The dock draws that sprite's pivot larger, which is the only way to find one row's
## worth on a sheet of a hundred.
func selected_sprite() -> int:
    var pivots := pivot_list()
    var pivot := pivots.get_at(selected_index()) if pivots != null else null
    return pivot.sprite if pivot != null else -1


## The list this control edits, or null while nothing is bound.
func pivot_list() -> PivotList:
    if _operation == null:
        return null
    var settings := _operation.get_settings()
    if settings == null:
        return null
    return settings.get(_property) as PivotList


## Points [param sprite]'s pivot at [param offset] facing [param facing], and highlights the
## row it landed on. [param offset] is measured from the sprite's top-left corner.
func set_pivot(sprite: int, offset: Vector2, facing: Vector2) -> void:
    var pivots := pivot_list()
    if pivots == null:
        return
    var row := pivots.set_pivot(sprite, offset, facing)
    _refresh()
    _list.select(row)
    _set_hint("")
    pivots_changed.emit()
    selection_changed.emit()


# --- Internals ----------------------------------------------------------

func _on_row_selected(_index: int) -> void:
    _update_buttons()
    selection_changed.emit()


func _on_enabled_toggled(index: int, on: bool) -> void:
    var pivots := pivot_list()
    var pivot := pivots.get_at(index) if pivots != null else null
    if pivot == null:
        return
    pivot.enabled = on
    _redraw_row(index)
    _set_hint("")
    pivots_changed.emit()
    selection_changed.emit()


func _remove_entry(index: int) -> void:
    var pivots := pivot_list()
    if pivots == null or index < 0 or index >= pivots.size():
        return
    pivots.remove_at(index)
    _refresh()
    if _list.count() > 0:
        _list.select(mini(index, _list.count() - 1))
    _set_hint("")
    pivots_changed.emit()
    selection_changed.emit()


func _on_clear_pressed() -> void:
    var pivots := pivot_list()
    if pivots == null or pivots.is_empty():
        return
    pivots.clear()
    _refresh()
    _set_hint("")
    pivots_changed.emit()
    selection_changed.emit()


func _refresh() -> void:
    if _list == null:
        return
    var pivots := pivot_list()
    var rows := []
    if pivots != null:
        for i in pivots.size():
            rows.append(_row_data(pivots.get_at(i)))
    _list.set_rows(rows)
    _update_buttons()


func _redraw_row(index: int) -> void:
    var pivots := pivot_list()
    var pivot := pivots.get_at(index) if pivots != null else null
    if pivot != null:
        _list.update_row(index, _row_data(pivot))


## A row names its sprite, where the pivot sits inside it and which way it faces.
##
## The swatch is the same colour the preview paints that sprite's tile patch, so a row and
## the sprite it belongs to can be matched by eye rather than by counting.
func _row_data(pivot: Pivot) -> Dictionary:
    if pivot == null:
        return {"color": Color.MAGENTA, "text": "Pivot", "enabled": false}
    return {
        "color": _sprite_color(pivot.sprite),
        "text": "Sprite %d  (%d, %d)  %d°" % [pivot.sprite + 1,
                roundi(pivot.offset.x), roundi(pivot.offset.y),
                roundi(Pivot.bearing_of(pivot.direction))],
        "enabled": pivot.enabled,
    }


func _sprite_color(sprite: int) -> Color:
    if sprite < 0:
        return Color.MAGENTA
    return Color.from_hsv(fmod(float(sprite) * PreviewView.TILE_HUE_STEP, 1.0),
            PreviewView.TILE_SATURATION, PreviewView.TILE_VALUE)


func _update_buttons() -> void:
    _clear_button.disabled = not _interactive or _list.count() == 0
    _edit_button.disabled = not _interactive
