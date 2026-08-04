@tool
extends Control

## The working overlay: a scrim that dims the image, and a panel holding the spinner,
## the caption, the two bars and the start-up log.
##
## The tree lives in scenes/iw_busy_overlay.tscn; this fades it in and out, turns the
## spinner and ratchets the bars. The preview owns where this sits and forwards its
## busy calls here. The spinner is the one part still drawn by hand — it is an
## animation, and arcs stay crisp at any size and pick up the theme's accent.

## Seconds the overlay takes to come up, and to go away again.
##
## Most runs are short, and an overlay that snapped on and off for every one of them
## turned the preview into a flicker. Fading means a run that finishes inside this
## never reaches full strength: it shows as a swell rather than a flash.
const FADE_TIME := 0.5

## Shown while nothing has said which stage is running.
const CAPTION := "Processing…"

## How many lines of a starting server's output are kept, and how wide the block under
## the bars may be.
const LOG_LINES := 8
const LOG_WIDTH := 480.0

## Diameter of the spinner, its stroke as a fraction of that, and how round it is.
const RING_SIZE := 78.0
const RING_THICKNESS := 0.115
const RING_SEGMENTS := 64

## How the spinner turns.
##
## Not at a constant rate: the wobble term takes a tenth of a turn off and puts it
## back once or so a second, which reads as something working at a thing rather than
## as a wheel freewheeling. The numbers are picked so it never quite reverses.
const SPIN_TURNS_PER_SECOND := 0.85
const SPIN_WOBBLE_TURNS := 0.10
const SPIN_WOBBLE_HZ := 1.3
const SPIN_SWEEP := 0.28

## How much dimmer the stage bar's fill is than the main bar's. Two bars of equal
## weight would leave the user working out which is which every time they looked.
const STAGE_FILL_DARKEN := 0.35

## Room the panel and its padding claim around the contents, for the fit below.
const EDGE_ROOM := 60.0

var _busy := false

## How far the overlay has faded up, 0 to 1. Separate from [member _busy] because a
## run can be over while its overlay is still on its way out, and the next run starts
## again from wherever that had got to rather than from nothing.
var _fade := 0.0

## Seconds the current run has been on screen, which is all the spinner needs.
var _spin_time := 0.0

## The two ratchets. See [method set_progress] and [method set_stage_progress].
var _progress := 0.0
var _stage_progress := 0.0
var _stage_label := ""

var _log := PackedStringArray()

var _spinner: Control
var _caption: Label
var _main_bar: ProgressBar
var _stage_bar: ProgressBar
var _log_label: RichTextLabel


func _ready() -> void:
    _bind()
    visible = false
    set_process(false)


func _bind() -> void:
    if _spinner != null:
        return
    _spinner = %Spinner
    _caption = %Caption
    _main_bar = %MainBar
    _stage_bar = %StageBar
    _log_label = %LogLabel
    _spinner.draw.connect(_draw_spinner)
    resized.connect(_fit)
    _apply_theme()


func _notification(what: int) -> void:
    if what == NOTIFICATION_THEME_CHANGED and _main_bar != null:
        _apply_theme()


## Runs while the overlay is on screen at all, which outlasts the run itself by the
## length of the fade. The spinner keeps turning on the way out: one that stops dead
## and then fades is two endings for one event, and the first says the wrong thing.
func _process(delta: float) -> void:
    _spin_time += delta

    var target := 1.0 if _busy else 0.0
    if not is_equal_approx(_fade, target):
        var step := delta / FADE_TIME
        _fade = minf(_fade + step, target) if target > _fade \
                else maxf(_fade - step, target)
    elif not _busy:
        # Faded out and nothing running: nothing left to animate until the next run.
        _fade = 0.0
        visible = false
        set_process(false)
        return

    # Eased rather than taken straight — a linear fade appears to arrive suddenly and
    # then crawl. One write on the root carries the fade into everything in the panel.
    modulate.a = smoothstep(0.0, 1.0, _fade)
    visible = _fade > 0.0
    _spinner.queue_redraw()


# --- What the preview forwards ------------------------------------------

## Puts the overlay into or out of its working state.
##
## Starting a run resets the bars, so a second run cannot appear to begin wherever the
## first one left off. Neither end is immediate: both are a target for the fade to
## travel towards, so a run beginning during the last one's exit turns it round.
func set_busy(active: bool) -> void:
    _bind()
    if active:
        _progress = 0.0
        _stage_progress = 0.0
        _stage_label = ""
        _main_bar.value = 0.0
        _stage_bar.value = 0.0
        _caption.text = CAPTION
        if not _busy:
            # The spinner is not reset with the bars: it says work is happening, and
            # one run giving way to another has not stopped it happening.
            if _fade <= 0.0:
                _spin_time = 0.0
            _busy = true
        set_process(true)
        return

    if not _busy:
        return
    _busy = false
    # Still processing: the overlay is carried out rather than taken away, and the
    # bars keep what they reached so they fade from there instead of emptying first.
    set_process(true)


## How far along the run says it is, 0 to 1. Never goes backwards within a run — a
## report out of order would show as a bar that stutters.
func set_progress(fraction: float) -> void:
    if not _busy:
        return
    _progress = maxf(_progress, clampf(fraction, 0.0, 1.0))
    _main_bar.value = _progress


## How far along the stage named [param label] says it is, 0 to 1.
##
## Ratcheted within a stage, but deliberately not across them: this bar resets every
## time the run moves on, and that reset is most of what it is saying. The label
## changing is what a new stage looks like from here.
func set_stage_progress(fraction: float, label: String) -> void:
    if not _busy:
        return
    if label != _stage_label:
        _stage_label = label
        _stage_progress = 0.0
        # The running stage's name rather than a fixed word, so a slow stack says
        # which part of it is slow instead of only that it is.
        _caption.text = label if not label.is_empty() else CAPTION
    _stage_progress = maxf(_stage_progress, clampf(fraction, 0.0, 1.0))
    _stage_bar.value = _stage_progress


## Adds [param text] to the lines under the bars, keeping the newest few.
func append_log(text: String) -> void:
    _bind()
    for line: String in text.split("\n", false):
        _log.append(line)
    while _log.size() > LOG_LINES:
        _log.remove_at(0)
    _log_label.text = "\n".join(_log)
    _log_label.visible = true
    _fit()


func clear_log() -> void:
    if _log.is_empty():
        return
    _log.clear()
    _bind()
    _log_label.text = ""
    _log_label.visible = false
    _fit()


# --- Internals ----------------------------------------------------------

## The accent colour is the theme's, so the fills are re-dyed whenever it changes.
## The log sits under the caption in every sense, so its type is a step smaller.
func _apply_theme() -> void:
    var fill := _main_bar.get_theme_stylebox(&"fill") as StyleBoxFlat
    if fill != null:
        fill.bg_color = _accent()
    var stage_fill := _stage_bar.get_theme_stylebox(&"fill") as StyleBoxFlat
    if stage_fill != null:
        stage_fill.bg_color = _accent().darkened(STAGE_FILL_DARKEN)
    _log_label.add_theme_font_size_override(&"normal_font_size",
            maxi(get_theme_default_font_size() - 3, 9))


## Asked for rather than assumed: outside the editor there is no Editor theme type.
func _accent() -> Color:
    if has_theme_color(&"accent_color", &"Editor"):
        return get_theme_color(&"accent_color", &"Editor")
    return Color(0.4, 0.6, 1.0)


## Keeps the panel inside a small view: the spinner gives before the caption or the
## bars do, and then shrinks square so it turns round rather than wobbling on an oval.
## The log block is a fixed width so short and long lines make the same panel.
func _fit() -> void:
    if _spinner == null:
        return
    var room := Vector2(maxf(size.x - EDGE_ROOM, 0.0), maxf(size.y - EDGE_ROOM, 0.0))
    _log_label.custom_minimum_size.x = minf(LOG_WIDTH, room.x) if _log_label.visible else 0.0
    # What the caption, the bars, the log and the gaps between them take of the height.
    var taken := _caption.get_combined_minimum_size().y + 42.0
    if _log_label.visible:
        taken += _log_label.get_combined_minimum_size().y + 10.0
    var ring := clampf(minf(room.x, room.y - taken), 0.0, RING_SIZE)
    _spinner.custom_minimum_size = Vector2(ring, ring)


## The spinner: a faint full ring under a bright arc running round it. The ring is
## what keeps the arc from reading as a stray mark at the moments the wobble has it
## nearly stopped. The bar says how far along the work is; this says it is still
## happening — a bar that has not moved for four seconds looks exactly like a hang.
func _draw_spinner() -> void:
    var radius := minf(_spinner.size.x, _spinner.size.y) * 0.5
    if radius <= 0.0:
        return
    # Kept off the outer edge, since a stroke straddles the radius it is drawn at.
    var thickness := maxf(radius * 2.0 * RING_THICKNESS, 1.0)
    radius -= thickness * 0.5

    var turns := _spin_time * SPIN_TURNS_PER_SECOND \
            + SPIN_WOBBLE_TURNS * sin(TAU * SPIN_WOBBLE_HZ * _spin_time)
    var angle := TAU * turns
    var center := _spinner.size * 0.5
    _spinner.draw_arc(center, radius, 0.0, TAU, RING_SEGMENTS,
            Color(1, 1, 1, 0.18), thickness, true)
    _spinner.draw_arc(center, radius, angle, angle + TAU * SPIN_SWEEP, RING_SEGMENTS,
            _accent(), thickness, true)
