@tool
extends Control

## Two grabbers on one track, for a setting that is a span rather than a single number.
##
## The low grabber cannot pass the high one. Godot has nothing of this kind — everything
## deriving from [Range] carries one value — so it is drawn and driven here.
##
## The span is held as a [Vector2], x low and y high, so the settings form can treat it as
## one property like any other.

## Emitted whenever either grabber moves, by pointer or by key.
signal range_changed(low: float, high: float)

const TRACK_HEIGHT := 4.0
const HANDLE_WIDTH := 8.0
const HANDLE_HEIGHT := 14.0

## Space between the line of text and the track under it.
const TEXT_GAP := 3.0

var label: String = "":
    set(value):
        label = value
        queue_redraw()

var min_value: float = 0.0
var max_value: float = 1.0
var step: float = 0.01

var low: float = 0.0
var high: float = 1.0

## Which grabber the pointer is dragging: -1 for neither, 0 low, 1 high.
var _dragging := -1

## Which grabber the arrow keys move, and which is drawn lit under the pointer.
var _keyed := 0
var _hover := -1


func _init() -> void:
    focus_mode = Control.FOCUS_CLICK
    size_flags_horizontal = Control.SIZE_EXPAND_FILL


## Points the control at a setting. [param at] is the span, x low and y high.
func setup(at: Vector2, lowest: float, highest: float, step_by: float, name_text: String) -> void:
    min_value = lowest
    max_value = highest
    step = step_by
    label = name_text
    set_span(at)
    update_minimum_size()


## The span as it now stands.
func get_span() -> Vector2:
    return Vector2(low, high)


## Moves both grabbers without raising [signal range_changed], for a form being pointed at
## another image's settings. Takes the pair in either order.
func set_span(at: Vector2) -> void:
    low = clampf(minf(at.x, at.y), min_value, max_value)
    high = clampf(maxf(at.x, at.y), min_value, max_value)
    queue_redraw()


func _notification(what: int) -> void:
    if what == NOTIFICATION_THEME_CHANGED:
        update_minimum_size()
        queue_redraw()
    elif what == NOTIFICATION_MOUSE_EXIT:
        if _hover != -1:
            _hover = -1
            queue_redraw()


func _get_minimum_size() -> Vector2:
    return Vector2(60.0, _line_height() + TEXT_GAP + HANDLE_HEIGHT)


func _draw() -> void:
    var font := get_theme_font(&"font", &"Label")
    if font == null:
        return
    var font_size := get_theme_font_size(&"font_size", &"Label")

    var text_color := Color(0.85, 0.85, 0.85)
    if has_theme_color(&"font_color", &"Label"):
        text_color = get_theme_color(&"font_color", &"Label")
    var accent := Color(0.4, 0.7, 1.0)
    if has_theme_color(&"accent_color", &"Editor"):
        accent = get_theme_color(&"accent_color", &"Editor")

    var baseline := font.get_ascent(font_size)
    draw_string(font, Vector2(0.0, baseline), label, HORIZONTAL_ALIGNMENT_LEFT, -1,
            font_size, text_color)
    var reading := "%s to %s" % [_format(low), _format(high)]
    draw_string(font, Vector2(0.0, baseline), reading, HORIZONTAL_ALIGNMENT_RIGHT,
            size.x, font_size, Color(text_color, text_color.a * 0.7))

    var mid := _line_height() + TEXT_GAP + HANDLE_HEIGHT * 0.5
    var top := mid - TRACK_HEIGHT * 0.5
    var left := HANDLE_WIDTH * 0.5
    var reach := _track_width()
    draw_rect(Rect2(left, top, reach, TRACK_HEIGHT), Color(text_color, 0.16))

    var low_x := left + reach * _fraction(low)
    var high_x := left + reach * _fraction(high)
    draw_rect(Rect2(low_x, top, maxf(high_x - low_x, 1.0), TRACK_HEIGHT), accent)
    _draw_handle(low_x, mid, accent, _dragging == 0 or (_dragging < 0 and _hover == 0))
    _draw_handle(high_x, mid, accent, _dragging == 1 or (_dragging < 0 and _hover == 1))


func _draw_handle(at_x: float, mid: float, accent: Color, lit: bool) -> void:
    var box := Rect2(at_x - HANDLE_WIDTH * 0.5, mid - HANDLE_HEIGHT * 0.5,
            HANDLE_WIDTH, HANDLE_HEIGHT)
    draw_rect(box.grow(1.0), Color(0.0, 0.0, 0.0, 0.55))
    draw_rect(box, accent.lightened(0.35) if lit else accent)


func _gui_input(event: InputEvent) -> void:
    var click := event as InputEventMouseButton
    if click != null and click.button_index == MOUSE_BUTTON_LEFT:
        if click.pressed:
            _dragging = _nearest(click.position.x)
            _keyed = _dragging
            grab_focus()
            _move(_dragging, _value_at(click.position.x))
        else:
            _dragging = -1
        queue_redraw()
        accept_event()
        return

    var motion := event as InputEventMouseMotion
    if motion != null:
        if _dragging >= 0:
            _move(_dragging, _value_at(motion.position.x))
            accept_event()
            return
        var over := _nearest(motion.position.x)
        if over != _hover:
            _hover = over
            queue_redraw()
        return

    var key := event as InputEventKey
    if key != null and key.pressed:
        var nudge := 0.0
        if key.keycode == KEY_LEFT:
            nudge = -maxf(step, 0.001)
        elif key.keycode == KEY_RIGHT:
            nudge = maxf(step, 0.001)
        elif key.keycode == KEY_TAB:
            # Swaps which grabber the arrows move, since both sit on one control.
            _keyed = 1 - _keyed
            queue_redraw()
            accept_event()
            return
        if not is_zero_approx(nudge):
            _move(_keyed, (low if _keyed == 0 else high) + nudge)
            accept_event()


## Which grabber a press at [param at_x] should take.
##
## When the two sit on the same spot it goes by which side the pointer is on. Nearest alone
## would always answer the same one, and the pair could never be pulled apart again.
func _nearest(at_x: float) -> int:
    var left := HANDLE_WIDTH * 0.5
    var reach := _track_width()
    var low_x := left + reach * _fraction(low)
    var high_x := left + reach * _fraction(high)
    if absf(low_x - high_x) < 1.0:
        return 0 if at_x < low_x else 1
    return 0 if absf(at_x - low_x) <= absf(at_x - high_x) else 1


func _move(which: int, to: float) -> void:
    var landed := to if step <= 0.0 else snappedf(to, step)
    if which == 0:
        landed = clampf(landed, min_value, high)
        if is_equal_approx(landed, low):
            return
        low = landed
    elif which == 1:
        landed = clampf(landed, low, max_value)
        if is_equal_approx(landed, high):
            return
        high = landed
    else:
        return
    queue_redraw()
    range_changed.emit(low, high)


func _value_at(at_x: float) -> float:
    var along := clampf((at_x - HANDLE_WIDTH * 0.5) / _track_width(), 0.0, 1.0)
    return min_value + (max_value - min_value) * along


func _fraction(value: float) -> float:
    var reach := max_value - min_value
    return 0.0 if is_zero_approx(reach) else clampf((value - min_value) / reach, 0.0, 1.0)


func _track_width() -> float:
    return maxf(size.x - HANDLE_WIDTH, 1.0)


func _line_height() -> float:
    var font := get_theme_font(&"font", &"Label")
    if font == null:
        return 16.0
    return font.get_height(get_theme_font_size(&"font_size", &"Label"))


## How many decimals to show, taken from the step so a coarse setting is not written out
## to a precision it cannot reach.
func _format(value: float) -> String:
    if step >= 1.0:
        return str(roundi(value))
    return String.num(value, 3 if step < 0.01 else 2)
