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

## Emitted when the user right-clicks while [member pick_mode] is on.
##
## What that means is the dock's business — for the polygon tool it closes the
## shape being drawn. Right-click is free here: panning takes the middle button
## and the left one.
signal pick_cancelled

## Emitted while a polygon vertex is being dragged, once per motion.
signal vertex_dragged(polygon: int, vertex: int, to: Vector2i)

## Emitted when the drag ends, so the dock can re-run the operation once rather
## than on every motion event above.
signal vertex_drag_ended

## Emitted whenever the zoom level changes, from any source.
signal zoom_changed(percent: float)

const CHECKER_SIZE := 8
const CHECKER_DARK := Color(0.16, 0.16, 0.18)
const CHECKER_LIGHT := Color(0.24, 0.24, 0.27)
const MARKER_RADIUS := 5.0
const MARKER_COLOR := Color(1, 1, 1)
const MARKER_SELECTED_COLOR := Color(1.0, 0.85, 0.2)

## Half-width of a polygon's draggable corner handle, in screen pixels, and how
## near the pointer has to be to grab one. Generous on purpose: at low zoom a
## whole image pixel is a fraction of a screen pixel and an exact hit would be
## impossible.
const HANDLE_SIZE := 3.5
const HANDLE_GRAB := 7.0

## Opacity of the shading inside a finished polygon. Enough to read as filled,
## little enough to judge the art underneath.
const POLYGON_FILL_ALPHA := 0.22
const POLYGON_WIDTH := 1.5

## The busy overlay: how far the image behind it is dimmed, and the shape of the
## bar drawn over it.
##
## Dimmed rather than covered, because the point of the preview is the image and
## the point of the overlay is that what you are looking at is one revision out of
## date — not that it has gone away.
const BUSY_SCRIM_ALPHA := 0.35
const BUSY_BAR_WIDTH := 220.0
const BUSY_BAR_HEIGHT := 6.0
const BUSY_BAR_MARGIN := 24.0
const BUSY_CAPTION := "Processing…"

const MIN_ZOOM := 1.0
const MAX_ZOOM := 1000.0

## Smallest slice of the image, in pixels, that panning will leave on screen.
## Bounds the free movement of an image that already fits, so it can be nudged
## around but never dragged out of sight.
const MIN_VISIBLE := 32.0

## Every zoom the buttons, the wheel and the dropdown offer.
##
## Spelled out rather than computed. The spacing is deliberately uneven — 10%
## apart at the bottom, 25% through the middle, 100% at the top — because what
## counts as a useful step depends on how much of the image you are looking at,
## and no single formula gives all three. Writing them down is also the only way
## the three controls are guaranteed to agree: they all walk this one array.
##
## [constant MIN_ZOOM] sits below the first rung on purpose. Fit has to be able
## to shrink a very large image past 10% to get it on screen, and the dropdown
## shows such a value when it does — it is simply not something you can pick.
const ZOOM_STOPS := [
	10.0, 20.0, 30.0, 40.0, 50.0, 75.0,
	100.0, 125.0, 150.0, 175.0,
	200.0, 300.0, 400.0, 500.0, 600.0, 700.0, 800.0, 900.0, 1000.0,
]

## How close a zoom must be to a rung to count as standing on it.
const _STOP_EPSILON := 0.01

## While set, clicks report the pixel under the cursor instead of doing nothing.
var pick_mode := false:
	set(value):
		if pick_mode == value:
			return
		pick_mode = value
		_update_cursor()

## Whether the overlays — island markers and drawn regions — are drawn. They
## sit right on top of the edges being judged, so being able to blink them away
## matters.
var markers_visible := true:
	set(value):
		if markers_visible == value:
			return
		markers_visible = value
		if _canvas != null:
			_canvas.queue_redraw()

## How much of [member _original_texture] is drawn over the result, 0 to 1.
var original_fade := 0.0:
	set(value):
		var clamped := clampf(value, 0.0, 1.0)
		if is_equal_approx(original_fade, clamped):
			return
		original_fade = clamped
		if _canvas != null:
			_canvas.queue_redraw()

## Whether a run is in flight, and how far along it last said it was.
##
## Only ever written from the main thread — the worker reports through the dock,
## which defers, so nothing here is touched from two threads at once.
var _busy := false
var _progress := 0.0

var _texture: Texture2D

## The untouched source, drawn over the result at [member original_fade].
##
## Held as a second texture and blended at draw time rather than mixed into one
## image: the fade is something the user drags, and re-blending a few megapixels
## per step would make it stutter exactly while being used.
var _original_texture: Texture2D

var _checker: Texture2D
var _image_size := Vector2i.ZERO
var _markers: Array[Vector2i] = []
## A byte per marker: zero means the island is switched off and draws hollow.
var _marker_enabled := PackedByteArray()
var _selected_marker := -1

## Drawn regions, as an Array of PackedVector2Array in image coordinates.
var _polygons: Array = []
var _polygon_colors := PackedColorArray()
## A byte per region: zero means it is switched off. It still draws — the shape
## took work to make — but without the fill, since nothing is being cut.
var _polygon_enabled := PackedByteArray()
## Row highlighted in the list. Its corners get grab handles.
var _selected_polygon := -1
## Row being drawn, or -1. Drawn as an open path with a rubber band rather than
## as a closed shape, since it is not one yet.
var _draft_polygon := -1

## Image pixel under the pointer, for the rubber band. Only tracked while a draft
## is open, so ordinary hovering does not queue a redraw per motion event.
var _hover_pixel := Vector2i(-1, -1)

## Corner being dragged, as (polygon, vertex), or (-1, -1).
var _drag_handle := Vector2i(-1, -1)

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


## Supplies the untouched source, for [member original_fade] to bring back in.
##
## Deliberately does not drive the layout: the view is sized by whatever
## [method set_image] was given, so a fade cannot move the image under the pointer
## even if the two somehow differ in size.
func set_original(image: Image) -> void:
	if image == null or image.is_empty():
		_original_texture = null
	else:
		_original_texture = ImageTexture.create_from_image(image)
	if _canvas != null:
		_canvas.queue_redraw()


## Marks [param markers] on the image, emphasising [param selected].
##
## [param enabled] runs alongside, a byte per marker. A switched-off island keeps
## its marker rather than vanishing — where it is remains worth seeing while it is
## set aside — but is drawn hollow so the list and the image agree.
func set_markers(markers: Array[Vector2i], selected: int, enabled := PackedByteArray()) -> void:
	# Copied, not aliased: the caller's array belongs to the operation and can
	# change underneath us without a redraw being requested.
	_markers = markers.duplicate()
	_marker_enabled = enabled.duplicate()
	_selected_marker = selected
	_canvas.queue_redraw()


## Shows [param polygons] over the image, in image coordinates.
##
## [param selected] gets grab handles on its corners, [param draft] is drawn as an
## open path still being placed. Pass -1 for either when there is none.
func set_polygons(polygons: Array, colors: PackedColorArray, selected: int, draft: int, enabled := PackedByteArray()) -> void:
	# Converted to float points once here rather than per redraw, and copied for
	# the same reason the markers are: the caller's arrays belong to the operation
	# and can change underneath us without a redraw being asked for.
	_polygons = []
	for points in polygons:
		var converted := PackedVector2Array()
		for point: Vector2i in points:
			converted.append(Vector2(point))
		_polygons.append(converted)
	_polygon_colors = colors.duplicate()
	_polygon_enabled = enabled.duplicate()
	_selected_polygon = selected
	_draft_polygon = draft
	if draft < 0:
		_hover_pixel = Vector2i(-1, -1)
	_canvas.queue_redraw()


## Puts the view into or out of its working state.
##
## Starting a run resets the bar, so a second run cannot appear to begin wherever
## the first one left off.
func set_busy(active: bool) -> void:
	if _busy == active:
		return
	_busy = active
	if active:
		_progress = 0.0
	_canvas.queue_redraw()


## How far along the run says it is, 0 to 1.
##
## Never goes backwards within a run. A report out of order — which is easy enough
## to introduce by reordering the passes that send them — would otherwise show as
## a bar that stutters, and a bar that stutters is worse than one that is coarse.
func set_progress(fraction: float) -> void:
	if not _busy:
		return
	var clamped := maxf(_progress, clampf(fraction, 0.0, 1.0))
	if is_equal_approx(_progress, clamped):
		return
	_progress = clamped
	_canvas.queue_redraw()


## Flips overlay visibility and reports the new state.
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


## Zoom that fills the frame with the image, magnifying a small one rather than
## leaving it at its true size.
##
## The smaller of the two ratios wins, so whichever axis runs out of room first
## decides and the whole image stays on screen. Anything past
## [constant MAX_ZOOM] is clamped by [method set_zoom], which is the one case
## where the result does not quite fill.
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
	set_zoom(fit)
	_relayout()


## The next rung of [constant ZOOM_STOPS] above or below [param percent].
##
## The buttons and the wheel both come through here, so they cannot disagree.
##
## The trailing [code]maxf[/code] and [code]minf[/code] stop a step travelling
## the wrong way from somewhere off the list. Below the first rung — where only
## Fit can put you — returning that rung on the way *down* would zoom in.
static func step_zoom(percent: float, zooming_in: bool) -> float:
	if zooming_in:
		for stop: float in ZOOM_STOPS:
			if stop > percent + _STOP_EPSILON:
				return maxf(stop, percent)
		return maxf(ZOOM_STOPS[ZOOM_STOPS.size() - 1], percent)

	var previous: float = ZOOM_STOPS[0]
	for stop: float in ZOOM_STOPS:
		if stop >= percent - _STOP_EPSILON:
			break
		previous = stop
	return minf(previous, percent)


## [constant ZOOM_STOPS] as a packed array, for the dropdown to build from.
static func zoom_stops() -> PackedFloat32Array:
	return PackedFloat32Array(ZOOM_STOPS)


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
	# Before panning, so grabbing a corner beats starting a drag of the view. Ctrl
	# still reaches the pan below, since a modified click never grabs a handle.
	if _handle_vertex_drag(event):
		return
	# Panning claims Ctrl+left before picking can see it, so the two never fight.
	if _handle_pan(event):
		return

	# Tracked only while a shape is open, so ordinary hovering over the image does
	# not queue a redraw for every motion event.
	if _draft_polygon >= 0 and event is InputEventMouseMotion:
		var hovered := _pixel_at_clamped(event.position)
		if hovered != _hover_pixel:
			_hover_pixel = hovered
			_canvas.queue_redraw()
		return

	if not (event is InputEventMouseButton) or not event.pressed:
		return

	if event.button_index == MOUSE_BUTTON_WHEEL_UP:
		set_zoom(step_zoom(_zoom_percent, true), event.position)
		_canvas.accept_event()
	elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		set_zoom(step_zoom(_zoom_percent, false), event.position)
		_canvas.accept_event()
	elif pick_mode and event.button_index == MOUSE_BUTTON_LEFT:
		var pixel := _pixel_at(event.position)
		if pixel.x >= 0:
			pixel_picked.emit(pixel)
		_canvas.accept_event()
	elif pick_mode and event.button_index == MOUSE_BUTTON_RIGHT:
		pick_cancelled.emit()
		_canvas.accept_event()


## Grab-and-drag of a polygon corner. Returns whether the event was consumed.
##
## Live only for the highlighted polygon, and never for the one being drawn — its
## corners are still being placed, and a click there means "another corner", not
## "move that one".
func _handle_vertex_drag(event: InputEvent) -> bool:
	var button := event as InputEventMouseButton
	if button != null and button.button_index == MOUSE_BUTTON_LEFT:
		if button.pressed:
			if button.ctrl_pressed or _selected_polygon < 0 or _selected_polygon == _draft_polygon:
				return false
			var vertex := _vertex_at(button.position, _selected_polygon)
			if vertex < 0:
				return false
			_drag_handle = Vector2i(_selected_polygon, vertex)
			_canvas.accept_event()
			return true
		if _drag_handle.x >= 0:
			_drag_handle = Vector2i(-1, -1)
			vertex_drag_ended.emit()
			_canvas.accept_event()
			return true
		return false

	if _drag_handle.x < 0 or not (event is InputEventMouseMotion):
		return false

	# A release swallowed elsewhere — an alt-tab mid-drag — would otherwise leave
	# the corner stuck to the cursor.
	if not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_drag_handle = Vector2i(-1, -1)
		vertex_drag_ended.emit()
		return false

	# Clamped rather than dropped: a corner dragged past the edge should stop at
	# it, not vanish because the pointer left the image.
	vertex_dragged.emit(_drag_handle.x, _drag_handle.y, _pixel_at_clamped(event.position))
	_canvas.accept_event()
	return true


## Index of the corner of [param polygon] under [param local_position], or -1.
##
## Searched back to front so that the corner drawn on top is the one grabbed
## where two overlap.
func _vertex_at(local_position: Vector2, polygon: int) -> int:
	if not markers_visible or polygon < 0 or polygon >= _polygons.size():
		return -1
	var points: PackedVector2Array = _polygons[polygon]
	var scale := _scale()
	for i in range(points.size() - 1, -1, -1):
		var center := _content_origin + (points[i] + Vector2(0.5, 0.5)) * scale
		if center.distance_to(local_position) <= HANDLE_GRAB:
			return i
	return -1


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


## Image pixel under a position, pulled to the nearest edge pixel when the
## position is outside the image.
##
## The clamping counterpart to [method _pixel_at], for the cases where leaving the
## image has to mean "stop at the edge" rather than "nothing here": dragging a
## corner past the frame, and the rubber band while drawing.
func _pixel_at_clamped(local_position: Vector2) -> Vector2i:
	if _image_size.x <= 0 or _image_size.y <= 0:
		return Vector2i(-1, -1)
	var scale := _scale()
	if scale <= 0.0:
		return Vector2i(-1, -1)
	var image_position := (local_position - _content_origin) / scale
	return Vector2i(
		clampi(floori(image_position.x), 0, _image_size.x - 1),
		clampi(floori(image_position.y), 0, _image_size.y - 1),
	)


# --- Drawing ------------------------------------------------------------

func _draw_canvas() -> void:
	_canvas.draw_texture_rect(_checker, Rect2(Vector2.ZERO, _viewport), true)
	if _texture == null or _content_size.x <= 0.0 or _content_size.y <= 0.0:
		# Still worth saying something is happening, even with nothing to dim.
		_draw_busy()
		return
	var frame := Rect2(_content_origin, _content_size)
	_canvas.draw_texture_rect(_texture, frame, false)
	# Over the top rather than blended into it. Where the source is opaque this
	# is an ordinary cross-fade; where the result cut something away, the source
	# comes back over the checkerboard, which is exactly the comparison being
	# asked for.
	if original_fade > 0.0 and _original_texture != null:
		_canvas.draw_texture_rect(_original_texture, frame, false, Color(1, 1, 1, original_fade))
	_draw_markers()
	_draw_polygons()
	# Over everything, including the overlays, since it is about the whole view
	# rather than about anything drawn on it.
	_draw_busy()


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
		var on := i >= _marker_enabled.size() or _marker_enabled[i] != 0
		var color := MARKER_SELECTED_COLOR if selected else MARKER_COLOR
		if not on:
			color = Color(color, 0.45)
		var radius := MARKER_RADIUS + (1.0 if selected else 0.0)
		# Dark ring underneath so the marker reads against light and dark art.
		_canvas.draw_arc(center, radius + 1.0, 0.0, TAU, 24, Color(0, 0, 0, 0.75), 3.0)
		_canvas.draw_arc(center, radius, 0.0, TAU, 24, color, 1.5)
		# Hollow when switched off, so a marker that is only a reminder cannot be
		# mistaken for one that is doing something.
		if on:
			_canvas.draw_circle(center, 1.5, color)


## Draws every drawn region: finished ones closed and shaded, the one being
## drawn as an open path trailing a rubber band to the pointer.
func _draw_polygons() -> void:
	if not markers_visible:
		return
	for i in _polygons.size():
		var points: PackedVector2Array = _polygons[i]
		if points.is_empty():
			continue
		var color := _polygon_colors[i] if i < _polygon_colors.size() else Color.MAGENTA
		var on := i >= _polygon_enabled.size() or _polygon_enabled[i] != 0
		var screen := _to_screen(points)
		if i == _draft_polygon:
			_draw_draft(screen, color)
		else:
			_draw_finished(screen, color, i == _selected_polygon, on)


## Image-space points as canvas positions, taken from pixel centres so a corner
## sits in the middle of the pixel it names rather than on its top-left edge.
func _to_screen(points: PackedVector2Array) -> PackedVector2Array:
	var scale := _scale()
	var out := PackedVector2Array()
	for point in points:
		out.append(_content_origin + (point + Vector2(0.5, 0.5)) * scale)
	return out


func _draw_finished(screen: PackedVector2Array, color: Color, selected: bool, enabled: bool) -> void:
	if not enabled:
		# Outline only. The fill is what says "this area is being taken out", so a
		# region that is switched off must not have one — but the shape stays, since
		# it was built corner by corner and is only set aside.
		var dimmed := Color(color, 0.5)
		var outline := screen.duplicate()
		outline.append(screen[0])
		_canvas.draw_polyline(outline, Color(0, 0, 0, 0.5), POLYGON_WIDTH + 2.0)
		_canvas.draw_polyline(outline, dimmed, POLYGON_WIDTH)
		if selected:
			for point in screen:
				_draw_handle(point, dimmed)
		return

	# Triangulated rather than handed straight to draw_colored_polygon, which
	# fans from the first vertex and so fills the wrong area for a concave shape —
	# and concave is the whole point of this tool.
	if screen.size() >= 3:
		var indices := Geometry2D.triangulate_polygon(screen)
		var fill := Color(color, POLYGON_FILL_ALPHA)
		var triangle := 0
		while triangle + 2 < indices.size():
			_canvas.draw_colored_polygon(PackedVector2Array([
				screen[indices[triangle]],
				screen[indices[triangle + 1]],
				screen[indices[triangle + 2]],
			]), fill)
			triangle += 3

	var closed := screen.duplicate()
	closed.append(screen[0])
	# Dark backing line first, so the outline reads against light and dark art
	# alike — the same trick the island markers use.
	_canvas.draw_polyline(closed, Color(0, 0, 0, 0.75), POLYGON_WIDTH + 2.0)
	_canvas.draw_polyline(closed, color, POLYGON_WIDTH + (1.0 if selected else 0.0))
	if selected:
		# Handles only on the highlighted region, since that is the only one whose
		# corners can be grabbed.
		for point in screen:
			_draw_handle(point, color)


func _draw_draft(screen: PackedVector2Array, color: Color) -> void:
	if screen.size() > 1:
		_canvas.draw_polyline(screen, Color(0, 0, 0, 0.75), POLYGON_WIDTH + 2.0)
		_canvas.draw_polyline(screen, color, POLYGON_WIDTH)

	# The edge that would be added by clicking where the pointer is, so the shape
	# can be judged before committing to the corner.
	if _hover_pixel.x >= 0 and not screen.is_empty():
		var scale := _scale()
		var cursor := _content_origin + (Vector2(_hover_pixel) + Vector2(0.5, 0.5)) * scale
		_canvas.draw_line(screen[screen.size() - 1], cursor, Color(0, 0, 0, 0.6), POLYGON_WIDTH + 2.0)
		_canvas.draw_line(screen[screen.size() - 1], cursor, Color(color, 0.7), POLYGON_WIDTH)
		# The closing edge too, dashed-thin, so an open path still reads as the
		# region it is about to become.
		if screen.size() >= 2:
			_canvas.draw_line(cursor, screen[0], Color(color, 0.35), POLYGON_WIDTH)

	for i in screen.size():
		# The first corner is the close target, so it is drawn larger than the
		# rest — clicking it again ends the shape.
		_draw_handle(screen[i], color, i == 0)


func _draw_handle(center: Vector2, color: Color, emphasised := false) -> void:
	var half := HANDLE_SIZE + (1.5 if emphasised else 0.0)
	var box := Rect2(center - Vector2(half, half), Vector2(half, half) * 2.0)
	_canvas.draw_rect(box.grow(1.0), Color(0, 0, 0, 0.75), true)
	_canvas.draw_rect(box, color, true)


## Dims the view and draws a progress bar across the middle of it.
##
## The bar is the honest shape for this: the passes behind it report where they
## have got to, so there is a real fraction to draw. It advances unevenly, because
## the passes are not equally expensive and the reports say so rather than
## pretending otherwise.
func _draw_busy() -> void:
	if not _busy:
		return

	_canvas.draw_rect(Rect2(Vector2.ZERO, _viewport), Color(0, 0, 0, BUSY_SCRIM_ALPHA), true)

	var bar_width := minf(BUSY_BAR_WIDTH, maxf(_viewport.x - BUSY_BAR_MARGIN * 2.0, 0.0))
	if bar_width <= 0.0:
		return
	var origin := Vector2(
		floorf((_viewport.x - bar_width) * 0.5),
		floorf((_viewport.y - BUSY_BAR_HEIGHT) * 0.5),
	)

	var accent := Color(0.4, 0.6, 1.0)
	if has_theme_color(&"accent_color", &"Editor"):
		accent = get_theme_color(&"accent_color", &"Editor")

	# Track first, then the fill over it, so a fraction of zero still reads as a
	# bar waiting rather than as nothing at all.
	_canvas.draw_rect(Rect2(origin, Vector2(bar_width, BUSY_BAR_HEIGHT)), Color(0, 0, 0, 0.55), true)
	if _progress > 0.0:
		_canvas.draw_rect(
			Rect2(origin, Vector2(floorf(bar_width * _progress), BUSY_BAR_HEIGHT)), accent, true)
	_canvas.draw_rect(
		Rect2(origin, Vector2(bar_width, BUSY_BAR_HEIGHT)), Color(1, 1, 1, 0.25), false, 1.0)

	var font := get_theme_default_font()
	if font == null:
		return
	var size := get_theme_default_font_size()
	var caption := font.get_string_size(BUSY_CAPTION, HORIZONTAL_ALIGNMENT_LEFT, -1.0, size)
	_canvas.draw_string(
		font,
		Vector2(floorf((_viewport.x - caption.x) * 0.5), origin.y - BUSY_BAR_HEIGHT * 1.5),
		BUSY_CAPTION,
		HORIZONTAL_ALIGNMENT_LEFT,
		-1.0,
		size,
		Color(1, 1, 1, 0.85),
	)


static func _build_checker() -> Texture2D:
	var image := Image.create_empty(CHECKER_SIZE * 2, CHECKER_SIZE * 2, false, Image.FORMAT_RGB8)
	image.fill(CHECKER_DARK)
	image.fill_rect(Rect2i(0, 0, CHECKER_SIZE, CHECKER_SIZE), CHECKER_LIGHT)
	image.fill_rect(Rect2i(CHECKER_SIZE, CHECKER_SIZE, CHECKER_SIZE, CHECKER_SIZE), CHECKER_LIGHT)
	return ImageTexture.create_from_image(image)
