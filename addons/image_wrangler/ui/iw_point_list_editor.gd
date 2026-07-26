@tool
extends VBoxContainer

## Settings control for an [code]Array[Vector2i][/code] of picked pixels.
##
## Owns the list and its buttons, but not the picking itself: only the dock can
## see the preview, so it listens for [signal pick_toggled], routes the click
## back in through [method add_point], and mirrors the entries as markers.

## Emitted when the pick button is toggled. The dock puts the preview into
## crosshair mode in response.
signal pick_toggled(enabled: bool)

## Emitted whenever the underlying array changes, so the preview can re-run.
signal points_changed

## Emitted when a different row is highlighted, so the matching marker can be.
signal selection_changed

const SWATCH_SIZE := 14
const LIST_MIN_HEIGHT := 96

var _operation: IWOperation
var _property: StringName
var _validate := Callable()

## Colour sampled at each pick, kept purely so the rows have a swatch. Held
## alongside rather than inside the property, which stays a plain point list.
var _colors: Array[Color] = []

var _list: ItemList
var _pick_button: Button
var _remove_button: Button
var _clear_button: Button
var _hint: Label


## Binds this control to [param property] on [param operation]. [param validate]
## is optional; when valid it is called with each picked colour and may return a
## warning to display.
func setup(operation: IWOperation, property: StringName, label: String, validate: Callable) -> void:
	_operation = operation
	_property = property
	_validate = validate
	_build(label)
	_refresh()


func _build(label: String) -> void:
	var title := Label.new()
	title.text = label
	add_child(title)

	var buttons := HBoxContainer.new()
	add_child(buttons)

	_pick_button = Button.new()
	_pick_button.text = "Pick"
	_pick_button.toggle_mode = true
	_pick_button.tooltip_text = "Click a spot in the preview to add it to the list."
	_pick_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_pick_button.toggled.connect(func(pressed: bool) -> void: pick_toggled.emit(pressed))
	buttons.add_child(_pick_button)

	_remove_button = Button.new()
	_remove_button.text = "Remove"
	_remove_button.tooltip_text = "Remove the highlighted entry."
	_remove_button.pressed.connect(_on_remove_pressed)
	buttons.add_child(_remove_button)

	_clear_button = Button.new()
	_clear_button.text = "Clear"
	_clear_button.tooltip_text = "Remove every entry."
	_clear_button.pressed.connect(_on_clear_pressed)
	buttons.add_child(_clear_button)

	_list = ItemList.new()
	_list.custom_minimum_size = Vector2(0, LIST_MIN_HEIGHT)
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.item_selected.connect(_on_item_selected)
	add_child(_list)

	_hint = Label.new()
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint.modulate = Color(1, 1, 1, 0.6)
	add_child(_hint)


func _notification(what: int) -> void:
	# The editor theme is only reachable once the control is in the tree, so the
	# eyedropper icon is applied here rather than during construction.
	if what == NOTIFICATION_THEME_CHANGED and _pick_button != null:
		if has_theme_icon(&"ColorPick", &"EditorIcons"):
			_pick_button.icon = get_theme_icon(&"ColorPick", &"EditorIcons")


## Adds a picked pixel. [param color] is only used for the row's swatch.
func add_point(point: Vector2i, color: Color) -> void:
	var points := _points()
	if points.has(point):
		_hint.text = "That pixel is already in the list."
		_select(points.find(point))
		return

	points.append(point)
	_colors.append(color)
	_operation.set(_property, points)
	_refresh()
	_select(points.size() - 1)
	_hint.text = _validate.call(color) if _validate.is_valid() else ""
	points_changed.emit()


func get_points() -> Array[Vector2i]:
	return _points()


## Row currently highlighted, or -1. Drives which marker is emphasised.
func selected_index() -> int:
	var selection := _list.get_selected_items()
	return selection[0] if not selection.is_empty() else -1


## Lets the dock switch picking off without echoing back a [signal pick_toggled].
func set_pick_active(enabled: bool) -> void:
	_pick_button.set_pressed_no_signal(enabled)


func _points() -> Array[Vector2i]:
	var points: Array[Vector2i] = _operation.get(_property)
	return points


func _on_item_selected(_index: int) -> void:
	_update_buttons()
	selection_changed.emit()


func _on_remove_pressed() -> void:
	var index := selected_index()
	var points := _points()
	if index < 0 or index >= points.size():
		return
	points.remove_at(index)
	if index < _colors.size():
		_colors.remove_at(index)
	_operation.set(_property, points)
	_refresh()
	if _list.item_count > 0:
		_select(mini(index, _list.item_count - 1))
	_hint.text = ""
	points_changed.emit()
	selection_changed.emit()


func _on_clear_pressed() -> void:
	var points := _points()
	if points.is_empty():
		return
	points.clear()
	_colors.clear()
	_operation.set(_property, points)
	_refresh()
	_hint.text = ""
	points_changed.emit()
	selection_changed.emit()


func _select(index: int) -> void:
	if index < 0 or index >= _list.item_count:
		return
	_list.select(index)
	_update_buttons()
	selection_changed.emit()


func _refresh() -> void:
	var points := _points()
	_list.clear()
	for i in points.size():
		var point := points[i]
		var index := _list.add_item("(%d, %d)" % [point.x, point.y])
		if i < _colors.size():
			_list.set_item_icon(index, _swatch(_colors[i]))
	_update_buttons()


func _update_buttons() -> void:
	var count := _list.item_count
	_remove_button.disabled = selected_index() < 0
	_clear_button.disabled = count == 0


## Small bordered colour chip, so a white pick is still visible on the row.
static func _swatch(color: Color) -> Texture2D:
	var image := Image.create_empty(SWATCH_SIZE, SWATCH_SIZE, false, Image.FORMAT_RGBA8)
	image.fill(Color(0, 0, 0, 1))
	image.fill_rect(Rect2i(1, 1, SWATCH_SIZE - 2, SWATCH_SIZE - 2), color)
	return ImageTexture.create_from_image(image)
