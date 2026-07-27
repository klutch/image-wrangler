@tool
extends VBoxContainer

## The Blackout list: regions the user draws over the preview to erase outright.
##
## Built on the same shape as the Island Picker, and differing in what a row
## holds: an island is one point and is finished the moment it is clicked, where a
## polygon is a run of points that has to be started, added to, and ended. That
## drawing session lives here rather than in the dock, because the list it is
## building lives here — the dock only owns the preview, so it forwards clicks in
## and lets this decide what they mean.
##
## The [BlackoutList] it edits is resolved through the operation's settings on
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

const SWATCH_SIZE := 14

## Floor for the rows box, which [member ItemList.auto_height] otherwise lets
## collapse to nothing while the list is empty.
const LIST_EMPTY_HEIGHT := 24

## Editor icon for the draw button. Every Node class has one, so this is always
## present, and editor icons already answer to the theme — none of the inversion
## [code]iw_pick_icon.gd[/code] does for the eyedropper artwork is needed.
const DRAW_ICON := &"Polygon2D"

var _operation: IWOperation
var _property: StringName

var _list: ItemList
var _draw_button: Button
var _remove_button: Button
var _clear_button: Button
var _hint: Label

## Row of the polygon currently being drawn, or -1 when no session is open.
##
## Tracked by index rather than by holding the [BlackoutPolygon]: the settings
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

	_remove_button = Button.new()
	_remove_button.text = "Remove"
	_remove_button.tooltip_text = "Remove the highlighted region."
	_remove_button.pressed.connect(_on_remove_pressed)
	buttons.add_child(_remove_button)

	_clear_button = Button.new()
	_clear_button.text = "Clear"
	_clear_button.tooltip_text = "Remove every region for this image."
	_clear_button.pressed.connect(_on_clear_pressed)
	buttons.add_child(_clear_button)

	_list = ItemList.new()
	# Grows with its contents rather than reserving a block of the dock whether
	# or not anything is in it.
	_list.auto_height = true
	_list.custom_minimum_size = Vector2(0, LIST_EMPTY_HEIGHT)
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.item_selected.connect(_on_item_selected)
	add_child(_list)

	_hint = Label.new()
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint.modulate = Color(1, 1, 1, 0.6)
	add_child(_hint)


func _notification(what: int) -> void:
	# The editor theme is only reachable once the control is in the tree, and the
	# icon comes out of it, so it is resolved here rather than at construction.
	if what == NOTIFICATION_THEME_CHANGED and _draw_button != null:
		if has_theme_icon(DRAW_ICON, &"EditorIcons"):
			_draw_button.icon = _drained(get_theme_icon(DRAW_ICON, &"EditorIcons"))


## [param source] with its colour taken out, leaving grey at the same lightness.
##
## Godot's node icons are colour-coded by category, so the Polygon2D artwork
## arrives blue and reads as permanently switched on. Tinting cannot fix that:
## modulation multiplies, so it can deepen a blue but never drain it. The pixels
## have to be rewritten.
##
## Draining rather than flattening to a silhouette, so the shape keeps its
## interior lines. What is left is neutral enough for the theme to colour: the
## button's own pressed tint is the editor accent, so an armed picker still goes
## blue, and now that means something.
static func _drained(source: Texture2D) -> Texture2D:
	if source == null:
		return null
	var image := source.get_image()
	if image == null:
		return null

	image = image.duplicate()
	if image.is_compressed():
		image.decompress()
	if image.get_format() != Image.FORMAT_RGBA8:
		image.convert(Image.FORMAT_RGBA8)

	# Rec. 709 luma, so a saturated blue lands as dark as it looks rather than as
	# the mid grey a flat channel average would give.
	var data := image.get_data()
	for i in range(0, data.size(), 4):
		var luma := roundi(0.2126 * data[i] + 0.7152 * data[i + 1] + 0.0722 * data[i + 2])
		data[i] = luma
		data[i + 1] = luma
		data[i + 2] = luma
	# Alpha is left alone, so the silhouette is unchanged.
	return ImageTexture.create_from_image(
			Image.create_from_data(image.get_width(), image.get_height(), false, Image.FORMAT_RGBA8, data))


# --- Public API ---------------------------------------------------------

## Redraws the rows from whatever list the operation now points at. Called when
## the settings Resource is swapped for another image.
##
## Any open drawing session belongs to the image that just left, so it is dropped
## rather than carried onto the new one.
func refresh() -> void:
	_draft = -1
	_hint.text = ""
	_refresh()


## Lets the dock switch drawing off without echoing back a [signal draw_toggled].
func set_pick_active(enabled: bool) -> void:
	_draw_button.set_pressed_no_signal(enabled)


## Row of the polygon being drawn, or -1. The dock draws that one as an open path
## with a rubber band rather than as a closed shape.
func draft_index() -> int:
	return _draft


func selected_index() -> int:
	var selection := _list.get_selected_items()
	return selection[0] if not selection.is_empty() else -1


## Every polygon's points, for the dock to hand to the preview.
func get_polygons() -> Array:
	var out := []
	var regions := _polygon_list()
	if regions == null:
		return out
	for polygon in regions.polygons:
		out.append(polygon.points if polygon != null else ([] as Array[Vector2i]))
	return out


## Every polygon's swatch colour, in the same order as [method get_polygons].
func get_colors() -> PackedColorArray:
	var out := PackedColorArray()
	var regions := _polygon_list()
	if regions == null:
		return out
	for polygon in regions.polygons:
		out.append(polygon.color if polygon != null else Color.MAGENTA)
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
	_hint.text = "Click to place corners. Right-click or Escape closes the shape."
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
	if polygon.size() >= BlackoutPolygon.MIN_POINTS and polygon.points[0] == at:
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
		_hint.text = "Region discarded."
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
		_hint.text = "Needs at least %d corners — region discarded." % BlackoutPolygon.MIN_POINTS
		return

	var finished := _draft
	_draft = -1
	_redraw_row(finished)
	_hint.text = ""
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
func _polygon_list() -> BlackoutList:
	if _operation == null:
		return null
	var settings := _operation.get_settings()
	if settings == null:
		return null
	return settings.get(_property) as BlackoutList


func _draft_polygon() -> BlackoutPolygon:
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


func _on_item_selected(_index: int) -> void:
	_update_buttons()
	selection_changed.emit()


func _on_remove_pressed() -> void:
	var index := selected_index()
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
	if _list.item_count > 0:
		_select(mini(index, _list.item_count - 1))
	_hint.text = ""
	polygons_changed.emit()
	selection_changed.emit()


func _on_clear_pressed() -> void:
	var regions := _polygon_list()
	if regions == null or regions.is_empty():
		return
	regions.clear()
	_draft = -1
	_refresh()
	_hint.text = ""
	polygons_changed.emit()
	selection_changed.emit()


func _select(index: int) -> void:
	if index < 0 or index >= _list.item_count:
		return
	_list.select(index)
	_update_buttons()
	selection_changed.emit()


func _refresh() -> void:
	if _list == null:
		return
	var regions := _polygon_list()
	_list.clear()
	if regions != null:
		for i in regions.size():
			var polygon := regions.get_at(i)
			_list.add_item(_row_text(i, polygon))
			_list.set_item_icon(i, _swatch(polygon))
	_update_buttons()


## Rewrites one row in place, leaving the selection alone — which is what lets a
## corner be added without the row being drawn losing its highlight.
func _redraw_row(index: int) -> void:
	var regions := _polygon_list()
	if regions == null or index < 0 or index >= _list.item_count:
		return
	var polygon := regions.get_at(index)
	_list.set_item_text(index, _row_text(index, polygon))
	_list.set_item_icon(index, _swatch(polygon))


## Numbered from one, since the row number is the only name a region has.
static func _row_text(index: int, polygon: BlackoutPolygon) -> String:
	if polygon == null:
		return "Region %d" % (index + 1)
	var count := polygon.size()
	return "Region %d  (%d corner%s)" % [index + 1, count, "" if count == 1 else "s"]


func _update_buttons() -> void:
	_remove_button.disabled = selected_index() < 0
	_clear_button.disabled = _list.item_count == 0


## Small bordered colour chip, matching the island picker's rows.
static func _swatch(polygon: BlackoutPolygon) -> Texture2D:
	var color := polygon.color if polygon != null else Color.MAGENTA
	var image := Image.create_empty(SWATCH_SIZE, SWATCH_SIZE, false, Image.FORMAT_RGBA8)
	image.fill(Color(0, 0, 0, 1))
	image.fill_rect(Rect2i(1, 1, SWATCH_SIZE - 2, SWATCH_SIZE - 2), color)
	return ImageTexture.create_from_image(image)
