@tool
extends Control

## A zoomable, scrollable image view over a checkerboard, so cut-out
## transparency and any surviving fringe are actually visible. Doubles as the
## picking surface for operations that need the user to point at the image.
##
## The image is never stretched to fit. Below the viewport size it sits centred
## with transparent margins around it; above, scrollbars appear and it is shown
## at exactly the requested zoom.

## Emitted when the user clicks the image while [member pick_mode] is on and
## [member region_pick] is not.
signal pixel_picked(pixel: Vector2i)

## Emitted when a sweep under [member region_pick] ends, with the rectangle of image
## pixels it covered.
##
## Never empty: pressing and releasing on one pixel reports that pixel as a one by one
## rectangle, so a caller can treat a click as the degenerate drag it is rather than as
## a separate gesture.
signal region_picked(region: Rect2i)

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

## What a marker is drawn in, alpha included.
##
## The alpha belongs here rather than being mixed in at each draw. There is one answer
## to how present a marker should be, and every place that built its own from a bare
## colour was another place for that answer to drift — the dashes ended up softer than
## the dot for no reason anyone had decided on. A marker that should read differently is
## a colour of its own, below, not the same colour re-alphaed on the way past.
##
## Softer than solid on purpose: these sit over the edges the tool exists to judge, and
## have to be readable without being what you look at.
const MARKER_COLOR := Color(1, 1, 1, 0.6)
const MARKER_SELECTED_COLOR := Color(1.0, 1.0, 0.2, 1)

## The same two for an island that has been switched off.
##
## It keeps its marker rather than vanishing — where it is stays worth seeing while it
## is set aside — but drops back far enough that the image agrees with the greyed row in
## the list.
const MARKER_DISABLED_COLOR := Color(1, 1, 1, 0.27)
const MARKER_DISABLED_SELECTED_COLOR := Color(1.0, 1.0, 0.2, 0.27)

## The dark backing every marker is laid over, so an outline reads against light and
## dark art alike. Drawn as the same shape, one step thicker.
const MARKER_SHADOW_COLOR := Color(0, 0, 0, 0.75)

## The outline of a picked rectangle, and the shading inside the one being swept or
## highlighted. Thin and faint on purpose: this sits over the edges the tool exists to
## judge, so it has to be readable without being what you look at.
const MARKER_WIDTH := 1.5

## Dash length on a flooded island's outline, in screen pixels.
##
## Held in screen pixels rather than image ones so the dashes stay the same size at
## every zoom: they are a property of the mark, not of the image under it, and dashes
## that grew with a zoom would turn into a solid line long before the pixels did.
const MARKER_DASH := 5.0
const MARKER_FILL_ALPHA := 0.14

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
const BUSY_SCRIM_ALPHA := 0.3
const BUSY_BAR_WIDTH := 220.0
const BUSY_BAR_HEIGHT := 6.0

## Seconds the overlay takes to come up, and to go away again.
##
## Most runs are short, and an overlay that snapped on and off for every one of them
## turned the preview into a flicker — the eye is caught by the change rather than by
## the result, which is the opposite of what the thing is for. Fading means a run that
## finishes inside this never reaches full strength: it shows as a swell rather than a
## flash, and the shorter it is the less there is to see.
##
## Long enough to read as a fade rather than a fast cut, short enough that a run which
## really is slow has its bar up almost at once.
const BUSY_FADE_TIME := 0.5

## The second bar, under the first: how far through the stage that is running, where
## the one above is how far through the whole stack.
##
## Thinner and dimmer, because it is the subordinate reading. Two bars of equal weight
## would leave the user working out which is which every time they looked.
const BUSY_STAGE_BAR_HEIGHT := 3.0
const BUSY_STAGE_BAR_GAP := 3.0

## Shown while nothing has said which stage is running.
const BUSY_CAPTION := "Processing…"

## The panel the whole overlay sits in, so that a spinner and a caption over busy
## artwork read as one thing rather than as marks on the image.
const BUSY_PANEL_ALPHA := 0.72
const BUSY_PANEL_RADIUS := 10
const BUSY_PANEL_PADDING := 18.0

## Closest the panel may come to the edge of the view, which is what decides how
## much room the contents have on a narrow preview column.
const BUSY_PANEL_MARGIN := 12.0

## Diameter of the spinner, and the gap between it and what sits under it.
##
## Drawn rather than loaded from a PNG. Arcs stay crisp at any size and at any
## editor scale, pick up the theme's accent colour, and cannot go missing — which
## is worth more here than artwork would be, since this is the one thing on screen
## whose whole job is to be noticed.
const BUSY_RING_SIZE := 78.0
const BUSY_SPINNER_GAP := 10.0

## Stroke width as a fraction of the diameter, rather than a number of pixels.
##
## Proportional so the ring keeps its proportions when it has to shrink into a
## narrow preview column — a fixed stroke would turn a small spinner into a blob
## and leave a large one looking like wire.
const BUSY_RING_THICKNESS := 0.115

## Segments in the two arcs. Enough that the ring reads as round at full size,
## which is where faceting would show.
const BUSY_RING_SEGMENTS := 64

## How the spinner turns.
##
## Not at a constant rate: the wobble term takes a tenth of a turn off and puts it
## back once or so a second, which reads as something working at a thing rather
## than as a wheel freewheeling. The numbers are picked so it never quite reverses
## — the wobble's own peak rate is [code]0.10 * TAU * 1.3[/code], a hair under the
## base rate — so it slows almost to a stop and then picks up again.
const BUSY_SPIN_TURNS_PER_SECOND := 0.85
const BUSY_SPIN_WOBBLE_TURNS := 0.10
const BUSY_SPIN_WOBBLE_HZ := 1.3

## Fraction of the ring the drawn fallback spinner fills.
const BUSY_SPIN_SWEEP := 0.28

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
		_cancel_region()
		_update_cursor()

## While set, a left drag in [member pick_mode] sweeps a rectangle and reports it
## through [signal region_picked] rather than reporting the pressed pixel through
## [signal pixel_picked].
##
## A property rather than a second pick mode, because everything else about picking is
## the same — the crosshair, who owns it, how Ctrl takes the button back for panning.
## What differs is only whether the gesture is a click or a sweep, and that is the
## tool's business: the island picker wants a region, the colour picker wants the one
## pixel under the pointer and would have nothing to do with a rectangle.
var region_pick := false:
	set(value):
		if region_pick == value:
			return
		region_pick = value
		# A sweep in flight belongs to the tool that had the crosshair. Letting it
		# survive the handover would report it to whoever holds it next.
		_cancel_region()

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

## How far through the stage that is running, and which one it is.
##
## Separate from [member _progress] because the two answer different questions: how
## far through the whole stack, and how far through the thing currently doing the
## work. A single fraction cannot say both, and without the second a stack that spends
## four seconds in one stage looks identical to one that has hung.
var _stage_progress := 0.0
var _stage_label := ""

## How far the overlay has faded up, 0 to 1, ramped over [constant BUSY_FADE_TIME]
## towards whatever [member _busy] currently is.
##
## Separate from [member _busy] because the two are no longer the same thing: a run
## can be over while its overlay is still on screen on its way out, and the next run
## can start again from wherever that had got to rather than from nothing.
##
## Linear here and eased where it is drawn, so what accumulates is a plain fraction of
## the fade time and the curve stays a decision the drawing makes.
var _busy_fade := 0.0

## Seconds the current run has been on screen, which is all the spinner needs to
## know. Reset per run so every one starts from the same place.
var _spin_time := 0.0

## Built once. A StyleBox is the only way to get a rounded rectangle out of a
## CanvasItem — draw_rect has square corners and nothing else.
var _busy_panel: StyleBoxFlat

var _texture: Texture2D

## The untouched source, drawn over the result at [member original_fade].
##
## Held as a second texture and blended at draw time rather than mixed into one
## image: the fade is something the user drags, and re-blending a few megapixels
## per step would make it stutter exactly while being used.
var _original_texture: Texture2D

var _checker: Texture2D
var _image_size := Vector2i.ZERO

## Picked regions, in image coordinates. A one by one rectangle is a single picked
## pixel and is drawn as the marker it always was.
var _markers: Array[Rect2i] = []
## A byte per marker: zero means the island is switched off and draws hollow.
var _marker_enabled := PackedByteArray()

## A byte per marker: one means the rectangle is where a run found the flood reached
## rather than where the pick was made, and is dashed to say so.
var _marker_flooded := PackedByteArray()
var _selected_marker := -1

## The sweep in progress: where the button went down, and where the pointer is now.
## An anchor of (-1, -1) means there is no sweep.
var _region_anchor := Vector2i(-1, -1)
var _region_cursor := Vector2i(-1, -1)

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
	# Off until there is a spinner to turn; see set_busy.
	set_process(false)
	_relayout()


## Runs while the overlay is on screen at all, which outlasts the run itself by the
## length of the fade.
func _process(delta: float) -> void:
	# Kept turning on the way out. A spinner that stops dead and then fades is two
	# endings for one event, and the first of them says the wrong thing — that the
	# work has stalled rather than finished.
	_spin_time += delta

	var target := 1.0 if _busy else 0.0
	if not is_equal_approx(_busy_fade, target):
		var step := delta / BUSY_FADE_TIME
		_busy_fade = minf(_busy_fade + step, target) if target > _busy_fade \
				else maxf(_busy_fade - step, target)
	elif not _busy:
		# Faded out and nothing running: the last frame of the fade has been drawn, so
		# there is nothing left to animate until the next run.
		_busy_fade = 0.0
		set_process(false)

	_canvas.queue_redraw()


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
## Rectangles rather than points, since an island is a region picked rather than a
## pixel picked. A one by one rectangle draws as the ringed dot a single pick always
## was, so the two read as the same kind of thing at either size.
##
## [param enabled] runs alongside, a byte per marker. A switched-off island keeps
## its marker rather than vanishing — where it is remains worth seeing while it is
## set aside — but is drawn hollow so the list and the image agree.
##
## [param flooded] runs alongside too, and says which rectangles are where a run found
## the flood reached rather than where the user picked. Those are dashed, because the
## two are different claims about the image and only one of them is something the user
## chose. Without it every marker is taken to be a pick, which is what it is until a
## run has said otherwise.
func set_markers(
		markers: Array[Rect2i],
		selected: int,
		enabled := PackedByteArray(),
		flooded := PackedByteArray()) -> void:
	# Copied, not aliased: the caller's array belongs to the operation and can
	# change underneath us without a redraw being requested.
	_markers = markers.duplicate()
	_marker_enabled = enabled.duplicate()
	_marker_flooded = flooded.duplicate()
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
## the first one left off. Neither end is immediate: both are a target for the fade in
## [method _process] to travel towards, so a run that begins during the last one's exit
## turns it round from wherever it had reached rather than snapping back to full.
func set_busy(active: bool) -> void:
	if active:
		# The bar resets even when a run was already going, since a replacement run
		# starts from nothing and showing it inheriting the abandoned one's place
		# would be a lie about how far along it is.
		_progress = 0.0
		_stage_progress = 0.0
		_stage_label = ""
		if not _busy:
			# The spinner does not, though. It is saying work is happening, and one
			# run giving way to another has not stopped it happening — restarting it
			# would put a stutter in the one thing on screen that must look continuous.
			# The same holds while the previous run's overlay is still fading: it is
			# still on screen, so it is still one the eye can follow.
			if _busy_fade <= 0.0:
				_spin_time = 0.0
			_busy = true
			# Nothing here animates between runs, so the frame loop only runs while
			# there is something to turn or to fade.
			set_process(true)
		_canvas.queue_redraw()
		return

	if not _busy:
		return
	_busy = false
	# Deliberately still processing: the overlay has to be carried out rather than
	# taken away, and [member _progress] is left where the run left it so the bar
	# fades from what it reached instead of emptying first.
	set_process(true)
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


## How far along the stage named [param label] says it is, 0 to 1.
##
## Ratcheted within a stage for the same reason the bar above is, but deliberately not
## across them: this one is meant to reset every time the run moves on, and that reset
## is most of what it is saying. The label changing is what a new stage looks like from
## here, so it is what clears the ratchet.
func set_stage_progress(fraction: float, label: String) -> void:
	if not _busy:
		return
	var changed := label != _stage_label
	if changed:
		_stage_label = label
		_stage_progress = 0.0
	var clamped := maxf(_stage_progress, clampf(fraction, 0.0, 1.0))
	if not changed and is_equal_approx(_stage_progress, clamped):
		return
	_stage_progress = clamped
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
	# After panning for that reason, and before everything below because a sweep owns
	# the left button outright for as long as it is held.
	if _handle_region_pick(event):
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


## Sweeps a rectangle with the left button while [member region_pick] is set. Returns
## whether the event was consumed.
##
## The gesture is one thing from press to release, so a click is not a case of its own:
## a press and release without motion leaves the anchor and the cursor on the same
## pixel and reports a one by one rectangle.
func _handle_region_pick(event: InputEvent) -> bool:
	if not pick_mode or not region_pick:
		return false

	var button := event as InputEventMouseButton
	if button != null and button.button_index == MOUSE_BUTTON_LEFT:
		if button.pressed:
			# Starting off the image is not a sweep of nothing, it is a miss — the
			# same answer a click there has always given.
			var pixel := _pixel_at(button.position)
			if pixel.x < 0:
				return false
			_region_anchor = pixel
			_region_cursor = pixel
			_canvas.queue_redraw()
			_canvas.accept_event()
			return true
		if _region_anchor.x < 0:
			return false
		_finish_region()
		_canvas.accept_event()
		return true

	if _region_anchor.x < 0 or not (event is InputEventMouseMotion):
		return false

	# A release swallowed elsewhere — an alt-tab mid-drag — would otherwise leave the
	# band stuck to the cursor. The sweep is reported rather than dropped: it happened,
	# and only its ending went missing.
	if not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_finish_region()
		return false

	# Clamped rather than dropped, so a rectangle dragged off the edge of the image
	# stops at it instead of freezing where the pointer last was inside.
	var moved := _pixel_at_clamped(event.position)
	if moved != _region_cursor:
		_region_cursor = moved
		_canvas.queue_redraw()
	_canvas.accept_event()
	return true


## Ends the sweep and reports it.
func _finish_region() -> void:
	var region := _region_bounds()
	_region_anchor = Vector2i(-1, -1)
	_region_cursor = Vector2i(-1, -1)
	_canvas.queue_redraw()
	if region.size.x > 0 and region.size.y > 0:
		region_picked.emit(region)


## Drops the sweep without reporting it, for the cases where the tool it belonged to
## has gone away underneath it.
func _cancel_region() -> void:
	if _region_anchor.x < 0:
		return
	_region_anchor = Vector2i(-1, -1)
	_region_cursor = Vector2i(-1, -1)
	if _canvas != null:
		_canvas.queue_redraw()


## The rectangle between the anchor and the cursor, inclusive of both, or an empty one
## when no sweep is in progress.
##
## Inclusive because the two ends are pixels the user pointed at rather than corners
## between pixels: dragging from (4, 4) to (6, 6) means nine pixels, not four.
func _region_bounds() -> Rect2i:
	if _region_anchor.x < 0 or _region_cursor.x < 0:
		return Rect2i()
	var from := Vector2i(
		mini(_region_anchor.x, _region_cursor.x),
		mini(_region_anchor.y, _region_cursor.y),
	)
	var to := Vector2i(
		maxi(_region_anchor.x, _region_cursor.x),
		maxi(_region_anchor.y, _region_cursor.y),
	)
	return Rect2i(from, to - from + Vector2i.ONE)


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
	# Deliberately outside the markers_visible test the two above obey: H is for
	# getting the overlays off the edges being judged, and a sweep in progress is not
	# an overlay but the thing the user is doing this instant.
	_draw_region_band()
	# Over everything, including the overlays, since it is about the whole view
	# rather than about anything drawn on it.
	_draw_busy()


func _draw_markers() -> void:
	if not markers_visible:
		return
	var frame := Rect2i(Vector2i.ZERO, _image_size)
	for i in _markers.size():
		var region := _markers[i]
		# Regions picked on a different image may fall outside this one.
		if region.size.x <= 0 or region.size.y <= 0 or not frame.intersects(region):
			continue
		var selected := i == _selected_marker
		var on := i >= _marker_enabled.size() or _marker_enabled[i] != 0
		var color := MARKER_SELECTED_COLOR if selected else MARKER_COLOR
		if not on:
			color = MARKER_DISABLED_SELECTED_COLOR if selected else MARKER_DISABLED_COLOR
		if i < _marker_flooded.size() and _marker_flooded[i] != 0:
			_draw_flood_marker(region, color, selected)
		elif region.size == Vector2i.ONE:
			_draw_point_marker(region.position, color, selected, on)
		else:
			_draw_region_marker(region, color, selected, on)


## A single picked pixel: the ringed dot the picker has always drawn.
func _draw_point_marker(point: Vector2i, color: Color, selected: bool, on: bool) -> void:
	var center := _content_origin + (Vector2(point) + Vector2(0.5, 0.5)) * _scale()
	var radius := MARKER_RADIUS + (1.0 if selected else 0.0)
	# Dark ring underneath so the marker reads against light and dark art.
	_canvas.draw_arc(center, radius + 1.0, 0.0, TAU, 24, MARKER_SHADOW_COLOR, 3.0)
	_canvas.draw_arc(center, radius, 0.0, TAU, 24, color, 1.5)
	# Hollow when switched off, so a marker that is only a reminder cannot be
	# mistaken for one that is doing something.
	if on:
		_canvas.draw_circle(center, 1.5, color)


## A picked rectangle: outlined rather than filled, because what is underneath it is
## the whole point — a fill over the region would hide the edge being judged.
##
## Faintly shaded when it is the highlighted row, which is the one case where saying
## which region is which beats seeing through it.
func _draw_region_marker(region: Rect2i, color: Color, selected: bool, on: bool) -> void:
	var scale := _scale()
	var box := Rect2(
		_content_origin + Vector2(region.position) * scale,
		Vector2(region.size) * scale,
	)
	if selected and on:
		_canvas.draw_rect(box, Color(color, MARKER_FILL_ALPHA), true)
	_canvas.draw_rect(box, MARKER_SHADOW_COLOR, false, MARKER_WIDTH + 2.0)
	_canvas.draw_rect(box, color, false, MARKER_WIDTH + (1.0 if selected else 0.0))


## What an island's flood actually reached, as a dashed box round its bounds.
##
## Dashed rather than solid because it is a different claim from the outline beside it.
## A picked rectangle is where the user drew; this is how far the image then let the
## flood get, which is the thing worth seeing — a click is one pixel, and one pixel says
## nothing about how much keying it took out. Dashes also survive lying on top of the
## edge they are describing, where a solid line of the same weight reads as part of it.
##
## Never shaded inside, unlike a picked region: this box is drawn around whatever the
## flood took, which is exactly the thing being judged, and a wash over it would tint
## the pixels the user is trying to read. The outline alone says where it reached.
##
## Selection is carried by weight and colour rather than by a fill, for the same reason.
func _draw_flood_marker(region: Rect2i, color: Color, selected: bool) -> void:
	var scale := _scale()
	var box := Rect2(
		_content_origin + Vector2(region.position) * scale,
		Vector2(region.size) * scale,
	)
	# The backing dashed in step with the line over it, so it reads as a shadow rather
	# than as a second dashed box.
	_draw_dashed_rect(box, MARKER_SHADOW_COLOR, MARKER_WIDTH + 2.0)
	_draw_dashed_rect(box, color, MARKER_WIDTH + (1.0 if selected else 0.0))


## A dashed rectangle, drawn as its four sides.
##
## Each side is dashed from its own start, which is what keeps the corners closed: with
## [code]aligned[/code] every line begins and ends on a dash, so the four meet instead
## of leaving a gap at each corner where two runs of dashes happened to land.
func _draw_dashed_rect(box: Rect2, color: Color, width: float) -> void:
	var top_left := box.position
	var top_right := box.position + Vector2(box.size.x, 0.0)
	var bottom_right := box.position + box.size
	var bottom_left := box.position + Vector2(0.0, box.size.y)
	_canvas.draw_dashed_line(top_left, top_right, color, width, MARKER_DASH)
	_canvas.draw_dashed_line(top_right, bottom_right, color, width, MARKER_DASH)
	_canvas.draw_dashed_line(bottom_right, bottom_left, color, width, MARKER_DASH)
	_canvas.draw_dashed_line(bottom_left, top_left, color, width, MARKER_DASH)


## The rectangle being swept, drawn as it is dragged.
func _draw_region_band() -> void:
	var region := _region_bounds()
	if region.size.x <= 0 or region.size.y <= 0:
		return
	var scale := _scale()
	var box := Rect2(
		_content_origin + Vector2(region.position) * scale,
		Vector2(region.size) * scale,
	)
	_canvas.draw_rect(box, Color(MARKER_SELECTED_COLOR, MARKER_FILL_ALPHA), true)
	_canvas.draw_rect(box, MARKER_SHADOW_COLOR, false, MARKER_WIDTH + 2.0)
	_canvas.draw_rect(box, MARKER_SELECTED_COLOR, false, MARKER_WIDTH)


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
	# Not [member _busy]: a finished run is still on screen for the length of its fade,
	# and this is the only thing that says whether there is anything left to draw.
	var fade := _busy_alpha()
	if fade <= 0.0:
		return

	_canvas.draw_rect(
		Rect2(Vector2.ZERO, _viewport), Color(0, 0, 0, BUSY_SCRIM_ALPHA * fade), true)

	var accent := Color(0.4, 0.6, 1.0)
	if has_theme_color(&"accent_color", &"Editor"):
		accent = get_theme_color(&"accent_color", &"Editor")
	# Carries the fade into both bars and the spinner arc, which are the only things
	# drawn in it. [method Color.darkened] leaves alpha alone, so the stage bar's
	# dimmer shade inherits this too.
	accent.a *= fade

	var font := get_theme_default_font()
	var font_size := get_theme_default_font_size()
	# The running stage's name rather than a fixed word, so a slow stack says which
	# part of it is slow instead of only that it is.
	var caption_text := _stage_label if not _stage_label.is_empty() else BUSY_CAPTION
	var caption := Vector2.ZERO
	if font != null:
		caption = font.get_string_size(caption_text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size)

	# Everything has to fit between the panel's padding and the view's edges, so
	# the room left for the contents is what is worked out first and everything
	# below sizes itself against it.
	var room := Vector2(
		maxf(_viewport.x - (BUSY_PANEL_MARGIN + BUSY_PANEL_PADDING) * 2.0, 0.0),
		maxf(_viewport.y - (BUSY_PANEL_MARGIN + BUSY_PANEL_PADDING) * 2.0, 0.0),
	)
	if room.x <= 0.0 or room.y <= 0.0:
		return

	var spinner := _spinner_size(room, caption.y)
	var bar_width := minf(BUSY_BAR_WIDTH, room.x)

	# Stacked and centred as one group, so a short preview column drops the bar
	# rather than pushing the spinner off its middle.
	var stack := spinner.y
	if caption.y > 0.0:
		stack += BUSY_SPINNER_GAP + caption.y
	if bar_width > 0.0:
		stack += BUSY_SPINNER_GAP + BUSY_BAR_HEIGHT + BUSY_STAGE_BAR_GAP + BUSY_STAGE_BAR_HEIGHT
	var content := Vector2(maxf(maxf(spinner.x, caption.x), bar_width), stack)

	# The panel first, since everything else is drawn on top of it.
	var panel := Rect2(
		Vector2(
			floorf((_viewport.x - content.x) * 0.5 - BUSY_PANEL_PADDING),
			floorf((_viewport.y - content.y) * 0.5 - BUSY_PANEL_PADDING),
		),
		(content + Vector2(BUSY_PANEL_PADDING, BUSY_PANEL_PADDING) * 2.0).floor(),
	)
	_canvas.draw_style_box(_panel_style(), panel)

	var top := floorf((_viewport.y - content.y) * 0.5)

	_draw_spinner(Vector2(floorf(_viewport.x * 0.5), top + spinner.y * 0.5), spinner, accent)
	top += spinner.y

	if caption.y > 0.0:
		top += BUSY_SPINNER_GAP
		_canvas.draw_string(
			font,
			# draw_string takes the baseline, not the top of the line.
			Vector2(floorf((_viewport.x - caption.x) * 0.5), top + font.get_ascent(font_size)),
			caption_text,
			HORIZONTAL_ALIGNMENT_LEFT,
			-1.0,
			font_size,
			Color(1, 1, 1, 0.85 * fade),
		)
		top += caption.y

	if bar_width <= 0.0:
		return
	top += BUSY_SPINNER_GAP
	var origin := Vector2(floorf((_viewport.x - bar_width) * 0.5), floorf(top))

	_draw_bar(origin, bar_width, BUSY_BAR_HEIGHT, _progress, accent, true)
	_draw_bar(
		origin + Vector2(0.0, BUSY_BAR_HEIGHT + BUSY_STAGE_BAR_GAP),
		bar_width,
		BUSY_STAGE_BAR_HEIGHT,
		_stage_progress,
		accent.darkened(0.35),
		false,
	)


## One progress bar. Track first, then the fill over it, so a fraction of zero still
## reads as a bar waiting rather than as nothing at all.
##
## [param outlined] is for the upper bar only: an outline around the thin one would be
## most of its height.
func _draw_bar(origin: Vector2, width: float, height: float, fraction: float, fill: Color, outlined: bool) -> void:
	# The fill arrives already faded, since its colour is the caller's; the track and
	# the outline are this function's own and have to be faded here.
	var fade := _busy_alpha()
	_canvas.draw_rect(Rect2(origin, Vector2(width, height)), Color(0, 0, 0, 0.55 * fade), true)
	if fraction > 0.0:
		_canvas.draw_rect(Rect2(origin, Vector2(floorf(width * fraction), height)), fill, true)
	if outlined:
		_canvas.draw_rect(
			Rect2(origin, Vector2(width, height)), Color(1, 1, 1, 0.25 * fade), false, 1.0)


## The spinner at [param center], turned to wherever the run has got to in time.
##
## The bar says how far along the work is and the spinner says the work is still
## happening. They answer different questions: a bar that has not moved for four
## seconds is indistinguishable from one that has hung, and a stage of this
## operation can easily take that long.
func _draw_spinner(center: Vector2, size: Vector2, accent: Color) -> void:
	var turns := _spin_time * BUSY_SPIN_TURNS_PER_SECOND \
			+ BUSY_SPIN_WOBBLE_TURNS * sin(TAU * BUSY_SPIN_WOBBLE_HZ * _spin_time)
	var angle := TAU * turns
	var radius := minf(size.x, size.y) * 0.5
	if radius <= 0.0:
		return

	# Kept off the outer edge, since a stroke straddles the radius it is drawn at
	# and half of it would otherwise sit outside the size asked for.
	var thickness := maxf(radius * 2.0 * BUSY_RING_THICKNESS, 1.0)
	radius -= thickness * 0.5

	# A faint full ring under a bright arc running round it. The ring underneath is
	# what keeps the arc from reading as a stray mark at the moments the wobble has
	# it nearly stopped.
	_canvas.draw_arc(
		center,
		radius,
		0.0,
		TAU,
		BUSY_RING_SEGMENTS,
		# The arc over it arrives faded with the accent; this one is the spinner's own.
		Color(1, 1, 1, 0.18 * _busy_alpha()),
		thickness,
		true,
	)
	_canvas.draw_arc(
		center,
		radius,
		angle,
		angle + TAU * BUSY_SPIN_SWEEP,
		BUSY_RING_SEGMENTS,
		accent,
		thickness,
		true,
	)


## How big to draw the spinner, given the [param room] the panel has and the
## [param caption_height] that has to share it.
##
## Fixed at [constant BUSY_RING_SIZE] until the view is too small to hold it, and
## then square, so it turns round rather than wobbling on an oval.
func _spinner_size(room: Vector2, caption_height: float) -> Vector2:
	# What is left once the caption and the bar have taken their share, so a short
	# view shrinks the spinner rather than pushing them out of the panel.
	var spare := room.y - BUSY_BAR_HEIGHT - BUSY_SPINNER_GAP
	if caption_height > 0.0:
		spare -= caption_height + BUSY_SPINNER_GAP

	var ring := minf(BUSY_RING_SIZE, minf(room.x, maxf(spare, 0.0)))
	return Vector2(ring, ring)


## The rounded black panel behind the overlay, built on first use.
##
## Its colour is set on every call rather than only on the first, since it is the one
## part of the overlay whose fade cannot be applied at the draw — a StyleBox carries
## its own.
func _panel_style() -> StyleBoxFlat:
	if _busy_panel == null:
		_busy_panel = StyleBoxFlat.new()
		_busy_panel.set_corner_radius_all(BUSY_PANEL_RADIUS)
	_busy_panel.bg_color = Color(0, 0, 0, BUSY_PANEL_ALPHA * _busy_alpha())
	return _busy_panel


## The opacity the overlay is drawn at: [member _busy_fade], eased.
##
## Eased rather than taken straight, because a linear fade is not seen as an even one
## — it appears to arrive suddenly and then crawl. Smoothing both ends is most of what
## makes this read as the overlay arriving rather than as it being switched on.
func _busy_alpha() -> float:
	return smoothstep(0.0, 1.0, _busy_fade)


static func _build_checker() -> Texture2D:
	var image := Image.create_empty(CHECKER_SIZE * 2, CHECKER_SIZE * 2, false, Image.FORMAT_RGB8)
	image.fill(CHECKER_DARK)
	image.fill_rect(Rect2i(0, 0, CHECKER_SIZE, CHECKER_SIZE), CHECKER_LIGHT)
	image.fill_rect(Rect2i(CHECKER_SIZE, CHECKER_SIZE, CHECKER_SIZE, CHECKER_SIZE), CHECKER_LIGHT)
	return ImageTexture.create_from_image(image)
