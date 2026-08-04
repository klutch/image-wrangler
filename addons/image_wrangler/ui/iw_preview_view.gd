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

## Emitted for each new pixel a stroke drag reaches, while [member stroke_pick] is on.
##
## [param starting] marks the press that opened the drag, so the receiver knows to begin a
## stroke rather than extend the one before it. One signal rather than a start and an
## extend: the two carry the same thing and differ by a flag, and a receiver that handled
## one but not the other would be a stroke that silently went to the wrong entry.
signal stroke_point(pixel: Vector2i, starting: bool)

## Emitted when the button comes up, or when a drag is abandoned.
signal stroke_finished

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

## Emitted when a pivot drag ends, while [member pivot_pick] is on.
##
## [param at] is the pixel the press landed on, which says both where the pivot goes and
## which sprite it belongs to. [param delta] is how far the drag ran from there, in image
## pixels, and is left raw — [method Pivot.direction_from] is what turns it into a
## direction, and a drag that never moved is a zero this way rather than a made-up vector.
signal pivot_drawn(at: Vector2i, delta: Vector2)

## Emitted whenever the zoom level changes, from any source.
signal zoom_changed(percent: float)

const CHECKER_SIZE := 8
const CHECKER_DARK := Color(0.16, 0.16, 0.18)
const CHECKER_LIGHT := Color(0.24, 0.24, 0.27)

## What [member magenta_background] lays under the image.
##
## Full magenta rather than anything softer, and deliberately a colour no photograph and
## almost no piece of art contains: the whole job is to be a colour that cannot be mistaken
## for the picture, so that a pixel showing any of it is a pixel that is not fully there.
## The checkerboard is the everyday backing and this is the one you switch to when a faint
## fringe or a pinhole has to be found rather than judged.
const TRANSPARENCY_COLOR := Color(1, 0, 1)

## The line drawn round the image's own edge, and how thick it is on screen.
##
## An image that is transparent at its corners has no visible edge at all against the
## checkerboard, so where the picture stops has to be stated rather than shown. One screen
## pixel whatever the zoom, since this is about the boundary and not about any pixel
## inside it — a line that grew with the zoom would start reading as part of the artwork.
const BORDER_COLOR := Color(0, 0, 0)
const BORDER_WIDTH := 1.0

## What a mark is drawn in when its operation gave no colour of its own.
##
## Softer than solid on purpose: these sit over the edges the tool exists to judge, and
## have to be readable without being what you look at.
const MARKER_FALLBACK_COLOR := Color(1, 1, 1)

## How present a mark is, by what it is saying.
##
## The colour now says which operation a mark belongs to, so the state it is in has to
## say itself some other way, and strength is it. Selected also draws a step thicker and
## takes a fill; switched off keeps its mark rather than vanishing — where it is stays
## worth seeing while it is set aside — but drops back far enough that the image agrees
## with the greyed row in the list.
const MARKER_ALPHA := 0.6
const MARKER_SELECTED_ALPHA := 1.0
const MARKER_DISABLED_ALPHA := 0.27

## How much of a held-back tile is laid back over the result, where the operation that
## held it back does not say.
##
## Faint enough that nothing here can be mistaken for part of the picture, and strong
## enough to say which tile it was rather than merely that something is missing.
const GHOST_ALPHA := 0.2

## The rectangle being dragged out this instant.
##
## One fixed colour rather than the tint of whatever operation is picking. It is the
## gesture in progress, not a mark on the result, and it disappears the moment the button
## comes up — so it has nothing to be told apart from.
const SWEEP_COLOR := Color(1.0, 1.0, 0.2)

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

## How far round the colour wheel each tile patch steps from the one before it.
##
## The golden ratio's fractional part, which is what makes a walk round a circle never
## repeat and never bunch up: any run of consecutive steps lands spread out rather than
## clustered. A colour per tile drawn from a plain random number would do neither, and the
## one thing these patches have to do is differ from the tile next to them — two neighbours
## that happened to roll the same hue would read as one tile, which is the only mistake this
## overlay can make.
const TILE_HUE_STEP := 0.6180339887

## Saturation and value every tile patch is drawn at.
##
## Fixed rather than rolled with the hue. Letting all three vary gives colours that differ
## in ways the eye reads as lighting rather than as identity — a dark one looks like shadow
## on its neighbour instead of a separate tile — where one band of brightness makes every
## patch obviously its own thing.
const TILE_SATURATION := 0.65
const TILE_VALUE := 0.80

## Half-width of a polygon's draggable corner handle, in screen pixels, and how
## near the pointer has to be to grab one. Generous on purpose: at low zoom a
## whole image pixel is a fraction of a screen pixel and an exact hit would be
## impossible.
const HANDLE_SIZE := 3.5
const HANDLE_GRAB := 7.0

## Opacity of the shading inside a finished polygon. Enough to read as filled,
## little enough to judge the art underneath.
const POLYGON_WIDTH := 1.5

## A pivot: a yellow dot in a dark orange rim where it sits, a cyan arm to the way it
## faces, and a light grey dot on a dark grey backing at the end of that arm.
##
## Two dots that cannot be confused with each other, since one is a position and one is a
## direction and dragging the wrong one is the mistake this overlay can invite.
const PIVOT_COLOR := Color(1.0, 0.85, 0.2)
const PIVOT_RIM_COLOR := Color(0.55, 0.27, 0.0)
const PIVOT_ARM_COLOR := Color(0.2, 0.9, 1.0)
const PIVOT_TIP_COLOR := Color(0.85, 0.85, 0.85)
const PIVOT_TIP_BACK_COLOR := Color(0.15, 0.15, 0.15)

## How the pivot marks are sized, in screen pixels at every zoom.
##
## The arm has to be a screen length rather than an image one: the vector it stands for is
## one pixel long, which at any ordinary zoom is nothing to see and nothing to grab.
const PIVOT_RADIUS := 3.5
const PIVOT_TIP_RADIUS := 3.0
const PIVOT_RIM_WIDTH := 1.5
const PIVOT_ARM_LENGTH := 30.0
const PIVOT_ARM_WIDTH := 1.5

## How much larger the highlighted pivot's dot is drawn, so the row picked in the list can
## be found on a sheet with a hundred of them.
const PIVOT_SELECTED_SCALE := 1.5

## The working overlay — scrim, spinner, caption, bars and log — from its own scene.
## Dimmed rather than covered, because the point of the preview is the image and the
## point of the overlay is that what you are looking at is one revision out of date.
const BusyOverlayScene := preload("res://addons/image_wrangler/scenes/iw_busy_overlay.tscn")

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

## While set, a left drag in [member pick_mode] paints: every pixel it crosses is reported
## through [signal stroke_point], and letting go reports [signal stroke_finished].
##
## A third property beside [member region_pick] rather than an enum of pick kinds, because
## that is the shape the other two already have and an enum would mean rewriting both to
## add the third. They are mutually exclusive in practice — the dock sets exactly one from
## whichever control holds the crosshair — and this one is tested first where they meet.
var stroke_pick := false:
    set(value):
        if stroke_pick == value:
            return
        stroke_pick = value
        # A drag in flight belongs to the tool that had the crosshair, the same as a sweep.
        _cancel_stroke()

## While set, the sheet's pivots are drawn and a left drag redefines one.
##
## Its own property beside the three above rather than one of them: nothing else here
## works on a packed sheet, and a gesture that reports both a point and a direction is not
## a click, a sweep or a stroke.
var pivot_pick := false:
    set(value):
        if pivot_pick == value:
            return
        pivot_pick = value
        _pivot_anchor = Vector2i(-1, -1)
        _update_cursor()
        if _canvas != null:
            _canvas.queue_redraw()

## Whether the overlays — island boxes and drawn regions — are drawn at all.
##
## They sit right on top of the edges being judged, so getting them out of the way is
## what the dock's Show Indicators switch is for. Nothing about processing changes; this
## is a repaint.
var markers_visible := true:
    set(value):
        if markers_visible == value:
            return
        markers_visible = value
        if _canvas != null:
            _canvas.queue_redraw()

## Whether a solid magenta ground is laid under the image in place of the checkerboard.
##
## The checkerboard is two greys a shade apart, which is what makes it read as backing
## rather than as picture — and is also what makes a pixel at a tenth alpha invisible over
## it. [constant TRANSPARENCY_COLOR] gives up being unobtrusive to answer the other
## question: anything short of solid takes on some magenta, so a pinhole or a surviving
## fringe shows up as colour rather than having to be spotted as a texture.
##
## Only under the image, not across the whole view. The margins keep their checkerboard, so
## where the image ends is still visible — a magenta view with a magenta image in it would
## have no edges at all.
var magenta_background := false:
    set(value):
        if magenta_background == value:
            return
        magenta_background = value
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

## The working overlay, instanced from its scene in [method _init]. It owns the fade,
## the spinner and the ratcheting bars; the busy setters below forward to it. Only
## ever spoken to from the main thread — the worker reports through the dock, which
## defers, so nothing here is touched from two threads at once.
var _overlay: Control

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

## A colour per marker: the tint of the operation the marker belongs to. Short or empty
## where an operation gave none, which falls back to white.
var _marker_tints := PackedColorArray()

## Pictures of what an operation held back, laid faintly over the result, where each one
## sits on the image, and how strongly each is laid over it.
var _ghosts: Array[Texture2D] = []
var _ghost_regions: Array[Rect2i] = []
var _ghost_alphas := PackedFloat32Array()
var _selected_marker := -1

## Where each packed tile sits on the sheet, in image coordinates, and the colour its
## patch is drawn in.
##
## Empty everywhere but the Packing tab. See [method set_tile_bounds].
var _tiles: Array[Rect2i] = []
var _tile_colors := PackedColorArray()

## The sweep in progress: where the button went down, and where the pointer is now.
## An anchor of (-1, -1) means there is no sweep.
var _region_anchor := Vector2i(-1, -1)
var _region_cursor := Vector2i(-1, -1)

## Whether a stroke drag is in flight, and the last pixel reported for it.
##
## The last pixel is kept so that motion inside one pixel — which is most motion events at
## any zoom above 100% — is dropped here rather than sent on to be dropped there.
var _painting := false
var _paint_last := Vector2i(-1, -1)

## The patch of the image the brush has repainted during the drag in flight, and where it
## sits. Null when nothing is being painted.
##
## [b]The paint is shown as image, not as an outline over one.[/b] A path drawn at the
## brush's width says where the stroke went; it does not say what the stroke did, and on a
## soft brush or a Subtract over something already faint those are different pictures. The
## patch is the answer itself, laid over the region it covers — see
## [method _draw_image_around].
var _patch_texture: Texture2D
var _patch_region := Rect2i()

## The highlighted stroke's own pixels, in one colour, and where they sit. Null when
## nothing is selected.
##
## An image rather than a line at the brush's width: a line says where the stroke went and
## not what it did, and on a soft brush or a Subtract over something already faint those
## are different pictures.
var _brush_overlay: Texture2D
var _brush_overlay_region := Rect2i()

## Drawn regions, as an Array of PackedVector2Array in image coordinates.
var _polygons: Array = []
## A byte per region: zero means it is switched off. It still draws — the shape
## took work to make — but without the fill, since nothing is being cut.
var _polygon_enabled := PackedByteArray()
## A colour per region: the tint of the operation it belongs to, as for the markers.
var _polygon_tints := PackedColorArray()
## Row highlighted in the list. Its corners get grab handles.
var _selected_polygon := -1
## Row being drawn, or -1. Drawn as an open path with a rubber band rather than
## as a closed shape, since it is not one yet.
var _draft_polygon := -1

## Every sprite's pivot, in sheet pixels, and which way each faces. Already resolved by
## the dock, so a sprite nobody edited is in here at the middle of its rectangle.
var _pivot_positions := PackedVector2Array()
var _pivot_directions := PackedVector2Array()
## Sprite whose row is highlighted in the Pivots list, or -1.
var _selected_pivot := -1

## Pixel a pivot drag was pressed on, and where the pointer has reached in image
## coordinates. The anchor is (-1, -1) while no drag is in flight.
var _pivot_anchor := Vector2i(-1, -1)
var _pivot_cursor := Vector2.ZERO

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

    # Over the image and under the scrollbars, so a run dims the picture without
    # taking the bars away.
    _overlay = BusyOverlayScene.instantiate()
    add_child(_overlay)

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
##
## [param tints] runs alongside as well, one colour per marker, saying which operation
## each belongs to. Short or empty falls back to white.
func set_markers(
        markers: Array[Rect2i],
        selected: int,
        enabled := PackedByteArray(),
        flooded := PackedByteArray(),
        tints := PackedColorArray()) -> void:
    # Copied, not aliased: the caller's array belongs to the operation and can
    # change underneath us without a redraw being requested.
    _markers = markers.duplicate()
    _marker_enabled = enabled.duplicate()
    _marker_flooded = flooded.duplicate()
    _marker_tints = tints.duplicate()
    _selected_marker = selected
    _canvas.queue_redraw()


## Shows what operations have held back, faintly, over the result.
##
## [param images] and [param regions] run alongside each other, one pair per operation with
## something to show. Pass empty arrays to clear them.
##
## [param alphas] runs alongside them too, saying how strongly each is laid over the
## result. Short or empty where an operation gave none, which falls back to
## [constant GHOST_ALPHA].
func set_ghosts(images: Array, regions: Array,
        alphas := PackedFloat32Array()) -> void:
    _ghosts.clear()
    _ghost_regions.clear()
    _ghost_alphas.clear()
    for i in mini(images.size(), regions.size()):
        var image: Image = images[i]
        var region: Rect2i = regions[i]
        if image == null or image.is_empty() or region.size.x <= 0 or region.size.y <= 0:
            continue
        _ghosts.append(ImageTexture.create_from_image(image))
        _ghost_regions.append(region)
        _ghost_alphas.append(alphas[i] if i < alphas.size() else GHOST_ALPHA)
    if _canvas != null:
        _canvas.queue_redraw()


## The colour one mark is drawn in.
##
## The tint says which operation the mark belongs to and the strength says what state it
## is in, so the two never compete for the same channel.
func _mark_color(tints: PackedColorArray, index: int, selected: bool, on: bool) -> Color:
    var base := MARKER_FALLBACK_COLOR
    if index < tints.size() and tints[index].a > 0.0:
        base = tints[index]
    var alpha := MARKER_DISABLED_ALPHA
    if on:
        alpha = MARKER_SELECTED_ALPHA if selected else MARKER_ALPHA
    return Color(base.r, base.g, base.b, alpha)


## Lays a solid patch of colour under each of [param tiles], in image coordinates.
##
## What the Packing tab uses to say where one sprite ends and the next begins. A packed
## sheet is the one picture here whose content cannot be read off itself: the sprites were
## cut on their alpha, so the transparent margin around each one is invisible against the
## transparent gap between them, and two sprites touching look like one. A patch under each
## tile turns the margin into that tile's colour and makes both edges obvious.
##
## [b]Under the image rather than over it.[/b] Over would hide the sprites, which are the
## thing being judged. Underneath, the sprite's own pixels sit on their patch and only the
## empty parts of its rectangle take the colour — so nothing is obscured and the boundary
## is still drawn in full.
##
## Pass an empty Array to clear them. Shown only while indicators are on; see
## [member markers_visible].
func set_tile_bounds(tiles: Array) -> void:
    # Copied rather than aliased, for the reason the markers are: the caller's array
    # belongs to the packing run and can change underneath us without a redraw being asked
    # for.
    _tiles.assign(tiles)
    # Assigned once here rather than rolled per redraw. A tile whose colour changed every
    # time the view was panned would be worse than no colour at all — the eye tracks these
    # by hue, and a hue that moves is not a boundary, it is a flicker.
    _tile_colors = PackedColorArray()
    _tile_colors.resize(_tiles.size())
    for i in _tiles.size():
        _tile_colors[i] = Color.from_hsv(fmod(float(i) * TILE_HUE_STEP, 1.0),
                TILE_SATURATION, TILE_VALUE)
    _canvas.queue_redraw()


## Shows [param polygons] over the image, in image coordinates.
##
## [param selected] gets grab handles on its corners, [param draft] is drawn as an
## open path still being placed. Pass -1 for either when there is none.
## Each region's own swatch is deliberately not taken. It tells one row from another in
## the list; on the image the colour says which operation the shape belongs to and how
## present it is, which is what the island boxes say too. [param tints] carries that,
## one colour per shape.
func set_polygons(
        polygons: Array,
        selected: int,
        draft: int,
        enabled := PackedByteArray(),
        tints := PackedColorArray()) -> void:
    # Converted to float points once here rather than per redraw, and copied for
    # the same reason the markers are: the caller's arrays belong to the operation
    # and can change underneath us without a redraw being asked for.
    _polygons = []
    for points in polygons:
        var converted := PackedVector2Array()
        for point: Vector2i in points:
            converted.append(Vector2(point))
        _polygons.append(converted)
    _polygon_enabled = enabled.duplicate()
    _polygon_tints = tints.duplicate()
    _selected_polygon = selected
    _draft_polygon = draft
    if draft < 0:
        _hover_pixel = Vector2i(-1, -1)
    _canvas.queue_redraw()


## Shows where every sprite's pivot sits and which way it faces, in sheet pixels.
##
## Both arrays run one entry per sprite and come out of [method PivotList.resolve], so the
## defaults are already filled in here — this draws what it is given rather than working
## out what a sprite with no pivot should get. [param selected] is the sprite whose row is
## highlighted, or -1.
##
## Only drawn while [member pivot_pick] is on. Pass empty arrays to clear them.
func set_pivots(positions: PackedVector2Array, directions: PackedVector2Array,
        selected: int) -> void:
    # Copied rather than aliased, for the reason the markers are: the caller's arrays
    # belong to the packing run and can change underneath us without a redraw being asked
    # for.
    _pivot_positions = positions.duplicate()
    _pivot_directions = directions.duplicate()
    _selected_pivot = selected
    if _canvas != null:
        _canvas.queue_redraw()


## Shows the highlighted stroke's own pixels over [param region] of the image.
##
## Laid over rather than replacing, unlike the live patch: this is a mark on the result,
## not a correction to it. Pass null to clear it.
func set_brush_overlay(overlay: Image, region: Rect2i) -> void:
    if overlay == null or overlay.is_empty() or region.size.x <= 0 or region.size.y <= 0:
        if _brush_overlay == null:
            return
        _brush_overlay = null
        _brush_overlay_region = Rect2i()
    else:
        _brush_overlay = ImageTexture.create_from_image(overlay)
        _brush_overlay_region = region
    if _canvas != null:
        _canvas.queue_redraw()


## Lays [param patch] over [param region] of the image, in place of what is there.
##
## What the live brush reports between mouse events. Only the region is uploaded, so the
## cost of a drag is the area the stroke has reached rather than the size of the sheet —
## which is the whole reason this exists rather than the view being handed a fresh copy of
## the image on every motion event.
##
## Replaced rather than blended: a Subtract stroke takes alpha away, and paint drawn over
## the top can only ever add. See [method _draw_image_around], which is what makes the
## replacement possible at all.
func set_live_patch(patch: Image, region: Rect2i) -> void:
    if patch == null or patch.is_empty() or region.size.x <= 0 or region.size.y <= 0:
        clear_live_patch()
        return
    _patch_texture = ImageTexture.create_from_image(patch)
    _patch_region = region
    if _canvas != null:
        _canvas.queue_redraw()


## Puts the view back to showing the image alone, for when the drag has ended and the run
## has taken over.
func clear_live_patch() -> void:
    if _patch_texture == null:
        return
    _patch_texture = null
    _patch_region = Rect2i()
    if _canvas != null:
        _canvas.queue_redraw()


## Puts the view into or out of its working state. The overlay owns what that means —
## the fade, the reset of the bars, the spinner carrying across back-to-back runs.
func set_busy(active: bool) -> void:
    _overlay.set_busy(active)


## How far along the run says it is, 0 to 1. Ratcheted by the overlay so a report out
## of order cannot make the bar stutter.
func set_progress(fraction: float) -> void:
    _overlay.set_progress(fraction)


## How far along the stage named [param label] says it is, 0 to 1.
func set_stage_progress(fraction: float, label: String) -> void:
    _overlay.set_stage_progress(fraction, label)


## Adds [param text] to the lines drawn under the bars, keeping the newest few.
func append_busy_log(text: String) -> void:
    _overlay.append_log(text)


func clear_busy_log() -> void:
    _overlay.clear_log()


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
    # The overlay covers exactly what the canvas does, scrollbars excluded.
    _overlay.position = Vector2.ZERO
    _overlay.size = _viewport

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
    # After panning for that reason, and before everything below because a drag owns the
    # left button outright for as long as it is held. Before the sweep because the two
    # claim the same gesture and the dock never arms both at once.
    if _handle_stroke_pick(event):
        return
    if _handle_region_pick(event):
        return
    if _handle_pivot_drag(event):
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


## Paints with the left button while [member stroke_pick] is set. Returns whether the
## event was consumed.
##
## The gesture is one thing from press to release, so a click is not a case of its own: a
## press and release without motion reports one pixel, which is one dab of the brush.
func _handle_stroke_pick(event: InputEvent) -> bool:
    if not pick_mode or not stroke_pick:
        return false

    var button := event as InputEventMouseButton
    if button != null and button.button_index == MOUSE_BUTTON_LEFT:
        if button.pressed:
            # Starting off the image is a miss rather than a stroke of nothing, the same
            # answer a click there has always given.
            var pixel := _pixel_at(button.position)
            if pixel.x < 0:
                return false
            _painting = true
            _paint_last = pixel
            stroke_point.emit(pixel, true)
            _canvas.accept_event()
            return true
        if not _painting:
            return false
        _painting = false
        _paint_last = Vector2i(-1, -1)
        stroke_finished.emit()
        _canvas.accept_event()
        return true

    if not _painting or not (event is InputEventMouseMotion):
        return false

    # A release swallowed elsewhere — an alt-tab mid-drag — would otherwise leave the
    # brush stuck to the cursor. The stroke is reported rather than dropped: it happened,
    # and only its ending went missing.
    if not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
        _painting = false
        _paint_last = Vector2i(-1, -1)
        stroke_finished.emit()
        return false

    # Clamped rather than dropped, so a stroke dragged off the edge of the image keeps
    # painting along it instead of stopping where the pointer last was inside. Reported
    # only when it has actually left the pixel it was on: at any zoom above 100% most
    # motion events land on the pixel already reported.
    var moved := _pixel_at_clamped(event.position)
    if moved != _paint_last:
        _paint_last = moved
        stroke_point.emit(moved, false)
    _canvas.accept_event()
    return true


## Redefines a pivot with the left button while [member pivot_pick] is set. Returns whether
## the event was consumed.
##
## The press places the pivot and the drag aims it, so a click that never moves is a pivot
## moved and left facing the way it already did rather than a gesture of nothing.
func _handle_pivot_drag(event: InputEvent) -> bool:
    if not pivot_pick:
        return false

    var button := event as InputEventMouseButton
    if button != null and button.button_index == MOUSE_BUTTON_LEFT:
        if button.pressed:
            # Starting off the sheet is a miss: the press is what says which sprite this
            # pivot belongs to, and there is no sprite out there.
            var pixel := _pixel_at(button.position)
            if pixel.x < 0:
                return false
            _pivot_anchor = pixel
            _pivot_cursor = Vector2(pixel)
            _canvas.queue_redraw()
            _canvas.accept_event()
            return true
        if _pivot_anchor.x < 0:
            return false
        _finish_pivot()
        _canvas.accept_event()
        return true

    if _pivot_anchor.x < 0 or not (event is InputEventMouseMotion):
        return false

    # A release swallowed elsewhere — an alt-tab mid-drag — would otherwise leave the arm
    # stuck to the cursor. The drag is reported rather than dropped: it happened, and only
    # its ending went missing.
    if not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
        _finish_pivot()
        return false

    # Unclamped, unlike a sweep or a stroke. Only a direction is being read off it, and a
    # pointer taken past the edge of the sheet still says which way it went.
    _pivot_cursor = _image_position(event.position)
    _canvas.queue_redraw()
    _canvas.accept_event()
    return true


## Ends the pivot drag and reports it.
func _finish_pivot() -> void:
    var at := _pivot_anchor
    var delta := _pivot_cursor - Vector2(at)
    _pivot_anchor = Vector2i(-1, -1)
    _canvas.queue_redraw()
    pivot_drawn.emit(at, delta)


## Drops the drag without reporting an ending, for the cases where the tool it belonged to
## has gone away underneath it.
func _cancel_stroke() -> void:
    if not _painting:
        return
    _painting = false
    _paint_last = Vector2i(-1, -1)
    stroke_finished.emit()


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
    if polygon < 0 or polygon >= _polygons.size():
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
                and (button.ctrl_pressed or not (pick_mode or pivot_pick))
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
    elif pick_mode or pivot_pick:
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


## Where a position in the drawing area falls in image coordinates, kept fractional and
## unbounded — for the pivot arm, which reads a direction rather than a pixel.
func _image_position(local_position: Vector2) -> Vector2:
    var scale := _scale()
    if scale <= 0.0:
        return Vector2.ZERO
    return (local_position - _content_origin) / scale


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
        return
    var frame := Rect2(_content_origin, _content_size)
    # Over the checkerboard and under the image, so the margins still say where the image
    # ends. See the note on the property.
    if magenta_background:
        _canvas.draw_rect(frame, TRANSPARENCY_COLOR, true)
    # Between the backdrop and the image, so each sprite lands on its own patch. See
    # set_tile_bounds for why they go under rather than over.
    _draw_tiles()
    if _patch_texture != null:
        _draw_image_around(_patch_region)
        _canvas.draw_texture_rect(_patch_texture, _image_rect(_patch_region), false)
    else:
        _canvas.draw_texture_rect(_texture, frame, false)
    # Over the top rather than blended into it. Where the source is opaque this
    # is an ordinary cross-fade; where the result cut something away, the source
    # comes back over the checkerboard, which is exactly the comparison being
    # asked for.
    if original_fade > 0.0 and _original_texture != null:
        _canvas.draw_texture_rect(_original_texture, frame, false, Color(1, 1, 1, original_fade))
    # Just outside the image rather than on it, so the line says where the picture stops
    # without covering the outermost row of pixels it is there to bound — which at a zoom
    # of 1 is the difference between marking that row and hiding it.
    _canvas.draw_rect(frame.grow(BORDER_WIDTH * 0.5), BORDER_COLOR, false, BORDER_WIDTH)
    # Under the marks, so an outline round a held-back tile still reads over its ghost.
    _draw_ghosts()
    _draw_markers()
    _draw_polygons()
    _draw_brush()
    _draw_region_band()
    # Over the tile patches and the marks, since a pivot is a point on one sprite and has
    # to be findable on a sheet those have already covered.
    _draw_pivots()


## Where a rectangle of image pixels lands on screen.
func _image_rect(region: Rect2i) -> Rect2:
    var scale := _scale()
    return Rect2(_content_origin + Vector2(region.position) * scale, Vector2(region.size) * scale)


## Draws the image everywhere except [param hole], as up to four bands around it.
##
## [b]The hole is what lets the live patch replace rather than blend.[/b] A patch drawn
## over a complete image can only ever add to it, and a Subtract stroke takes alpha away —
## so the pixels it is replacing must not be underneath it. Cutting the hole is the whole
## of the trick, and it costs four draw calls against the one it replaces.
##
## Written as regions of the source texture rather than by clipping, since the canvas has
## one clip rectangle and it is already spent on the viewport.
func _draw_image_around(hole: Rect2i) -> void:
    var frame := Rect2i(Vector2i.ZERO, _image_size)
    var gap := hole.intersection(frame)
    if gap.size.x <= 0 or gap.size.y <= 0:
        _canvas.draw_texture_rect(_texture, Rect2(_content_origin, _content_size), false)
        return

    for band: Rect2i in [
        # Full width above and below, then the two stubs either side of the hole, so no
        # band overlaps another and every pixel outside the hole is drawn exactly once.
        Rect2i(0, 0, frame.size.x, gap.position.y),
        Rect2i(0, gap.end.y, frame.size.x, frame.size.y - gap.end.y),
        Rect2i(0, gap.position.y, gap.position.x, gap.size.y),
        Rect2i(gap.end.x, gap.position.y, frame.size.x - gap.end.x, gap.size.y),
    ]:
        if band.size.x <= 0 or band.size.y <= 0:
            continue
        _canvas.draw_texture_rect_region(_texture, _image_rect(band), band)


## What operations have held back, laid faintly back over the result.
##
## An indicator rather than part of the picture, so it follows the same switch every other
## mark does and never reaches what gets written out.
func _draw_ghosts() -> void:
    if not markers_visible:
        return
    for i in _ghosts.size():
        var alpha: float = _ghost_alphas[i] if i < _ghost_alphas.size() else GHOST_ALPHA
        if alpha <= 0.0:
            continue
        _canvas.draw_texture_rect(
                _ghosts[i], _image_rect(_ghost_regions[i]), false,
                Color(1, 1, 1, alpha))


## [b]A single picked pixel draws nothing at all until a run has reported.[/b] It used to
## get a ringed dot, which was the wrong statement in the only place it appeared: a click
## is one pixel and one pixel says nothing about how much of the image that pick took out,
## so the dot marked the question rather than the answer — and it sat over the very pixel
## being judged while doing it. The dashed box the run comes back with is the whole of what
## there is to say, and a gap until then is better than a mark that means nothing.
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
        var color := _mark_color(_marker_tints, i, selected, on)
        if i < _marker_flooded.size() and _marker_flooded[i] != 0:
            _draw_flood_marker(region, color, selected)
        elif region.size != Vector2i.ONE:
            # A swept rectangle is still worth outlining before a run: the user drew it,
            # and it is the one pick whose own extent is a thing they chose.
            _draw_region_marker(region, color, selected, on)


## A solid patch of colour under every packed tile.
##
## Behind the indicator switch like every other overlay: it is drawn on top of the answer
## rather than being part of it, and seeing the sheet as it will actually be is one switch
## away. Nothing here is drawn on any tab but Packing, since nothing else sets any tiles.
func _draw_tiles() -> void:
    if not markers_visible or _tiles.is_empty():
        return
    var frame := Rect2i(Vector2i.ZERO, _image_size)
    for i in _tiles.size():
        var tile := _tiles[i]
        # A sprite that did not get placed is a rectangle of no area, and one from an
        # earlier sheet may not fit this one.
        if tile.size.x <= 0 or tile.size.y <= 0 or not frame.intersects(tile):
            continue
        _canvas.draw_rect(_image_rect(tile), _tile_colors[i], true)


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


## The highlighted stroke's own pixels, laid over the result.
##
## The only brush overlay there is. What a stroke is doing while it is being drawn is shown
## by repainting the image itself — see [method set_live_patch] — and what a highlighted
## stroke did is shown by lighting up the pixels it is responsible for. Neither is a shape
## drawn beside the answer; both are the answer.
func _draw_brush() -> void:
    if not markers_visible or _brush_overlay == null:
        return
    _canvas.draw_texture_rect(_brush_overlay, _image_rect(_brush_overlay_region), false)


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
    _canvas.draw_rect(box, Color(SWEEP_COLOR, MARKER_FILL_ALPHA), true)
    _canvas.draw_rect(box, MARKER_SHADOW_COLOR, false, MARKER_WIDTH + 2.0)
    _canvas.draw_rect(box, SWEEP_COLOR, false, MARKER_WIDTH)


## Draws every drawn region: finished ones closed and shaded, the one being
## drawn as an open path trailing a rubber band to the pointer.
## [b]Coloured the way the island boxes are, not by each region's own swatch.[/b] The
## swatch tells one row from another in the list, which is what a list needs; on the
## image the question is a different one — is this the shape I have selected, and is it
## switched on — and that is the same question the boxes answer, so it gets the same
## answer here.
func _draw_polygons() -> void:
    for i in _polygons.size():
        var points: PackedVector2Array = _polygons[i]
        if points.is_empty():
            continue
        var selected := i == _selected_polygon
        var on := i >= _polygon_enabled.size() or _polygon_enabled[i] != 0
        var color := _mark_color(_polygon_tints, i, selected, on)
        var screen := _to_screen(points)
        if i == _draft_polygon:
            # Drawn whether or not the overlays are showing. A shape being placed this
            # instant is not an overlay on the result, it is the thing being done — the
            # same reason the sweep band ignores the switch.
            _draw_draft(screen, color)
        elif markers_visible:
            _draw_finished(screen, color, selected, on)


## Every sprite's pivot, and the one being dragged over the top of them.
##
## Shown only while the Pivots section is armed. They belong to a gesture rather than to
## the result, so they are not on the Show Indicators switch the marks are.
func _draw_pivots() -> void:
    if not pivot_pick:
        return
    var scale := _scale()
    for i in _pivot_positions.size():
        var at := _content_origin + _pivot_positions[i] * scale
        var facing := Pivot.as_image_vector(_pivot_directions[i]) if i < _pivot_directions.size() \
                else Pivot.as_image_vector(Pivot.DEFAULT_DIRECTION)
        _draw_pivot(at, at + facing * PIVOT_ARM_LENGTH, i == _selected_pivot)

    # Last, so the one being aimed is on top of whatever it is being aimed over. Its arm
    # runs to the pointer rather than to a fixed length, which is the whole of the gesture.
    if _pivot_anchor.x >= 0:
        _draw_pivot(_content_origin + Vector2(_pivot_anchor) * scale,
                _content_origin + _pivot_cursor * scale, true)


## One pivot: the dot at [param at], the arm to [param tip], and the dot on the end of it.
func _draw_pivot(at: Vector2, tip: Vector2, selected: bool) -> void:
    var radius := PIVOT_RADIUS * (PIVOT_SELECTED_SCALE if selected else 1.0)
    # The arm first, so both dots sit over it rather than being cut by it.
    _canvas.draw_line(at, tip, PIVOT_ARM_COLOR, PIVOT_ARM_WIDTH, true)
    _canvas.draw_circle(tip, PIVOT_TIP_RADIUS + PIVOT_RIM_WIDTH, PIVOT_TIP_BACK_COLOR)
    _canvas.draw_circle(tip, PIVOT_TIP_RADIUS, PIVOT_TIP_COLOR)
    # The rim is a filled circle under the dot rather than an outline on it, so it holds
    # up at the width a hairline outline loses on a light sheet.
    _canvas.draw_circle(at, radius + PIVOT_RIM_WIDTH, PIVOT_RIM_COLOR)
    _canvas.draw_circle(at, radius, PIVOT_COLOR)


## Image-space points as canvas positions, taken from pixel centres so a corner
## sits in the middle of the pixel it names rather than on its top-left edge.
func _to_screen(points: PackedVector2Array) -> PackedVector2Array:
    var scale := _scale()
    var out := PackedVector2Array()
    for point in points:
        out.append(_content_origin + (point + Vector2(0.5, 0.5)) * scale)
    return out


## Dashed, like the box round an island's reach and for the same reason: it survives
## lying on top of the edge it is describing, where a solid line of the same weight reads
## as part of it.
func _draw_finished(screen: PackedVector2Array, color: Color, selected: bool, enabled: bool) -> void:
    # Shaded only when it is the highlighted row and still doing something, which is what
    # a swept rectangle does. The fill is what says "this area is being taken out", so a
    # region that is switched off must not have one — the shape stays, since it was built
    # corner by corner and is only set aside.
    if selected and enabled and screen.size() >= 3:
        # Triangulated rather than handed straight to draw_colored_polygon, which fans
        # from the first vertex and so fills the wrong area for a concave shape — and
        # concave is the whole point of this tool.
        var indices := Geometry2D.triangulate_polygon(screen)
        var fill := Color(color, MARKER_FILL_ALPHA)
        var triangle := 0
        while triangle + 2 < indices.size():
            _canvas.draw_colored_polygon(PackedVector2Array([
                screen[indices[triangle]],
                screen[indices[triangle + 1]],
                screen[indices[triangle + 2]],
            ]), fill)
            triangle += 3

    # The backing dashed in step with the line over it, so it reads as a shadow rather
    # than as a second dashed shape.
    _draw_dashed_polygon(screen, MARKER_SHADOW_COLOR, MARKER_WIDTH + 2.0)
    _draw_dashed_polygon(screen, color, MARKER_WIDTH + (1.0 if selected else 0.0))
    if selected:
        # Handles only on the highlighted region, since that is the only one whose
        # corners can be grabbed.
        for point in screen:
            _draw_handle(point, color)


## A closed shape, each side dashed from its own start.
##
## Side by side rather than as one dashed polyline, which is what keeps the corners
## closed: every line begins and ends on a dash, so the sides meet instead of leaving a
## gap wherever two runs of dashes happened to land.
func _draw_dashed_polygon(screen: PackedVector2Array, color: Color, width: float) -> void:
    if screen.size() < 2:
        return
    for i in screen.size():
        _canvas.draw_dashed_line(screen[i], screen[(i + 1) % screen.size()],
                color, width, MARKER_DASH)


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


static func _build_checker() -> Texture2D:
    var image := Image.create_empty(CHECKER_SIZE * 2, CHECKER_SIZE * 2, false, Image.FORMAT_RGB8)
    image.fill(CHECKER_DARK)
    image.fill_rect(Rect2i(0, 0, CHECKER_SIZE, CHECKER_SIZE), CHECKER_LIGHT)
    image.fill_rect(Rect2i(CHECKER_SIZE, CHECKER_SIZE, CHECKER_SIZE, CHECKER_SIZE), CHECKER_LIGHT)
    return ImageTexture.create_from_image(image)
