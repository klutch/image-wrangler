@tool
extends VBoxContainer

## The Polygon Edit list: regions the user draws over the preview to cut away or
## force opaque.
##
## Built on the same shape as the Island Picker, and differing in what a row
## holds: an island is one point and is finished the moment it is clicked, where a
## polygon is a run of points that has to be started, added to, and ended. That
## drawing session lives here rather than in the dock, because the list it is
## building lives here — the dock only owns the preview, so it forwards clicks in
## and lets this decide what they mean.
##
## The [PolygonRegionList] it edits is resolved through the operation's settings on
## every access, so when the dock swaps in another image's settings this control
## follows without being told — it only needs a [method refresh] to redraw.

## Emitted when the draw button is toggled. The dock puts the preview into
## crosshair mode in response, and switches any other picker off.
signal draw_toggled(enabled: bool)

## Emitted whenever the list or any polygon on it changes, so the dock can re-run
## the preview and save the settings against the current image.
signal polygons_changed

## Emitted when a different row is highlighted, or when the draft changes, so the
## dock can redraw the overlay.
signal selection_changed

const ToolButton := preload("res://addons/image_wrangler/ui/iw_tool_button.gd")
const EntryList := preload("res://addons/image_wrangler/ui/iw_entry_list.gd")

## Editor icon for the draw button. Every Node class has one, so this is always
## present — though its colour has to be taken out first, since node icons are
## colour-coded and a blue one reads as permanently armed.
const DRAW_ICON := &"Polygon2D"

var _operation: IWOperation
var _property: StringName

## Whether this control answers to the pointer.
##
## Its own state rather than something set on the buttons from outside, because
## [method _update_buttons] rewrites them whenever the selection or the list changes
## and would put back whatever it worked out for itself.
var _interactive := true

var _list: EntryList
var _draw_button: Button
var _clear_button: Button
var _hint: Label

## Row of the polygon currently being drawn, or -1 when no session is open.
##
## Tracked by index rather than by holding the [PolygonRegion]: the settings
## Resource under this control can be swapped for another image mid-draw, and a
## held reference would go on collecting points into an object no longer on any
## list.
var _draft := -1


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

	_draw_button = Button.new()
	_draw_button.text = "Draw"
	_draw_button.toggle_mode = true
	_draw_button.tooltip_text = "Click the preview to place corners.\nRight-click, press Escape, or click the first corner again to close the\nshape. Backspace takes back the last corner."
	_draw_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_draw_button.toggled.connect(func(pressed: bool) -> void: draw_toggled.emit(pressed))
	buttons.add_child(_draw_button)

	_clear_button = Button.new()
	_clear_button.text = "Clear"
	_clear_button.tooltip_text = "Remove every region for this image."
	_clear_button.pressed.connect(_on_clear_pressed)
	buttons.add_child(_clear_button)

	_list = EntryList.new()
	_list.configure(true)
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.row_selected.connect(_on_row_selected)
	_list.enabled_toggled.connect(_on_enabled_toggled)
	_list.mode_changed.connect(_on_mode_changed)
	_list.remove_requested.connect(_remove_entry)
	add_child(_list)

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
	# icon comes out of it, so it is resolved here rather than at construction.
	if what == NOTIFICATION_THEME_CHANGED and _draw_button != null:
		ToolButton.apply_theme_icon(_draw_button, DRAW_ICON)
		ToolButton.style_armed(_draw_button)


# --- Public API ---------------------------------------------------------

## Redraws the rows from whatever list the operation now points at. Called when
## the settings Resource is swapped for another image.
##
## Any open drawing session belongs to the image that just left, so it is dropped
## rather than carried onto the new one.
## Turns every control here on or off, for a stack entry that has been switched off.
## See [method IWColorList.set_controls_enabled].
func set_controls_enabled(value: bool) -> void:
	_interactive = value
	if _list != null:
		_list.set_interactive(value)
	_update_buttons()


func refresh() -> void:
	_draft = -1
	_set_hint("")
	_refresh()


## Lets the dock switch drawing off without echoing back a [signal draw_toggled].
func set_pick_active(enabled: bool) -> void:
	_draw_button.set_pressed_no_signal(enabled)


## Row of the polygon being drawn, or -1. The dock draws that one as an open path
## with a rubber band rather than as a closed shape.
func draft_index() -> int:
	return _draft


func selected_index() -> int:
	return _list.selected_index()


## Every polygon's points, for the dock to hand to the preview.
func get_polygons() -> Array:
	var out := []
	var regions := _polygon_list()
	if regions == null:
		return out
	for polygon in regions.regions:
		out.append(polygon.points if polygon != null else ([] as Array[Vector2i]))
	return out


## Every polygon's swatch colour, in the same order as [method get_polygons].
func get_colors() -> PackedColorArray:
	var out := PackedColorArray()
	var regions := _polygon_list()
	if regions == null:
		return out
	for polygon in regions.regions:
		out.append(polygon.color if polygon != null else Color.MAGENTA)
	return out


## Whether each region is switched on, in the same order. A region that is off
## still draws — the shape took work to make and is worth seeing while it is set
## aside — so the preview needs to know which to draw as inert.
func get_enabled_flags() -> PackedByteArray:
	var out := PackedByteArray()
	var regions := _polygon_list()
	if regions == null:
		return out
	for polygon in regions.regions:
		out.append(1 if polygon != null and polygon.enabled else 0)
	return out


## Opens a drawing session, appending an empty polygon to collect into.
func begin_polygon() -> void:
	var regions := _polygon_list()
	if regions == null:
		return
	regions.add()
	_draft = regions.size() - 1
	_refresh()
	_list.select(_draft)
	_update_buttons()
	_set_hint("Click to place corners. Right-click or Escape closes the shape.")
	selection_changed.emit()


## Adds a corner to the open session, starting one if none is open.
##
## Returns [code]true[/code] when the click landed on the first corner, which is
## a request to close rather than a corner of its own. The dock finishes the
## polygon in that case.
func add_vertex(at: Vector2i) -> bool:
	if _draft < 0:
		begin_polygon()
	var polygon := _draft_polygon()
	if polygon == null:
		return false

	# Clicking the first corner again closes the shape, but only once there is a
	# shape to close — otherwise the second click of a double-click on the first
	# corner would end the polygon before it began.
	if polygon.size() >= PolygonRegion.MIN_POINTS and polygon.points[0] == at:
		return true
	# A corner placed exactly on the previous one is a double-click or a jitter,
	# not a request for a zero-length edge.
	if polygon.size() > 0 and polygon.points[polygon.size() - 1] == at:
		return false

	polygon.add(at)
	_redraw_row(_draft)
	_update_buttons()
	selection_changed.emit()
	return false


## Takes back the last corner placed. Closes the session if that empties it.
func undo_vertex() -> void:
	var polygon := _draft_polygon()
	if polygon == null:
		return
	polygon.remove_last()
	if polygon.is_empty():
		_discard_draft()
		_set_hint("Region discarded.")
		return
	_redraw_row(_draft)
	_update_buttons()
	selection_changed.emit()


## Ends the open session, keeping the polygon only if it encloses anything.
func finish_polygon() -> void:
	var polygon := _draft_polygon()
	if polygon == null:
		_draft = -1
		return

	if not polygon.is_drawable():
		_discard_draft()
		# Said rather than left silent: a shape vanishing on close looks like a
		# bug unless the reason is on screen.
		_set_hint("Needs at least %d corners — region discarded." % PolygonRegion.MIN_POINTS)
		return

	var finished := _draft
	_draft = -1
	_redraw_row(finished)
	_set_hint("")
	_update_buttons()
	selection_changed.emit()
	polygons_changed.emit()


## Moves one corner of one polygon, for the preview's drag handles.
##
## Deliberately does not emit [signal polygons_changed]: a drag fires on every
## mouse motion, and re-running the operation that often would be unusable. The
## dock re-runs once the drag ends.
func move_vertex(polygon_index: int, vertex: int, to: Vector2i) -> void:
	var regions := _polygon_list()
	if regions == null:
		return
	var polygon := regions.get_at(polygon_index)
	if polygon == null:
		return
	polygon.set_point(vertex, to)
	selection_changed.emit()


# --- Internals ----------------------------------------------------------

## The list this control edits, resolved through the operation every time so that
## swapping the settings Resource for another image needs no re-pointing here.
func _polygon_list() -> PolygonRegionList:
	if _operation == null:
		return null
	var settings := _operation.get_settings()
	if settings == null:
		return null
	return settings.get(_property) as PolygonRegionList


func _draft_polygon() -> PolygonRegion:
	var regions := _polygon_list()
	return regions.get_at(_draft) if regions != null else null


## Throws away the polygon being drawn and closes the session.
func _discard_draft() -> void:
	var regions := _polygon_list()
	if regions != null and _draft >= 0:
		regions.remove_at(_draft)
	_draft = -1
	_refresh()
	selection_changed.emit()


func _on_row_selected(_index: int) -> void:
	_update_buttons()
	selection_changed.emit()


func _on_enabled_toggled(index: int, on: bool) -> void:
	var regions := _polygon_list()
	var polygon := regions.get_at(index) if regions != null else null
	if polygon == null:
		return
	polygon.enabled = on
	_redraw_row(index)
	_set_hint("")
	polygons_changed.emit()
	# The preview draws a switched-off region differently, so the overlay has to
	# be told even though no geometry moved.
	selection_changed.emit()


func _on_mode_changed(index: int, mode: int) -> void:
	var regions := _polygon_list()
	var polygon := regions.get_at(index) if regions != null else null
	if polygon == null:
		return
	polygon.mode = IWAlphaMode.sanitise(mode)
	_redraw_row(index)
	_set_hint("")
	polygons_changed.emit()



## Takes one row off the list, whether the button asked or a row's own cross did.
func _remove_entry(index: int) -> void:
	var regions := _polygon_list()
	if regions == null or index < 0 or index >= regions.size():
		return
	# Removing the row being drawn ends the session with it, rather than leaving
	# the draft index pointing at whatever slid into that slot.
	if index == _draft:
		_draft = -1
	elif _draft > index:
		_draft -= 1
	regions.remove_at(index)
	_refresh()
	if _list.count() > 0:
		_select(mini(index, _list.count() - 1))
	_set_hint("")
	polygons_changed.emit()
	selection_changed.emit()


func _on_clear_pressed() -> void:
	var regions := _polygon_list()
	if regions == null or regions.is_empty():
		return
	regions.clear()
	_draft = -1
	_refresh()
	_set_hint("")
	polygons_changed.emit()
	selection_changed.emit()


func _select(index: int) -> void:
	_list.select(index)
	_update_buttons()
	selection_changed.emit()


func _refresh() -> void:
	if _list == null:
		return
	var regions := _polygon_list()
	var rows := []
	if regions != null:
		for i in regions.size():
			rows.append(_row_data(i, regions.get_at(i)))
	_list.set_rows(rows)
	_update_buttons()


## Rewrites one row in place, leaving the selection alone — which is what lets a
## corner be added without the row being drawn losing its highlight.
func _redraw_row(index: int) -> void:
	var regions := _polygon_list()
	var polygon := regions.get_at(index) if regions != null else null
	if polygon == null:
		return
	_list.update_row(index, _row_data(index, polygon))


## Numbered from one, since the row number is the only name a region has.
func _row_data(index: int, polygon: PolygonRegion) -> Dictionary:
	if polygon == null:
		return {"color": Color.MAGENTA, "text": "Region %d" % (index + 1), "enabled": false}
	var count := polygon.size()
	return {
		"color": polygon.color,
		"text": "%d.  %d corner%s" % [index + 1, count, "" if count == 1 else "s"],
		"enabled": polygon.enabled,
		"mode": polygon.mode,
	}


func _update_buttons() -> void:
	_clear_button.disabled = not _interactive or _list.count() == 0
	_draw_button.disabled = not _interactive
