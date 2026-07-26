@tool
extends Control

## Draws an image centred over a checkerboard, so cut-out transparency and any
## surviving fringe are actually visible.

const CHECKER_SIZE := 8
const CHECKER_DARK := Color(0.16, 0.16, 0.18)
const CHECKER_LIGHT := Color(0.24, 0.24, 0.27)

var _texture: Texture2D
var _checker: Texture2D


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
	else:
		_texture = ImageTexture.create_from_image(image)
	queue_redraw()


func _draw() -> void:
	draw_texture_rect(_checker, Rect2(Vector2.ZERO, size), true)
	if _texture == null:
		return

	var texture_size := Vector2(_texture.get_size())
	if texture_size.x <= 0.0 or texture_size.y <= 0.0:
		return

	var scale := minf(size.x / texture_size.x, size.y / texture_size.y)
	var draw_size := (texture_size * scale).floor()
	var origin := ((size - draw_size) * 0.5).floor()
	draw_texture_rect(_texture, Rect2(origin, draw_size), false)


static func _build_checker() -> Texture2D:
	var image := Image.create_empty(CHECKER_SIZE * 2, CHECKER_SIZE * 2, false, Image.FORMAT_RGB8)
	image.fill(CHECKER_DARK)
	image.fill_rect(Rect2i(0, 0, CHECKER_SIZE, CHECKER_SIZE), CHECKER_LIGHT)
	image.fill_rect(Rect2i(CHECKER_SIZE, CHECKER_SIZE, CHECKER_SIZE, CHECKER_SIZE), CHECKER_LIGHT)
	return ImageTexture.create_from_image(image)
