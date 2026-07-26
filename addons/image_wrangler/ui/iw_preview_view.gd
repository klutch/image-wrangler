@tool
extends Control

## A zoomable, scrollable image view over a checkerboard, so cut-out
## transparency and any surviving fringe are actually visible. Doubles as the
## picking surface for operations that need the user to point at the image.
##
## The image is never stretched to fit. Below the viewport size it sits centred
## with transparent margins around it; above, scrollbars appear and it is shown
## at exactly the requested zoom.

## Emitted when the user clicks the image while [member pick_mode] is on.
signal pixel_picked(pixel: Vector2i)

## Emitted whenever the zoom level changes, from any source.
signal zoom_changed(percent: float)

const CHECKER_SIZE := 8
const CHECKER_DARK := Color(0.16, 0.16, 0.18)
const CHECKER_LIGHT := Color(0.24, 0.24, 0.27)
const MARKER_RADIUS := 5.0
const MARKER_COLOR := Color(1, 1, 1)
const MARKER_SELECTED_COLOR := Color(1.0, 0.85, 0.2)

const MIN_ZOOM := 1.0
const MAX_ZOOM := 1000.0

## Smallest slice of the image, in pixels, that panning will leave on screen.
## Bounds the free movement of an image that already fits, so it can be nudged
## around but never dragged out of sight.
const MIN_VISIBLE := 32.0

## Button steps are fine up to 100% and coarse beyond it, so the top of the
## range is reachable without forty clicks.
const FINE_STEP := 25.0
const COARSE_STEP := 100.0
const COARSE_ABOVE := 100.0

## The wheel steps 25% for most of the range, but drops to 10% at the bottom of
## it, where a 25% jump is a large fraction of what you are looking at.
const WHEEL_STEP := 25.0
const WHEEL_FINE_STEP := 10.0
const WHEEL_FINE_BELOW := 50.0

## While set, clicks report the pixel under the cursor instead of doing nothing.
var pick_mode := false:
	set(value):
		if pick_mode == value:
			return
		pick_mode = value
		_update_cursor()

## Whether the island markers are drawn. They sit right on top of the edges
## being judged, so being able to blink them away matters.
var markers_visible := true:
	set(value):
		if markers_visible == value:
			return
		markers_visible = value
		if _canvas != null:
			_canvas.queue_redraw()

var _texture: Texture2D
var _checker: Texture2D
var _image_size := Vector2i.ZERO
var _markers: Array[Vector2i] = []
var _selected_marker := -1

var _zoom_percent := 100.0
## True between grabbing the image and letting go of it.
var _panning := false
## Top-left of the viewport in content space, in screen pixels.
var _scroll := Vector2.ZERO
## How far the image has been dragged off its resting place, on axes where it
## fits the viewport and so has nothing to scroll. Kept separate from
## [member _scroll] so that centring stays the rest position rather than
## something the pan has to keep re-deriving.
var _pan_offset := Vector2.ZERO
## Drawing area, i.e. this control minus whichever scrollbars are showing.
var _viewport := Vector2.ZERO
var _content_size := Vector2.ZERO
## Where the image's top-left lands inside the viewport.
var _content_origin := Vector2.ZERO

var _canvas: Control
var _h_scroll: HScrollBar
var _v_scroll: VScrollBar
## Guards the scrollbars against re-entering layout while it is writing to them.
var _syncing_bars := false


func _init() -> void:
	clip_contents = true
	custom_minimum_size = Vector2(120, 120)
	_checker = _build_checker()

	# A separate canvas child rather than drawing here directly: it clips to the
	# drawing area, so a zoomed image cannot spill under the scrollbars.
	_canvas = Control.new()
	_canvas.clip_contents = true
	# Nearest keeps edge pixels honest — a filtered preview would smear exactly
	# the fringe the background remover exists to kill — and keeps the checkerboard
	# seam-free.
	_canvas.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_canvas.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
	_canvas.draw.connect(_draw_canvas)
	_canvas.gui_input.connect(_on_canvas_gui_input)
	add_child(_canvas)

	_h_scroll = HScrollBar.new()
	_h_scroll.value_changed.connect(_on_h_scroll_changed)
	add_child(_h_scroll)

	_v_scroll = VScrollBar.new()
	_v_scroll.value_changed.connect(_on_v_scroll_changed)
	add_child(_v_scroll)


func _ready() -> void:
	_relayout()


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_relayout()


# --- Public API ---------------------------------------------------------

## Shows [param image], or clears the view when passed [code]null[/code].
func set_image(image: Image) -> void:
	if image == null or image.is_empty():
		_texture = null
		_image_size = Vector2i.ZERO
	else:
		_texture = ImageTexture.create_from_image(image)
		_image_size = Vector2i(image.get_width(), image.get_height())
	_relayout()


## Marks [param markers] on the image, emphasising [param selected].
func set_markers(markers: Array[Vector2i], selected: int) -> void:
	# Copied, not aliased: the caller's array belongs to the operation and can
	# change underneath us without a redraw being requested.
	_markers = markers.duplicate()
	_selected_marker = selected
	_canvas.queue_redraw()


## Flips marker visibility and reports the new state.
func toggle_markers() -> bool:
	markers_visible = not markers_visible
	return markers_visible


func get_zoom() -> float:
	return _zoom_percent


## Sets the zoom, keeping [param anchor] (a position within the drawing area)
## over the same image pixel. Pass a negative anchor to hold the centre instead.
func set_zoom(percent: float, anchor := Vector2(-1, -1)) -> void:
	var target := clampf(percent, MIN_ZOOM, MAX_ZOOM)
	if is_equal_approx(target, _zoom_percent):
		return

	var use_anchor := anchor.x >= 0.0 and anchor.y >= 0.0
	if not use_anchor:
		anchor = _viewport * 0.5
	# The image point under the anchor has to be captured before the scale
	# changes, since that is the thing being held still.
	var image_point := (anchor - _content_origin) / _scale()

	_zoom_percent = target
	_relayout()

	var scaled := image_point * _scale()
	if _content_size.x > _viewport.x:
		_scroll.x = scaled.x - anchor.x
	if _content_size.y > _viewport.y:
		_scroll.y = scaled.y - anchor.y
	_relayout()

	zoom_changed.emit(_zoom_percent)


func zoom_in(anchor := Vector2(-1, -1)) -> void:
	set_zoom(step_zoom(_zoom_percent, true), anchor)


func zoom_out(anchor := Vector2(-1, -1)) -> void:
	set_zoom(step_zoom(_zoom_percent, false), anchor)


## Zoom that makes the whole image visible, never above 100%: a small image is
## shown at its true size with margins rather than blown up to fill the frame.
func fit_to_view() -> void:
	if _image_size.x <= 0 or _image_size.y <= 0 or size.x <= 0.0 or size.y <= 0.0:
		set_zoom(100.0)
		return
	var fit := minf(size.x / _image_size.x, size.y / _image_size.y) * 100.0
	# Fit is also the way back to centre after nudging a small image around.
	# Deliberately not done in set_image(), so that re-running the operation
	# leaves the view exactly where it was.
	_scroll = Vector2.ZERO
	_pan_offset = Vector2.ZERO
	_relayout()
	set_zoom(minf(fit, 100.0))
	_relayout()


## Next zoom on the button ladder: 25% steps below 100%, 100% steps above it.
static func step_zoom(percent: float, zooming_in: bool) -> float:
	if zooming_in:
		var up_step := FINE_STEP if percent < COARSE_ABOVE else COARSE_STEP
		return clampf(floorf(percent / up_step) * up_step + up_step, MIN_ZOOM, MAX_ZOOM)
	var down_step := FINE_STEP if percent <= COARSE_ABOVE else COARSE_STEP
	return clampf(ceilf(percent / down_step) * down_step - down_step, MIN_ZOOM, MAX_ZOOM)


## Next zoom on the wheel ladder: 10% steps below 50%, 25% steps from there up.
##
## The comparisons differ by a hair on purpose. Stepping up *from* 50% takes the
## coarse step and stepping down *from* it takes the fine one, so 40 and 50 are
## neighbours in both directions and the boundary has no rung that can only be
## reached from one side.
static func wheel_zoom(percent: float, zooming_in: bool) -> float:
	if zooming_in:
		var up_step := WHEEL_FINE_STEP if percent < WHEEL_FINE_BELOW else WHEEL_STEP
		return clampf(floorf(percent / up_step) * up_step + up_step, MIN_ZOOM, MAX_ZOOM)
	var down_step := WHEEL_FINE_STEP if percent <= WHEEL_FINE_BELOW else WHEEL_STEP
	return clampf(ceilf(percent / down_step) * down_step - down_step, MIN_ZOOM, MAX_ZOOM)


# --- Layout -------------------------------------------------------------

func _scale() -> float:
	return _zoom_percent * 0.01


func _relayout() -> void:
	if _canvas == null:
		return

	_content_size = Vector2(_image_size) * _scale()
	var bar_width := _v_scroll.get_combined_minimum_size().x
	var bar_height := _h_scroll.get_combined_minimum_size().y

	# Showing one bar shrinks the other axis, which can be what tips it into
	# needing the second. Two passes settle that; a third could not change it.
	var show_h := false
	var show_v := false
	for _pass in 2:
		var available := size
		if show_v:
			available.x -= bar_width
		if show_h:
			available.y -= bar_height
		show_h = _content_size.x > available.x
		show_v = _content_size.y > available.y

	_viewport = size
	if show_v:
		_viewport.x -= bar_width
	if show_h:
		_viewport.y -= bar_height
	_viewport.x = maxf(_viewport.x, 0.0)
	_viewport.y = maxf(_viewport.y, 0.0)

	# One rule governs how far the image may be dragged, whether it fits or
	# overflows: it stops once only MIN_VISIBLE pixels of it are left on screen.
	# For an overflowing axis that means the scroll range runs past both edges,
	# so the image can be pulled clear of them rather than sticking.
	var keep := Vector2(
		minf(MIN_VISIBLE, minf(_content_size.x, _viewport.x)),
		minf(MIN_VISIBLE, minf(_content_size.y, _viewport.y)),
	)
	var scroll_min := Vector2(keep.x - _viewport.x, keep.y - _viewport.y)
	var scroll_max := Vector2(_content_size.x - keep.x, _content_size.y - keep.y)

	# Centred plus however far it has been dragged when it fits, scrolled when it
	# does not. Floored so the image lands on whole pixels and nearest sampling
	# stays exact.
	if _content_size.x <= _viewport.x:
		# Scroll means nothing on this axis; the offset carries the drag.
		_scroll.x = 0.0
		var limit_x := _pan_limit(_content_size.x, _viewport.x)
		_pan_offset.x = clampf(_pan_offset.x, -limit_x, limit_x)
		_content_origin.x = floorf((_viewport.x - _content_size.x) * 0.5 + _pan_offset.x)
	else:
		_scroll.x = clampf(_scroll.x, scroll_min.x, scroll_max.x)
		_content_origin.x = -_scroll.x
	if _content_size.y <= _viewport.y:
		_scroll.y = 0.0
		var limit_y := _pan_limit(_content_size.y, _viewport.y)
		_pan_offset.y = clampf(_pan_offset.y, -limit_y, limit_y)
		_content_origin.y = floorf((_viewport.y - _content_size.y) * 0.5 + _pan_offset.y)
	else:
		_scroll.y = clampf(_scroll.y, scroll_min.y, scroll_max.y)
		_content_origin.y = -_scroll.y

	_canvas.position = Vector2.ZERO
	_canvas.size = _viewport

	_syncing_bars = true
	# A Range clamps its value to [min_value, max_value - page], so the bars have
	# to span the overscroll too. Left at the plain content extent they would
	# clamp the value back on every sync and fight the drag.
	_h_scroll.visible = show_h
	if show_h:
		_h_scroll.position = Vector2(0.0, size.y - bar_height)
		_h_scroll.size = Vector2(_viewport.x, bar_height)
		_h_scroll.min_value = scroll_min.x
		_h_scroll.max_value = scroll_max.x + _viewport.x
		_h_scroll.page = _viewport.x
		_h_scroll.value = _scroll.x
	_v_scroll.visible = show_v
	if show_v:
		_v_scroll.position = Vector2(size.x - bar_width, 0.0)
		_v_scroll.size = Vector2(bar_width, _viewport.y)
		_v_scroll.min_value = scroll_min.y
		_v_scroll.max_value = scroll_max.y + _viewport.y
		_v_scroll.page = _viewport.y
		_v_scroll.value = _scroll.y
	_syncing_bars = false

	_canvas.queue_redraw()


func _on_h_scroll_changed(value: float) -> void:
	if _syncing_bars:
		return
	_scroll.x = value
	_relayout()


func _on_v_scroll_changed(value: float) -> void:
	if _syncing_bars:
		return
	_scroll.y = value
	_relayout()


# --- Input --------------------------------------------------------------

func _on_canvas_gui_input(event: InputEvent) -> void:
	# Panning claims Ctrl+left before picking can see it, so the two never fight.
	if _handle_pan(event):
		return

	if not (event is InputEventMouseButton) or not event.pressed:
		return

	if event.button_index == MOUSE_BUTTON_WHEEL_UP:
		set_zoom(wheel_zoom(_zoom_percent, true), event.position)
		_canvas.accept_event()
	elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		set_zoom(wheel_zoom(_zoom_percent, false), event.position)
		_canvas.accept_event()
	elif pick_mode and event.button_index == MOUSE_BUTTON_LEFT:
		var pixel := _pixel_at(event.position)
		if pixel.x >= 0:
			pixel_picked.emit(pixel)
		_canvas.accept_event()


## Grab-and-drag panning. The middle button always pans; the left button pans
## too unless a tool has claimed it, in which case Ctrl reclaims it. Returns
## whether the event was consumed.
func _handle_pan(event: InputEvent) -> bool:
	var button := event as InputEventMouseButton
	if button != null:
		if not button.pressed:
			# Any release ends a pan. Testing the modifier here instead would
			# strand the drag whenever Ctrl came up before the mouse button.
			if _panning and button.button_index in [MOUSE_BUTTON_MIDDLE, MOUSE_BUTTON_LEFT]:
				_set_panning(false)
				_canvas.accept_event()
				return true
			return false
		# With no tool active the left button has nothing else to do, so it
		# drags the view; with one active it belongs to the tool and Ctrl is the
		# way back to panning.
		var left_pans := button.button_index == MOUSE_BUTTON_LEFT \
				and (button.ctrl_pressed or not pick_mode)
		if button.button_index == MOUSE_BUTTON_MIDDLE or left_pans:
			_set_panning(true)
			_canvas.accept_event()
			return true
		return false

	var motion := event as InputEventMouseMotion
	if motion == null or not _panning:
		return false

	# A release swallowed elsewhere — an alt-tab mid-drag, say — would otherwise
	# leave the view stuck to the cursor.
	if not (Input.is_mouse_button_pressed(MOUSE_BUTTON_MIDDLE) or Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)):
		_set_panning(false)
		return false

	# The image follows the cursor either way. An axis with something to scroll
	# moves against the drag; one the image already fits gets dragged directly,
	# which is what lets a small image be nudged around at all.
	if _content_size.x > _viewport.x:
		_scroll.x -= motion.relative.x
	else:
		_pan_offset.x += motion.relative.x
	if _content_size.y > _viewport.y:
		_scroll.y -= motion.relative.y
	else:
		_pan_offset.y += motion.relative.y
	_relayout()
	_canvas.accept_event()
	return true


## Half the distance an image that fits may be dragged from centre, being the
## point at which only [constant MIN_VISIBLE] pixels of it would still be on
## screen. An image smaller than that is simply never allowed off the edge.
static func _pan_limit(content: float, viewport: float) -> float:
	var keep := minf(MIN_VISIBLE, content)
	return maxf((viewport + content) * 0.5 - keep, 0.0)


func _set_panning(active: bool) -> void:
	if _panning == active:
		return
	_panning = active
	_update_cursor()


func _update_cursor() -> void:
	if _canvas == null:
		return
	if _panning:
		_canvas.mouse_default_cursor_shape = Control.CURSOR_DRAG
	elif pick_mode:
		_canvas.mouse_default_cursor_shape = Control.CURSOR_CROSS
	else:
		_canvas.mouse_default_cursor_shape = Control.CURSOR_ARROW


## Image pixel under a position in the drawing area, or (-1, -1) when outside
## the image.
func _pixel_at(local_position: Vector2) -> Vector2i:
	var scale := _scale()
	if scale <= 0.0:
		return Vector2i(-1, -1)
	var image_position := (local_position - _content_origin) / scale
	var pixel := Vector2i(floori(image_position.x), floori(image_position.y))
	if pixel.x < 0 or pixel.y < 0 or pixel.x >= _image_size.x or pixel.y >= _image_size.y:
		return Vector2i(-1, -1)
	return pixel


# --- Drawing ------------------------------------------------------------

func _draw_canvas() -> void:
	_canvas.draw_texture_rect(_checker, Rect2(Vector2.ZERO, _viewport), true)
	if _texture == null or _content_size.x <= 0.0 or _content_size.y <= 0.0:
		return
	_canvas.draw_texture_rect(_texture, Rect2(_content_origin, _content_size), false)
	_draw_markers()


func _draw_markers() -> void:
	if not markers_visible:
		return
	var scale := _scale()
	for i in _markers.size():
		var point := _markers[i]
		# Points picked on a different image may fall outside this one.
		if point.x < 0 or point.y < 0 or point.x >= _image_size.x or point.y >= _image_size.y:
			continue
		var center := _content_origin + (Vector2(point) + Vector2(0.5, 0.5)) * scale
		var selected := i == _selected_marker
		var color := MARKER_SELECTED_COLOR if selected else MARKER_COLOR
		var radius := MARKER_RADIUS + (1.0 if selected else 0.0)
		# Dark ring underneath so the marker reads against light and dark art.
		_canvas.draw_arc(center, radius + 1.0, 0.0, TAU, 24, Color(0, 0, 0, 0.75), 3.0)
		_canvas.draw_arc(center, radius, 0.0, TAU, 24, color, 1.5)
		_canvas.draw_circle(center, 1.5, color)


static func _build_checker() -> Texture2D:
	var image := Image.create_empty(CHECKER_SIZE * 2, CHECKER_SIZE * 2, false, Image.FORMAT_RGB8)
	image.fill(CHECKER_DARK)
	image.fill_rect(Rect2i(0, 0, CHECKER_SIZE, CHECKER_SIZE), CHECKER_LIGHT)
	image.fill_rect(Rect2i(CHECKER_SIZE, CHECKER_SIZE, CHECKER_SIZE, CHECKER_SIZE), CHECKER_LIGHT)
	return ImageTexture.create_from_image(image)
