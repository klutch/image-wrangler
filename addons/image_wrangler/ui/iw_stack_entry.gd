@tool
extends PanelContainer

## One operation's row in the stack: a header to grab, tick and close, and the
## operation's own settings form underneath.
##
## The header replaces what used to be a folding group heading inside one long form.
## That is why an operation's schema no longer names a group for its own settings —
## the entry [i]is[/i] the group now, and a heading inside it would be a heading
## inside a heading.
##
## [b]Dragging starts anywhere in the header.[/b] The whole entry implements the drag, so
## the preview and the drop indicator cover all of it and the gesture works across the
## scroll container. But an entry full of sliders and list rows would be impossible to
## use if a drag could start anywhere in it, so [method _get_drag_data] refuses unless
## the press began inside the header. The tick, the title and the close button take their
## own mouse events, so each forwards a drag back here; a press that does not move still
## does what the control it landed on says it does.

## Emitted when the close button is pressed.
signal remove_requested(entry: Control)

## Emitted when the tick changes. The stack is what reads it; the entry only reports.
signal enabled_toggled(entry: Control, enabled: bool)

## Emitted when a drop lands on this entry: move [param from_uid] to just above or
## just below this one.
signal reorder_requested(from_uid: int, to_uid: int, above: bool)

## Emitted when anything in the settings form changes.
signal setting_changed(entry: Control)

## Emitted when the entry is folded or unfolded.
##
## Its own signal rather than [signal setting_changed], because a fold changes no pixels:
## it is worth saving, and it must not enter the undo history or start another run.
signal fold_changed(entry: Control)

## Emitted on a right-click over this entry. [param above] is which half was clicked, the
## same rule a drop uses, so a paste lands where the pointer said rather than at the end.
signal menu_requested(entry: Control, above: bool)

## What a reorder's drag payload calls itself, so the editor's other drags are told apart
## from this one.
const DRAG_TYPE := "iw_stack_entry"

## Indent of the settings form under its header, matching what a folded group used.
const INDENT := 8

## Thickness of the line drawn where a dragged entry would land.
const DROP_LINE := 2.0

## Width of the grab handle. Wide enough to be aimed at without crowding the title,
## which is the only other thing competing for the left of the header.
const HANDLE_WIDTH := 22

## How much lighter than the panel behind it an entry sits, and how round its
## corners are.
##
## Lifted rather than outlined, because the stack is a column of things that can be
## picked up and moved — and a raised card says that where a border only says the
## contents are related. Slight on purpose: six of these down a narrow dock at any
## more contrast would read as six separate panels rather than one list.
const PANEL_LIGHTEN := 0.06
const PANEL_RADIUS := 5
const PANEL_PADDING := 4

## The border drawn round the entry the stack is pointed at, and how thick it is.
##
## Yellow because nothing else in the dock is: every card already wears its operation's own
## colour, so the mark saying which one is current has to be a colour none of them can be.
const SELECTED_BORDER_COLOR := Color(1.0, 0.85, 0.15)
const SELECTED_BORDER_WIDTH := 2

## How far the card is carried towards its operation's own colour.
##
## Half way, so the tie between a card and the marks it owns is obvious at a glance without
## the column turning into ten flat blocks of colour. The marks themselves are drawn in the
## colour undiluted, which is what keeps them readable over the art.
const PANEL_TINT_MIX := 0.15

## The item this entry stands for. Its settings are the live ones.
var stage: IWStackItem

## Identity for this entry, unique for the session.
##
## Needed because the same operation may appear more than once, so neither the
## operation id nor the position in the stack identifies a row: the id is shared and
## the position is exactly what a reorder changes.
var uid := 0

## Which stack view this card belongs to, as that view's instance id.
##
## Written by the view before [method setup]. The dock holds two stacks and both hand out
## the same kind of payload, so without this a card could be dragged from one into the other
## — and every view would answer every card's drag by scrolling itself.
var stack_id := 0

var _handle: Label
var _header: HBoxContainer
var _tick: CheckBox
var _title: Button
var _note: Label
var _body: MarginContainer
var _settings_box: VBoxContainer

## Where a drop would land, while one is hovering: 1 above, -1 below, 0 not hovering.
var _drop_side := 0

## Set while the card's own colour is being assigned, so the theme change that
## assignment raises does not come straight back in.
var _styling := false

## Whether the stack is pointed at this entry.
var _selected := false


func setup(operation: IWStackItem, entry_uid: int, folded: bool) -> void:
    stage = operation
    uid = entry_uid
    _build()
    _title.button_pressed = not folded
    _body.visible = not folded
    _tick.button_pressed = operation.enabled
    _apply_fold_arrow()


## The form's container, for the settings builder to fill.
func settings_box() -> VBoxContainer:
    return _settings_box


## Shows or clears the line about what this stage is waiting for.
func set_note(text: String) -> void:
    _note.text = text
    _note.visible = not text.is_empty()


func is_folded() -> bool:
    return not _title.button_pressed


## Every picker or drawing control this entry's form built, at any depth.
##
## A grouped setting is nested inside its heading box rather than sitting directly in
## the form, so scanning only the form's own children would find nothing and every
## picker feature would go quietly dead.
func pick_controls() -> Array[Control]:
    var found: Array[Control] = []
    _collect(_settings_box, found)
    return found


func _collect(node: Node, into: Array[Control]) -> void:
    for child in node.get_children():
        if child.has_method("set_pick_active"):
            into.append(child)
        _collect(child, into)


## Paints the entry as a card standing slightly off the panel behind it.
##
## Asked for rather than assumed: reading a theme colour that is not there logs an
## error, and outside the editor there is no Editor theme type at all.
##
## Guarded against itself. Assigning the override is a theme change, and this is what
## answers a theme change — so without the flag it calls itself until the stack runs
## out. The editor happens to survive it; anything building an entry outside one does
## not.
func _apply_panel_style() -> void:
    if _styling:
        return
    _styling = true

    var base := Color(0.19, 0.20, 0.23)
    if has_theme_color(&"base_color", &"Editor"):
        base = get_theme_color(&"base_color", &"Editor")

    var lifted := base.lightened(PANEL_LIGHTEN)
    if stage != null:
        lifted = lifted.lerp(stage.get_tint(), PANEL_TINT_MIX)

    var box := StyleBoxFlat.new()
    box.bg_color = lifted
    box.set_corner_radius_all(PANEL_RADIUS)
    box.set_content_margin_all(PANEL_PADDING)
    if _selected:
        box.set_border_width_all(SELECTED_BORDER_WIDTH)
        box.border_color = SELECTED_BORDER_COLOR
    add_theme_stylebox_override(&"panel", box)

    _styling = false


## Whether the stack is pointed at this entry, which is what the border says.
func set_selected(value: bool) -> void:
    if _selected == value:
        return
    _selected = value
    _apply_panel_style()


func is_selected() -> bool:
    return _selected


func _build() -> void:
    _apply_panel_style()

    var column := VBoxContainer.new()
    column.add_theme_constant_override("separation", 0)
    add_child(column)

    _header = HBoxContainer.new()
    var header := _header
    column.add_child(header)

    # Passes the mouse through rather than taking it, so the press reaches the entry
    # and _get_drag_data can see where it started.
    _handle = Label.new()
    _handle.text = "≡"
    _handle.mouse_filter = Control.MOUSE_FILTER_PASS
    _handle.mouse_default_cursor_shape = Control.CURSOR_MOVE
    _handle.custom_minimum_size = Vector2(HANDLE_WIDTH, 0)
    _handle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    _handle.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    _handle.modulate = Color(1, 1, 1, 0.55)
    _handle.tooltip_text = "Drag to reorder. Order matters: each operation works on what the ones above it left."
    header.add_child(_handle)

    _tick = CheckBox.new()
    _tick.focus_mode = Control.FOCUS_NONE
    _tick.tooltip_text = "Run this operation.\nUnticking it keeps everything dialled into it, which removing the entry would not."
    _tick.toggled.connect(func(pressed: bool) -> void:
        stage.enabled = pressed
        refresh_enabled_state()
        enabled_toggled.emit(self, pressed))
    header.add_child(_tick)

    # A flat toggle rather than a Label: it reads as a heading, but the whole width of
    # it is the hit target, which a disclosure arrow on its own is not.
    _title = Button.new()
    _title.text = stage.get_operation_name()
    _title.toggle_mode = true
    _title.flat = true
    _title.alignment = HORIZONTAL_ALIGNMENT_LEFT
    _title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    # Never focused: the form is tabbed through to reach the controls, and a heading
    # in that path is a stop nobody wants.
    _title.focus_mode = Control.FOCUS_NONE
    _title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
    # What the item does goes on the title, because the title is the only part of a folded
    # card left to hover. Nothing has one where the name says the whole of it.
    var about := stage.get_description()
    _title.tooltip_text = "Show or hide these settings." if about.is_empty() \
            else "%s\n\nClick to show or hide these settings." % about
    # Written straight onto the operation, which is where the sidecar picks it up.
    _title.toggled.connect(func(pressed: bool) -> void:
        _body.visible = pressed
        if stage != null:
            stage.folded = not pressed
        _apply_fold_arrow()
        fold_changed.emit(self))
    _title.theme_changed.connect(_apply_fold_arrow)
    _title.gui_input.connect(_on_title_input)
    header.add_child(_title)

    # Text rather than the editor's Remove icon: that one is colour-coded by the theme
    # and would arrive tinted.
    #
    # Grey rather than red, and brighter on hover. Six red crosses down a column read
    # as six warnings; the button only becomes the loudest thing on the entry at the
    # moment the pointer is on it, which is the moment it matters.
    var close := Button.new()
    close.flat = true
    close.focus_mode = Control.FOCUS_NONE
    close.text = "✕"
    close.add_theme_color_override(&"font_color", Color(0.62, 0.62, 0.62))
    close.add_theme_color_override(&"font_hover_color", Color(0.92, 0.92, 0.92))
    close.add_theme_color_override(&"font_pressed_color", Color(1.0, 1.0, 1.0))
    close.tooltip_text = "Remove this operation from the stack.\nIts settings go with it."
    close.pressed.connect(func() -> void: remove_requested.emit(self))
    header.add_child(close)

    # The three controls in the header take their own mouse events, so a press on one
    # never reaches this entry's _get_drag_data. Each hands the drag back here instead.
    # A press that does not move still ticks, folds or closes: Godot drops a button's
    # press when a drag begins, so the two cannot both happen.
    for grabbable: Control in [_tick, _title, close]:
        grabbable.set_drag_forwarding(
                func(_at: Vector2) -> Variant: return _begin_drag(),
                Callable(), Callable())

    _note = Label.new()
    _note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    _note.modulate = Color(1.0, 0.85, 0.4)
    _note.visible = false
    _note.add_theme_font_size_override("font_size", 10)
    column.add_child(_note)

    _body = MarginContainer.new()
    _body.add_theme_constant_override("margin_left", INDENT)
    column.add_child(_body)

    _settings_box = VBoxContainer.new()
    _settings_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    _body.add_child(_settings_box)


## Fades a switched-off entry and takes its settings out of use, so the stack reads at
## a glance and nothing can be dialled into an operation that is not running.
##
## The header is deliberately left alone. The tick, the title and the close button
## have to keep working, or an entry could be switched off and never switched back on.
##
## Guarded because the theme fires at the header while the body is still being built:
## adding the title to the tree raises [code]theme_changed[/code], and the arrow that
## hangs off it comes through here.
func refresh_enabled_state() -> void:
    if _title == null or _body == null:
        return
    var live := stage.enabled
    var shade := Color(1, 1, 1, 1.0 if live else 0.5)
    _title.modulate = shade
    _body.modulate = shade

    if _settings_box == null:
        return
    _set_form_enabled(_settings_box, live)


## Turns every input in [param node] on or off.
##
## By property rather than by type, because the form is built from a schema and holds
## whatever the operations asked for. The three names cover the plain ones: buttons
## and their kin take [code]disabled[/code], text fields take [code]editable[/code],
## and [code]EditorSpinSlider[/code] takes [code]read_only[/code].
##
## [b]A control that knows how to switch itself off is asked to, and not recursed
## into.[/b] The list controls rewrite their own buttons whenever the selection
## changes and rebuild their rows on every edit, so anything set on their insides from
## here would be overwritten the moment the user touched them — which is exactly how a
## disabled entry ended up with a live dropdown and a working Remove.
static func _set_form_enabled(node: Node, enabled: bool) -> void:
    for child in node.get_children():
        if child.has_method("set_controls_enabled"):
            child.call("set_controls_enabled", enabled)
            continue
        if "disabled" in child:
            child.disabled = not enabled
        elif "editable" in child:
            child.editable = enabled
        elif "read_only" in child:
            child.read_only = not enabled
        _set_form_enabled(child, enabled)


## Guarded rather than assumed: outside the editor there is no [code]EditorIcons[/code]
## theme to take an arrow from, and a heading with no arrow is better than an error.
func _apply_fold_arrow() -> void:
    if _title == null:
        return
    var open := _title.button_pressed
    var name := &"GuiTreeArrowDown" if open else &"GuiTreeArrowRight"
    if has_theme_icon(name, &"EditorIcons"):
        _title.icon = get_theme_icon(name, &"EditorIcons")
    refresh_enabled_state()


# --- The right-click menu -----------------------------------------------

## Right-clicks anywhere on the card itself: the padding, the gaps, the note.
func _gui_input(event: InputEvent) -> void:
    _offer_menu(event, self)


## Right-clicks on the title, which is a [Button] and would otherwise swallow them.
##
## The header is where anyone would aim, so leaving it out would make the menu feel
## broken. The form below is deliberately not forwarded — a right-click on a slider
## belongs to the slider.
func _on_title_input(event: InputEvent) -> void:
    _offer_menu(event, _title)


func _offer_menu(event: InputEvent, over: Control) -> void:
    var button := event as InputEventMouseButton
    if button == null or not button.pressed or button.button_index != MOUSE_BUTTON_RIGHT:
        return
    accept_event()
    # Measured against the whole card rather than whatever was clicked, so the top and
    # bottom halves mean the same thing wherever the pointer landed.
    var at := over.global_position.y + button.position.y - global_position.y
    menu_requested.emit(self, at < size.y * 0.5)


# --- Reordering ---------------------------------------------------------

func _get_drag_data(at_position: Vector2) -> Variant:
    # Only from the header. Without this, dragging any spin slider or list row inside
    # the entry would start a reorder instead of doing what it looks like it does.
    #
    # Measured against where the press began, which is what at_position is — not where
    # the pointer has since got to. A drag is not offered until the pointer has moved
    # about ten pixels, and asking the live position turns down most real drags started
    # near an edge.
    #
    # This catches the handle and the gaps around the controls. The controls themselves
    # forward to _begin_drag, since they take their own mouse events.
    if _header == null:
        return null
    if not _header.get_global_rect().has_point(get_global_transform() * at_position):
        return null
    return _begin_drag()


## Starts a reorder: hangs a label off the pointer and says which entry is moving.
func _begin_drag() -> Variant:
    var preview := Label.new()
    preview.text = stage.get_operation_name()
    preview.add_theme_constant_override("outline_size", 2)
    set_drag_preview(preview)
    return {"type": DRAG_TYPE, "uid": uid, "stack": stack_id}


func _can_drop_data(at_position: Vector2, data: Variant) -> bool:
    if not (data is Dictionary):
        return false
    var payload: Dictionary = data
    if String(payload.get("type", "")) != DRAG_TYPE:
        return false
    # A card from the other stack is not a reorder of this one, and the operations and the
    # normal map generators are not interchangeable anyway.
    if int(payload.get("stack", 0)) != stack_id:
        return false
    if int(payload.get("uid", -1)) == uid:
        return false
    var side := 1 if at_position.y < size.y * 0.5 else -1
    if side != _drop_side:
        _drop_side = side
        queue_redraw()
    return true


func _drop_data(at_position: Vector2, data: Variant) -> void:
    _drop_side = 0
    queue_redraw()
    var payload: Dictionary = data
    reorder_requested.emit(int(payload.get("uid", -1)), uid, at_position.y < size.y * 0.5)


func _notification(what: int) -> void:
    # The card is mixed from a theme colour, so it has to be mixed again when the
    # theme changes or a light editor would keep a dark entry.
    if what == NOTIFICATION_THEME_CHANGED and _title != null:
        _apply_panel_style()
        return
    # The indicator has to come down when the drag leaves or ends anywhere, not only
    # when it is dropped here — _can_drop_data stops being called and nothing else
    # would clear it.
    if what == NOTIFICATION_DRAG_END or what == NOTIFICATION_MOUSE_EXIT:
        if _drop_side != 0:
            _drop_side = 0
            queue_redraw()


func _draw() -> void:
    if _drop_side == 0:
        return
    var accent := Color(0.4, 0.7, 1.0)
    if has_theme_color(&"accent_color", &"Editor"):
        accent = get_theme_color(&"accent_color", &"Editor")
    var y := 0.0 if _drop_side > 0 else size.y - DROP_LINE
    draw_rect(Rect2(0, y, size.x, DROP_LINE), accent)
