@tool
extends VBoxContainer

## Settings control for an [code]Array[Vector2i][/code] of picked pixels.
##
## Owns the list and its buttons, but neither the picking nor the storage. Only
## the dock can see the preview, so it listens for [signal pick_toggled], routes
## the click back in through [method add_point], and mirrors the entries as
## markers. The dock also decides what the list is *of* — for the background
## remover it swaps the contents per image via [method set_points], so picked
## islands follow the image they were found on.

## Emitted when the pick button is toggled. The dock puts the preview into
## crosshair mode in response.
signal pick_toggled(enabled: bool)

## Emitted whenever the underlying array changes, so the dock can re-run the
## preview and write the list back against the current image.
signal points_changed

## Emitted when a different row is highlighted, so the matching marker can be.
signal selection_changed

const SWATCH_SIZE := 14
const LIST_MIN_HEIGHT := 96

## Eyedropper artwork for the pick button. Loaded rather than preloaded so that a
## missing or not-yet-imported file leaves a plain button instead of breaking the
## addon at parse time.
const PICK_ICON_PATH := "res://addons/image_wrangler/ui/color-picker.png"

## Edge length the icon is resampled to, before editor DPI scaling.
const PICK_ICON_SIZE := 16

var _operation: IWOperation
var _property: StringName

## Supplied by the dock: maps a pixel to its colour in the image on screen.
## Swatches are sampled through this rather than stored, so they can never go
## stale against whichever image is currently selected — and for the background
## remover the swatch is not decoration, it is the colour that seed keys out.
var _color_provider := Callable()

var _base_label := ""
var _title: Label
var _list: ItemList
var _pick_button: Button
var _remove_button: Button
var _clear_button: Button
var _hint: Label


## Binds this control to [param property] on [param operation].
func setup(operation: IWOperation, property: StringName, label: String) -> void:
	_operation = operation
	_property = property
	_base_label = label
	_build()
	_refresh()


func _build() -> void:
	_title = Label.new()
	_title.text = _base_label
	# This label names the selected image, and the settings form it lives in
	# cannot scroll horizontally, so its width becomes a floor for the whole tool
	# column. Ellipsising drops its reported minimum width to nothing, which is
	# what keeps a long file name from pinning the splitters open.
	_title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	add_child(_title)

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
	_clear_button.tooltip_text = "Remove every entry for this image."
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
	# The editor theme is only reachable once the control is in the tree, and the
	# icon depends on it, so both are resolved here rather than at construction.
	if what == NOTIFICATION_THEME_CHANGED and _pick_button != null:
		_apply_pick_icon()


## Builds the pick button's icon for the theme currently in force.
##
## The artwork is two-tone line art — a dark outline with light interior detail —
## so on a dark editor theme the outline would sink into the panel and leave a
## shapeless blob. Inverting it there keeps the linework reading the same way
## round in both themes. Tinting cannot do this job: modulation multiplies, so it
## can darken the light parts but never lift the dark ones.
func _apply_pick_icon() -> void:
	var font_color := _pick_button.get_theme_color(&"font_color", &"Button")
	var icon := _build_pick_icon(font_color.get_luminance() > 0.5)
	if icon != null:
		_pick_button.icon = icon
	elif has_theme_icon(&"ColorPick", &"EditorIcons"):
		# Only reachable before the editor has imported the PNG.
		_pick_button.icon = get_theme_icon(&"ColorPick", &"EditorIcons")


static func _build_pick_icon(invert: bool) -> Texture2D:
	var source := load(PICK_ICON_PATH) as Texture2D
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

	var edge := PICK_ICON_SIZE
	if Engine.is_editor_hint():
		edge = maxi(roundi(PICK_ICON_SIZE * EditorInterface.get_editor_scale()), 1)
	if image.get_width() != edge or image.get_height() != edge:
		image.resize(edge, edge, Image.INTERPOLATE_LANCZOS)

	if invert:
		# Alpha is left alone, so the silhouette is unchanged.
		var data := image.get_data()
		for i in range(0, data.size(), 4):
			data[i] = 255 - data[i]
			data[i + 1] = 255 - data[i + 1]
			data[i + 2] = 255 - data[i + 2]
		image = Image.create_from_data(edge, edge, false, Image.FORMAT_RGBA8, data)

	return ImageTexture.create_from_image(image)


## Lets the dock supply the colour behind a pixel, for swatches and validation.
func set_color_provider(provider: Callable) -> void:
	_color_provider = provider
	_refresh()


## Names what the list currently belongs to, so it is obvious the entries are
## scoped to one image rather than to the tool.
func set_context_label(context: String) -> void:
	_title.text = _base_label if context.is_empty() else "%s: %s" % [_base_label, context]
	_title.tooltip_text = _title.text


## Replaces the whole list and redraws it. Used when the selection changes.
func set_points(points: Array[Vector2i]) -> void:
	write_points(points)
	_hint.text = ""
	_refresh()


## Writes the property without touching the UI, for batch runs that swap points
## per image behind the scenes.
func write_points(points: Array[Vector2i]) -> void:
	var stored: Array[Vector2i] = []
	stored.assign(points)
	_operation.set(_property, stored)


## Adds a picked pixel to the list.
func add_point(point: Vector2i) -> void:
	var points := _points()
	if points.has(point):
		_hint.text = "That pixel is already in the list."
		_select(points.find(point))
		return

	points.append(point)
	_operation.set(_property, points)
	_refresh()
	_select(points.size() - 1)
	_hint.text = ""
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
	if _list == null:
		return
	var points := _points()
	_list.clear()
	for point in points:
		var index := _list.add_item("(%d, %d)" % [point.x, point.y])
		if _color_provider.is_valid():
			_list.set_item_icon(index, _swatch(_color_provider.call(point)))
	_update_buttons()


func _update_buttons() -> void:
	_remove_button.disabled = selected_index() < 0
	_clear_button.disabled = _list.item_count == 0


## Small bordered colour chip, so a white pick is still visible on the row.
static func _swatch(color: Color) -> Texture2D:
	var image := Image.create_empty(SWATCH_SIZE, SWATCH_SIZE, false, Image.FORMAT_RGBA8)
	image.fill(Color(0, 0, 0, 1))
	image.fill_rect(Rect2i(1, 1, SWATCH_SIZE - 2, SWATCH_SIZE - 2), color)
	return ImageTexture.create_from_image(image)
