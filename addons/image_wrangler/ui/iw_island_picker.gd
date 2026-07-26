@tool
extends VBoxContainer

## The Island Picker: a list of image positions the user clicks off the preview,
## each standing for a region the operation should act on.
##
## Owns the list and its buttons, but neither the picking nor the storage. Only
## the dock can see the preview, so it listens for [signal pick_toggled], routes
## the click back in through [method add_island], and mirrors the entries as
## markers.
##
## The [IslandList] it edits is resolved through the operation's settings on
## every access, so when the dock swaps in another image's settings this control
## follows without being told — it only needs a [method refresh] to redraw.

## Emitted when the pick button is toggled. The dock puts the preview into
## crosshair mode in response.
signal pick_toggled(enabled: bool)

## Emitted whenever the underlying list changes, so the dock can re-run the
## preview and write the list back against the current image.
signal islands_changed

## Emitted when a different row is highlighted, so the matching marker can be.
signal selection_changed

const PickIcon := preload("res://addons/image_wrangler/ui/iw_pick_icon.gd")

const SWATCH_SIZE := 14
const LIST_MIN_HEIGHT := 96

var _operation: IWOperation
var _property: StringName

## Supplied by the dock: maps a position to its colour in the image on screen.
## Swatches are sampled through this rather than stored, so they can never go
## stale against whichever image is currently selected — and for the background
## remover the swatch is not decoration, it is the colour that island keys out.
var _color_provider := Callable()

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

	_hint = Label.new()
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint.modulate = Color(1, 1, 1, 0.6)
	add_child(_hint)


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED and _pick_button != null:
		PickIcon.apply_to(_pick_button)


# --- Public API ---------------------------------------------------------

## Lets the dock supply the colour behind a position, for the row swatches.
func set_color_provider(provider: Callable) -> void:
	_color_provider = provider
	_refresh()


## Adds an island at [param at].
func add_island(at: Vector2i) -> void:
	var islands := _island_list()
	if islands == null:
		return
	if islands.has(at):
		_hint.text = "That position is already in the list."
		_select(islands.find(at))
		return

	islands.add(at)
	_refresh()
	_select(islands.size() - 1)
	_hint.text = ""
	islands_changed.emit()


func get_islands() -> Array[Vector2i]:
	var islands := _island_list()
	return islands.points if islands != null else ([] as Array[Vector2i])


## Redraws the rows from whatever list the operation now points at. Called when
## the settings Resource is swapped for another image.
func refresh() -> void:
	_hint.text = ""
	_refresh()


## Row currently highlighted, or -1. Drives which marker is emphasised.
func selected_index() -> int:
	var selection := _list.get_selected_items()
	return selection[0] if not selection.is_empty() else -1


## Lets the dock switch picking off without echoing back a [signal pick_toggled].
func set_pick_active(enabled: bool) -> void:
	_pick_button.set_pressed_no_signal(enabled)


# --- Internals ----------------------------------------------------------

## The list this picker edits, resolved through the operation every time so that
## swapping the settings Resource for another image needs no re-pointing here.
func _island_list() -> IslandList:
	if _operation == null:
		return null
	var settings := _operation.get_settings()
	if settings == null:
		return null
	return settings.get(_property) as IslandList


func _on_item_selected(_index: int) -> void:
	_update_buttons()
	selection_changed.emit()


func _on_remove_pressed() -> void:
	var index := selected_index()
	var islands := _island_list()
	if islands == null or index < 0 or index >= islands.size():
		return
	islands.remove_at(index)
	_refresh()
	if _list.item_count > 0:
		_select(mini(index, _list.item_count - 1))
	_hint.text = ""
	islands_changed.emit()
	selection_changed.emit()


func _on_clear_pressed() -> void:
	var islands := _island_list()
	if islands == null or islands.is_empty():
		return
	islands.clear()
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
	var islands := _island_list()
	_list.clear()
	if islands == null:
		_update_buttons()
		return
	for at in islands.points:
		var index := _list.add_item("(%d, %d)" % [at.x, at.y])
		if _color_provider.is_valid():
			_list.set_item_icon(index, _swatch(_color_provider.call(at)))
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
