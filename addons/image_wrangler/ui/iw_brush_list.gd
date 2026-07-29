@tool
extends VBoxContainer

## The Brush Edit list: strokes the user drags over the preview to erase or paint solid.
##
## Built on the shape the other three list controls share, and borrowing from two of them:
## the drawing session from [code]iw_polygon_list.gd[/code], since a stroke has to be
## started, extended and ended rather than finished by one click; and the per-row editor
## from [code]iw_hsv_list.gd[/code], since a stroke carries settings of its own.
##
## [b]One pair of sliders, not two.[/b] The radius and sharpness edit the highlighted
## stroke when there is one, and the brush the next stroke will be drawn at when there is
## not. Two pairs — one for the tool, one for the selection — was the obvious layout and
## the wrong one: they sit a centimetre apart, say the same two words, and there is no
## reading of the form that tells you which is which. The caption above them does that
## instead, and there is only ever one thing to reach for.
##
## Drawing deliberately does not highlight the stroke it just made. Painting a series of
## strokes at one brush is the ordinary case, and selecting each one as it landed would
## repoint the sliders at it and turn every following adjustment into an edit of the last
## stroke rather than a change of brush.
##
## The [BrushStrokeList] it edits is resolved through the operation's settings on every
## access, so when the dock swaps in another image's settings this control follows without
## being told — it only needs a [method refresh] to redraw.

## Emitted when the draw button is toggled. The dock puts the preview into stroke mode in
## response, and switches any other picker off.
signal draw_toggled(enabled: bool)

## Emitted whenever the list or any stroke on it changes, so the dock can re-run the
## preview and save the settings against the current image.
signal strokes_changed

## Emitted when a different row is highlighted, or while a stroke is being drawn, so the
## dock can redraw the overlay.
signal selection_changed

const ToolButton := preload("res://addons/image_wrangler/ui/iw_tool_button.gd")
const EntryList := preload("res://addons/image_wrangler/ui/iw_entry_list.gd")

## Editor icon for the draw button. Every Node class has one, so this is always present —
## though its colour has to be taken out first, since node icons are colour-coded and a
## blue one reads as permanently armed.
const DRAW_ICON := &"Line2D"

var _operation: IWOperation
var _property: StringName

## Whether this control answers to the pointer.
##
## Its own state rather than something set on the buttons from outside, because
## [method _update_buttons] rewrites them whenever the selection or the list changes and
## would put back whatever it worked out for itself.
var _interactive := true

var _list: EntryList
var _draw_button: Button
var _remove_button: Button
var _clear_button: Button
var _caption: Label
var _radius: EditorSpinSlider
var _sharpness: EditorSpinSlider
var _hint: Label

## Set while the sliders are being pointed at another stroke, so their change signal does
## not write the one that was selected a moment ago.
var _loading_editor := false

## Row of the stroke currently being drawn, or -1 when no drag is in flight.
##
## Tracked by index rather than by holding the [BrushStroke]: the settings Resource under
## this control can be swapped for another image mid-drag, and a held reference would go on
## collecting points into an object no longer on any list.
var _draft := -1


## Binds this control to [param property] on [param operation].
func setup(operation: IWOperation, property: StringName) -> void:
    _operation = operation
    _property = property
    _build()
    _refresh()


func _build() -> void:
    # Buttons first so they sit flush under the group heading. This control has no title
    # of its own — the settings form already provides one.
    var buttons := HBoxContainer.new()
    add_child(buttons)

    _draw_button = Button.new()
    _draw_button.text = "Draw"
    _draw_button.toggle_mode = true
    _draw_button.tooltip_text = "Drag over the preview to paint a stroke. Each drag is one entry.\n\nA click without moving puts down a single dab. Press Escape or right-click\nto stop drawing."
    _draw_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    _draw_button.toggled.connect(func(pressed: bool) -> void: draw_toggled.emit(pressed))
    buttons.add_child(_draw_button)

    _remove_button = Button.new()
    _remove_button.text = "Remove"
    _remove_button.tooltip_text = "Remove the highlighted stroke."
    _remove_button.pressed.connect(_on_remove_pressed)
    buttons.add_child(_remove_button)

    _clear_button = Button.new()
    _clear_button.text = "Clear"
    _clear_button.tooltip_text = "Remove every stroke for this image."
    _clear_button.pressed.connect(_on_clear_pressed)
    buttons.add_child(_clear_button)

    # Says what the two sliders under it are pointed at, which is the whole of what stops
    # one pair of sliders being ambiguous. See the class note.
    _caption = Label.new()
    _caption.modulate = Color(1, 1, 1, 0.6)
    _caption.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
    add_child(_caption)

    _radius = _add_slider("Radius", BrushStroke.MIN_RADIUS, BrushStroke.MAX_RADIUS, 1, true,
            "How wide the brush is, in pixels out from the centre.\n\n1 is a single pixel, 2 is three across, 3 is five, and so on — so the\nsmallest setting is the pencil it looks like rather than a five-pixel cross.")
    _sharpness = _add_slider("Sharpness", 0.0, 1.0, 0.01, false,
            "How hard the edge of the brush is.\n\nAt 1 the stroke has a hard rim. Below that it ramps to nothing over the\nouter part of the brush, and at 0 the ramp runs the whole way from the\ncentre. The centre is solid at every setting, so a one-pixel brush still\npaints however soft it is set.")

    _list = EntryList.new()
    _list.configure(true)
    _list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    _list.row_selected.connect(_on_row_selected)
    _list.enabled_toggled.connect(_on_enabled_toggled)
    _list.mode_changed.connect(_on_mode_changed)
    add_child(_list)

    _hint = Label.new()
    _hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    _hint.modulate = Color(1, 1, 1, 0.6)
    _hint.visible = false
    add_child(_hint)


func _add_slider(label: String, low: float, high: float, step: float, whole: bool,
        hint: String) -> EditorSpinSlider:
    var slider := EditorSpinSlider.new()
    slider.label = label
    slider.min_value = low
    slider.max_value = high
    slider.step = step
    slider.rounded = whole
    slider.tooltip_text = hint
    slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    slider.value_changed.connect(_on_slider_changed)
    add_child(slider)
    return slider


func _notification(what: int) -> void:
    # The editor theme is only reachable once the control is in the tree, and the icon
    # comes out of it, so it is resolved here rather than at construction.
    if what == NOTIFICATION_THEME_CHANGED and _draw_button != null:
        ToolButton.apply_theme_icon(_draw_button, DRAW_ICON)
        ToolButton.style_armed(_draw_button)


# --- What the dock asks of every picker ---------------------------------

## Redraws the rows from whatever list the operation now points at. Called when the
## settings Resource is swapped for another image.
##
## Any drag in flight belongs to the image that just left, so it is dropped rather than
## carried onto the new one.
func refresh() -> void:
    _draft = -1
    _set_hint("")
    _refresh()


## Lets the dock switch drawing off without echoing back a [signal draw_toggled].
func set_pick_active(enabled: bool) -> void:
    _draw_button.set_pressed_no_signal(enabled)


## Turns every control here on or off, for a stack entry that has been switched off.
func set_controls_enabled(value: bool) -> void:
    _interactive = value
    if _list != null:
        _list.set_interactive(value)
    _update_buttons()


func selected_index() -> int:
    return _list.selected_index() if _list != null else -1


## Row of the stroke being drawn, or -1. The dock draws that one live, so the paint can be
## seen going down before the run that renders it lands.
func draft_index() -> int:
    return _draft


## The stroke being drawn, or null. The dock reads the brush off it so that its live paint
## is laid down at the same width and softness the stage will use.
func draft_stroke() -> BrushStroke:
    return _draft_stroke()


## Every stroke's path, for the dock to hand to the preview.
func get_paths() -> Array:
    var out := []
    var strokes := _stroke_list()
    if strokes == null:
        return out
    for stroke in strokes.strokes:
        out.append(stroke.points if stroke != null else ([] as Array[Vector2i]))
    return out


## Every stroke's brush radius, in the same order as [method get_paths].
func get_radii() -> PackedInt32Array:
    var out := PackedInt32Array()
    var strokes := _stroke_list()
    if strokes == null:
        return out
    for stroke in strokes.strokes:
        out.append(stroke.radius if stroke != null else BrushStroke.MIN_RADIUS)
    return out


## Whether each stroke is switched on, in the same order.
func get_enabled_flags() -> PackedByteArray:
    var out := PackedByteArray()
    var strokes := _stroke_list()
    if strokes == null:
        return out
    for stroke in strokes.strokes:
        out.append(1 if stroke != null and stroke.enabled else 0)
    return out


# --- The drawing session ------------------------------------------------

## Opens a stroke at [param at], on the brush the sliders are currently set to.
func begin_stroke(at: Vector2i) -> void:
    var strokes := _stroke_list()
    if strokes == null:
        return
    # A drag arriving while one is somehow still open ends that one rather than being
    # collected into it — two strokes in one entry would be undeletable separately.
    if _draft >= 0:
        finish_stroke()
    var settings := _settings()
    var stroke := strokes.add(
            int(settings.brush_radius) if settings != null else BrushStroke.MIN_RADIUS,
            float(settings.brush_sharpness) if settings != null else 1.0)
    stroke.extend(at)
    _draft = strokes.size() - 1
    _refresh_rows()
    _set_hint("Painting. Release to finish the stroke.")
    # The overlay drops the highlighted stroke's outline while one is being drawn, so it
    # still has to hear about the start — just not about every point after it.
    selection_changed.emit()


## Adds a point to the open stroke.
##
## Deliberately emits nothing. [signal strokes_changed] would re-run the stack, which a
## drag reporting many times a second cannot afford; [signal selection_changed] would
## rebuild the overlay, and there is no longer anything in it that a growing stroke
## changes — the paint going down is shown by the dock repainting the image itself. What is
## left is the row's own label, which is one Label write.
func extend_stroke(at: Vector2i) -> void:
    var stroke := _draft_stroke()
    if stroke == null:
        return
    if not stroke.extend(at):
        return
    _redraw_row(_draft)


## Ends the open stroke, keeping it only if it put any paint down.
func finish_stroke() -> void:
    var stroke := _draft_stroke()
    if stroke == null:
        _draft = -1
        return

    if not stroke.is_drawable():
        # Never seen in practice — a press reports a point before anything can release —
        # but a stroke of no points would sit on the list doing nothing and looking like
        # a bug.
        _discard_draft()
        _set_hint("Nothing painted — stroke discarded.")
        return

    var finished := _draft
    _draft = -1
    _redraw_row(finished)
    _set_hint("")
    _update_buttons()
    selection_changed.emit()
    strokes_changed.emit()


# --- Internals ----------------------------------------------------------

## The settings Resource behind this control, or null.
func _settings() -> Resource:
    return _operation.get_settings() if _operation != null else null


## The list this control edits, resolved through the operation every time so that swapping
## the settings Resource for another image needs no re-pointing here.
func _stroke_list() -> BrushStrokeList:
    var settings := _settings()
    if settings == null:
        return null
    return settings.get(_property) as BrushStrokeList


func _draft_stroke() -> BrushStroke:
    var strokes := _stroke_list()
    return strokes.get_at(_draft) if strokes != null else null


func _selected_stroke() -> BrushStroke:
    var strokes := _stroke_list()
    return strokes.get_at(selected_index()) if strokes != null else null


## Throws away the stroke being drawn and closes the session.
func _discard_draft() -> void:
    var strokes := _stroke_list()
    if strokes != null and _draft >= 0:
        strokes.remove_at(_draft)
    _draft = -1
    _refresh()
    selection_changed.emit()


func _refresh() -> void:
    _refresh_rows()
    _load_editor()
    _update_buttons()


func _refresh_rows() -> void:
    if _list == null:
        return
    var strokes := _stroke_list()
    var rows := []
    if strokes != null:
        for i in strokes.size():
            rows.append(_row_data(i, strokes.get_at(i)))
    _list.set_rows(rows)


## Rewrites one row in place, leaving the selection alone — which is what lets a stroke
## grow under the pointer without the list being rebuilt on every motion event.
func _redraw_row(index: int) -> void:
    var strokes := _stroke_list()
    var stroke := strokes.get_at(index) if strokes != null else null
    if stroke == null:
        return
    _list.update_row(index, _row_data(index, stroke))


## Numbered from one, since the row number is the only name a stroke has.
##
## The length is in path points rather than in painted pixels: what is stored is the path,
## and a count of pixels would be a number this control would have to paint the stroke to
## know.
func _row_data(index: int, stroke: BrushStroke) -> Dictionary:
    if stroke == null:
        return {"color": Color.MAGENTA, "text": "Stroke %d" % (index + 1), "enabled": false}
    return {
        "color": stroke.color,
        "text": "%d.  %d pt%s  r%d" % [
            index + 1, stroke.size(), "" if stroke.size() == 1 else "s", stroke.radius],
        "enabled": stroke.enabled,
        "mode": stroke.mode,
    }


## Points the sliders at the highlighted stroke, or at the brush when nothing is selected,
## and says which in the caption.
func _load_editor() -> void:
    var stroke := _selected_stroke()
    var settings := _settings()
    if settings == null:
        return
    _loading_editor = true
    if stroke != null:
        _caption.text = "Editing stroke %d" % (selected_index() + 1)
        _radius.value = stroke.radius
        _sharpness.value = stroke.sharpness
    else:
        _caption.text = "Brush for the next stroke"
        _radius.value = settings.brush_radius
        _sharpness.value = settings.brush_sharpness
    _loading_editor = false


func _update_buttons() -> void:
    _remove_button.disabled = not _interactive or selected_index() < 0
    _clear_button.disabled = not _interactive or _list.count() == 0
    _draw_button.disabled = not _interactive
    # read_only rather than the editable a Range has: EditorSpinSlider does not carry that
    # property, and assigning it fails at runtime rather than at parse.
    _radius.read_only = not _interactive
    _sharpness.read_only = not _interactive


## Shows [param text] under the list, or gives the line back when it is empty.
##
## Hidden rather than blanked. An empty Label still claims a line's height, and several of
## these controls in one form is a visible band of nothing in a dock with no room to spare.
func _set_hint(text: String) -> void:
    _hint.text = text
    _hint.visible = not text.is_empty()


func _on_slider_changed(_moved_to: float) -> void:
    if _loading_editor:
        return
    var stroke := _selected_stroke()
    if stroke != null:
        stroke.radius = int(_radius.value)
        stroke.sharpness = _sharpness.value
        # One row rather than the whole list, so the label follows a dragged slider
        # without the rows being rebuilt under the pointer.
        _redraw_row(selected_index())
        strokes_changed.emit()
        # The overlay draws the selected stroke at its own width, so a radius change has
        # to reach it even though the path did not move.
        selection_changed.emit()
        return

    # Nothing selected: the sliders are the brush, which changes what the next stroke gets
    # and nothing about the image. Saved rather than re-run.
    var settings := _settings()
    if settings == null:
        return
    settings.brush_radius = int(_radius.value)
    settings.brush_sharpness = _sharpness.value


func _on_row_selected(_index: int) -> void:
    _load_editor()
    _update_buttons()
    selection_changed.emit()


func _on_enabled_toggled(index: int, on: bool) -> void:
    var strokes := _stroke_list()
    var stroke := strokes.get_at(index) if strokes != null else null
    if stroke == null:
        return
    stroke.enabled = on
    _redraw_row(index)
    _set_hint("")
    strokes_changed.emit()


func _on_mode_changed(index: int, mode: int) -> void:
    var strokes := _stroke_list()
    var stroke := strokes.get_at(index) if strokes != null else null
    if stroke == null:
        return
    stroke.mode = IWAlphaMode.sanitise(mode)
    _redraw_row(index)
    _set_hint("")
    strokes_changed.emit()
    # The overlay tells Add and Subtract apart, so it has to be redrawn as well.
    selection_changed.emit()


func _on_remove_pressed() -> void:
    var index := selected_index()
    var strokes := _stroke_list()
    if strokes == null or index < 0 or index >= strokes.size():
        return
    # Removing the row being drawn ends the drag with it, rather than leaving the draft
    # index pointing at whatever slid into that slot.
    if index == _draft:
        _draft = -1
    elif _draft > index:
        _draft -= 1
    strokes.remove_at(index)
    _refresh()
    if _list.count() > 0:
        _list.select(mini(index, _list.count() - 1))
    _load_editor()
    _update_buttons()
    _set_hint("")
    strokes_changed.emit()
    selection_changed.emit()


func _on_clear_pressed() -> void:
    var strokes := _stroke_list()
    if strokes == null or strokes.is_empty():
        return
    strokes.clear()
    _draft = -1
    _refresh()
    _set_hint("")
    strokes_changed.emit()
    selection_changed.emit()
