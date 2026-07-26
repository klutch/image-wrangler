@tool
extends Control

## Draws an image centred over a checkerboard, so cut-out transparency and any
## surviving fringe are actually visible. Doubles as the picking surface for
## tools that need the user to point at the image.

## Emitted when the user clicks the image while [member pick_mode] is on.
signal pixel_picked(pixel: Vector2i)

const CHECKER_SIZE := 8
const CHECKER_DARK := Color(0.16, 0.16, 0.18)
const CHECKER_LIGHT := Color(0.24, 0.24, 0.27)
const MARKER_RADIUS := 5.0
const MARKER_COLOR := Color(1, 1, 1)
const MARKER_SELECTED_COLOR := Color(1.0, 0.85, 0.2)

## While set, clicks report the pixel under the cursor instead of doing nothing.
var pick_mode := false:
	set(value):
		if pick_mode == value:
			return
		pick_mode = value
		mouse_default_cursor_shape = Control.CURSOR_CROSS if value else Control.CURSOR_ARROW

var _texture: Texture2D
var _checker: Texture2D
var _image_size := Vector2i.ZERO
var _markers: Array[Vector2i] = []
var _selected_marker := -1

## Where the image landed on screen last frame. Cached so a click can be mapped
## back to a pixel using exactly the transform that was drawn.
var _draw_origin := Vector2.ZERO
var _draw_scale := 0.0


func _init() -> void:
	# Nearest keeps edge pixels honest — a filtered preview would smear exactly
	# the fringe this tool exists to remove.
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
	clip_contents = true
	custom_minimum_size = Vector2(160, 160)
	_checker = _build_checker()


## Shows [param image], or clears the view when passed [code]null[/code].
func set_image(image: Image) -> void:
	if image == null or image.is_empty():
		_texture = null
		_image_size = Vector2i.ZERO
	else:
		_texture = ImageTexture.create_from_image(image)
		_image_size = Vector2i(image.get_width(), image.get_height())
	queue_redraw()


## Marks [param markers] on the image, emphasising [param selected].
func set_markers(markers: Array[Vector2i], selected: int) -> void:
	# Copied, not aliased: the caller's array belongs to the operation and can
	# change underneath us without a redraw being requested.
	_markers = markers.duplicate()
	_selected_marker = selected
	queue_redraw()


func _gui_input(event: InputEvent) -> void:
	if not pick_mode:
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var pixel := _pixel_at(event.position)
		if pixel.x >= 0:
			pixel_picked.emit(pixel)
		accept_event()


## Image pixel under a local position, or (-1, -1) when outside the image.
func _pixel_at(local_position: Vector2) -> Vector2i:
	if _draw_scale <= 0.0:
		return Vector2i(-1, -1)
	var image_position := (local_position - _draw_origin) / _draw_scale
	var pixel := Vector2i(floori(image_position.x), floori(image_position.y))
	if pixel.x < 0 or pixel.y < 0 or pixel.x >= _image_size.x or pixel.y >= _image_size.y:
		return Vector2i(-1, -1)
	return pixel


func _draw() -> void:
	draw_texture_rect(_checker, Rect2(Vector2.ZERO, size), true)
	if _texture == null:
		return

	var texture_size := Vector2(_texture.get_size())
	if texture_size.x <= 0.0 or texture_size.y <= 0.0:
		return

	_draw_scale = minf(size.x / texture_size.x, size.y / texture_size.y)
	var draw_size := (texture_size * _draw_scale).floor()
	_draw_origin = ((size - draw_size) * 0.5).floor()
	draw_texture_rect(_texture, Rect2(_draw_origin, draw_size), false)
	_draw_markers()


func _draw_markers() -> void:
	for i in _markers.size():
		var point := _markers[i]
		# Points picked on a different image may fall outside this one.
		if point.x < 0 or point.y < 0 or point.x >= _image_size.x or point.y >= _image_size.y:
			continue
		var center := _draw_origin + (Vector2(point) + Vector2(0.5, 0.5)) * _draw_scale
		var selected := i == _selected_marker
		var color := MARKER_SELECTED_COLOR if selected else MARKER_COLOR
		var radius := MARKER_RADIUS + (1.0 if selected else 0.0)
		# Dark ring underneath so the marker reads against light and dark art.
		draw_arc(center, radius + 1.0, 0.0, TAU, 24, Color(0, 0, 0, 0.75), 3.0)
		draw_arc(center, radius, 0.0, TAU, 24, color, 1.5)
		draw_circle(center, 1.5, color)


static func _build_checker() -> Texture2D:
	var image := Image.create_empty(CHECKER_SIZE * 2, CHECKER_SIZE * 2, false, Image.FORMAT_RGB8)
	image.fill(CHECKER_DARK)
	image.fill_rect(Rect2i(0, 0, CHECKER_SIZE, CHECKER_SIZE), CHECKER_LIGHT)
	image.fill_rect(Rect2i(CHECKER_SIZE, CHECKER_SIZE, CHECKER_SIZE, CHECKER_SIZE), CHECKER_LIGHT)
	return ImageTexture.create_from_image(image)
