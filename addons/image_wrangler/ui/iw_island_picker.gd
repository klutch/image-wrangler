@tool
extends VBoxContainer

## The Island Picker: a list of image positions the user clicks off the preview,
## each standing for a region the operation should act on.
##
## Owns the list and its buttons, but neither the picking nor the storage. Only
## the dock can see the preview, so it listens for [signal pick_toggled], routes
## the click back in through [method add_island], and mirrors the entries as
## markers. The dock also decides what the list is *of* — for the background
## remover it swaps the contents per image via [method set_islands], so picked
## islands follow the image they were found on.

## Emitted when the pick button is toggled. The dock puts the preview into
## crosshair mode in response.
signal pick_toggled(enabled: bool)

## Emitted whenever the underlying list changes, so the dock can re-run the
## preview and write the list back against the current image.
signal islands_changed

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

## Longest file name shown before it is elided from the middle.
##
## Generous on purpose: the label reports a minimum width of one pixel either
## way, so this only decides how much is shown when there is room. Too tight a
## limit eats the index in names like [code]sheet__0002_[Generated]-...[/code],
## which is the one part that tells a batch of exports apart.
const CONTEXT_MAX_CHARS := 40

var _operation: IWOperation
var _property: StringName

## Supplied by the dock: maps a position to its colour in the image on screen.
## Swatches are sampled through this rather than stored, so they can never go
## stale against whichever image is currently selected — and for the background
## remover the swatch is not decoration, it is the colour that island keys out.
var _color_provider := Callable()

var _context: Label
var _list: ItemList
var _pick_button: Button
var _remove_button: Button
var _clear_button: Button
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
	_pick_button.tooltip_text = "Click a region in the preview to add it to the list.\nPress H over the dock to show or hide the markers."
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

	_list = ItemList.new()
	_list.custom_minimum_size = Vector2(0, LIST_MIN_HEIGHT)
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.item_selected.connect(_on_item_selected)
	add_child(_list)

	# Captions the list rather than heading the whole control, so it cannot push
	# the buttons away from the group heading. It names the selected image, and
	# the settings form it lives in cannot scroll horizontally, so its width
	# would otherwise become a floor for the whole column — ellipsising drops its
	# reported minimum width to nothing.
	_context = Label.new()
	_context.modulate = Color(1, 1, 1, 0.6)
	_context.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	add_child(_context)

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


# --- Public API ---------------------------------------------------------

## Lets the dock supply the colour behind a position, for the row swatches.
func set_color_provider(provider: Callable) -> void:
	_color_provider = provider
	_refresh()


## Names the image the list currently belongs to, so it is obvious the entries
## are scoped to one image rather than to the operation.
func set_context_label(context: String) -> void:
	if context.is_empty():
		_context.text = "No image selected."
		_context.tooltip_text = ""
		return
	_context.text = _elide_middle(context, CONTEXT_MAX_CHARS)
	_context.tooltip_text = context


## Adds an island at [param at].
func add_island(at: Vector2i) -> void:
	var islands := _islands()
	if islands.has(at):
		_hint.text = "That position is already in the list."
		_select(islands.find(at))
		return

	islands.append(at)
	_operation.set(_property, islands)
	_refresh()
	_select(islands.size() - 1)
	_hint.text = ""
	islands_changed.emit()


func get_islands() -> Array[Vector2i]:
	return _islands()


## Replaces the whole list and redraws it. Used when the selection changes.
func set_islands(islands: Array[Vector2i]) -> void:
	write_islands(islands)
	_hint.text = ""
	_refresh()


## Writes the property without touching the UI, for batch runs that swap islands
## per image behind the scenes.
func write_islands(islands: Array[Vector2i]) -> void:
	var stored: Array[Vector2i] = []
	stored.assign(islands)
	_operation.set(_property, stored)


## Row currently highlighted, or -1. Drives which marker is emphasised.
func selected_index() -> int:
	var selection := _list.get_selected_items()
	return selection[0] if not selection.is_empty() else -1


## Lets the dock switch picking off without echoing back a [signal pick_toggled].
func set_pick_active(enabled: bool) -> void:
	_pick_button.set_pressed_no_signal(enabled)


# --- Internals ----------------------------------------------------------

func _islands() -> Array[Vector2i]:
	var islands: Array[Vector2i] = _operation.get(_property)
	return islands


func _on_item_selected(_index: int) -> void:
	_update_buttons()
	selection_changed.emit()


func _on_remove_pressed() -> void:
	var index := selected_index()
	var islands := _islands()
	if index < 0 or index >= islands.size():
		return
	islands.remove_at(index)
	_operation.set(_property, islands)
	_refresh()
	if _list.item_count > 0:
		_select(mini(index, _list.item_count - 1))
	_hint.text = ""
	islands_changed.emit()
	selection_changed.emit()


func _on_clear_pressed() -> void:
	var islands := _islands()
	if islands.is_empty():
		return
	islands.clear()
	_operation.set(_property, islands)
	_refresh()
	_hint.text = ""
	islands_changed.emit()
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
	var islands := _islands()
	_list.clear()
	for at in islands:
		var index := _list.add_item("(%d, %d)" % [at.x, at.y])
		if _color_provider.is_valid():
			_list.set_item_icon(index, _swatch(_color_provider.call(at)))
	_update_buttons()


func _update_buttons() -> void:
	_remove_button.disabled = selected_index() < 0
	_clear_button.disabled = _list.item_count == 0


## Shortens a long name from the middle, keeping both ends.
##
## Generated file names tend to share a long descriptive tail, so trimming only
## the end — which is all the label's own ellipsis can do — throws away the part
## that actually distinguishes them, and the extension with it.
static func _elide_middle(text: String, limit: int) -> String:
	if text.length() <= limit:
		return text
	var head := floori((limit - 1) * 0.5)
	var tail := limit - 1 - head
	return "%s…%s" % [text.substr(0, head), text.substr(text.length() - tail)]


## Small bordered colour chip, so a white pick is still visible on the row.
static func _swatch(color: Color) -> Texture2D:
	var image := Image.create_empty(SWATCH_SIZE, SWATCH_SIZE, false, Image.FORMAT_RGBA8)
	image.fill(Color(0, 0, 0, 1))
	image.fill_rect(Rect2i(1, 1, SWATCH_SIZE - 2, SWATCH_SIZE - 2), color)
	return ImageTexture.create_from_image(image)
