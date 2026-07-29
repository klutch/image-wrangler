@tool
extends VBoxContainer

## The HSV Adjustment list: rectangles picked off the preview, each with its own three
## sliders.
##
## Built on the same shape as the Island Picker — pick a region, get a row, edit the
## highlighted row underneath. What differs is what a row holds: an island carries one
## tolerance and a mode, where a region here carries three adjustments and no mode, since
## there is nothing to add or subtract.
##
## The [HSVRegionList] it edits is resolved through the operation's settings on every
## access, so swapping in another image's settings needs no re-pointing here.

## Emitted when the pick button is toggled. The dock puts the preview into crosshair mode
## in response, and switches any other picker off.
signal pick_toggled(enabled: bool)

## Emitted whenever the list or any region on it changes, so the dock can re-run the
## preview and save the settings against the current image.
signal regions_changed

## Emitted when a different row is highlighted, so the dock can redraw the overlay.
signal selection_changed

const EntryList := preload("res://addons/image_wrangler/ui/iw_entry_list.gd")

## What the swatch on each row shows. The regions have no colour of their own, so it
## stands for the adjustment: the hue the slider turns to, at full strength.
const SWATCH_SATURATION := 0.7
const SWATCH_VALUE := 0.9

var _operation: IWOperation
var _property: StringName

## Whether this control answers to the pointer. Its own state rather than something set
## on the buttons, because [method _update_buttons] rewrites them on every change and
## would put back whatever it worked out for itself.
var _interactive := true

var _list: EntryList
var _pick_button: Button
var _clear_button: Button

## The three sliders for the highlighted row, hidden rather than disabled when nothing is
## selected — a control that edits nothing should not be on screen.
var _editor: VBoxContainer
var _hue: EditorSpinSlider
var _saturation: EditorSpinSlider
var _value: EditorSpinSlider
var _reset_button: Button

## Set while the sliders are being pointed at another row, so their change signal does not
## write the row that was selected a moment ago.
var _loading_editor := false

var _hint: Label


## Binds this control to [param property] on [param operation].
func setup(operation: IWOperation, property: StringName) -> void:
    _operation = operation
    _property = property
    _build()
    _refresh()


func _build() -> void:
    # Buttons first so they sit flush under the group heading. This control has no title
    # of its own — the settings form already provides one.
    var buttons := HBoxContainer.new()
    add_child(buttons)

    _pick_button = Button.new()
    _pick_button.text = "Pick"
    _pick_button.toggle_mode = true
    _pick_button.tooltip_text = "Drag a rectangle over the preview to add that region to the list.\n\nRegions may overlap. They are applied in the order they were picked,\neach working on what the one before it left."
    _pick_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    _pick_button.toggled.connect(func(pressed: bool) -> void: pick_toggled.emit(pressed))
    buttons.add_child(_pick_button)

    _clear_button = Button.new()
    _clear_button.text = "Clear"
    _clear_button.tooltip_text = "Remove every region for this image."
    _clear_button.pressed.connect(_on_clear_pressed)
    buttons.add_child(_clear_button)

    _list = EntryList.new()
    # No mode dropdown: a region here has nothing to add or subtract, only three
    # adjustments that are all on the sliders below.
    _list.configure(false)
    _list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    _list.row_selected.connect(_on_row_selected)
    _list.enabled_toggled.connect(_on_enabled_toggled)
    _list.remove_requested.connect(_remove_entry)
    add_child(_list)

    _editor = VBoxContainer.new()
    add_child(_editor)

    # Hue in turns rather than degrees, matching what the kernel takes, but stepped
    # finely enough that the slider still lands on a whole degree.
    _hue = _add_slider("Hue", -0.5, 0.5, 1.0 / 360.0,
            "How far round the colour wheel to turn everything in this region.\n\nWraps rather than clamping, so the ends meet — there is no edge of the\nwheel to pile colours up against.")
    _saturation = _add_slider("Saturation", 0.0, 3.0, 0.01,
            "How much more or less colourful, as a multiplier.\n\n1 leaves it alone, 0 drains it to grey. Above 1 deepens what is already\nthere and cannot invent colour in a pixel that has none.")
    _value = _add_slider("Value", 0.0, 3.0, 0.01,
            "How much lighter or darker, as a multiplier.\n\n1 leaves it alone. Above 1 lightens, and anything already at full\nbrightness stays there.")

    _reset_button = Button.new()
    _reset_button.text = "Reset Sliders"
    _reset_button.tooltip_text = "Put this region's three sliders back where they do nothing.\nThe region stays on the list."
    _reset_button.pressed.connect(_on_reset_pressed)
    _editor.add_child(_reset_button)

    _hint = Label.new()
    _hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    _hint.modulate = Color(1, 1, 1, 0.6)
    _hint.visible = false
    add_child(_hint)


func _add_slider(label: String, low: float, high: float, step: float, hint: String) -> EditorSpinSlider:
    var slider := EditorSpinSlider.new()
    slider.label = label
    slider.min_value = low
    slider.max_value = high
    slider.step = step
    slider.tooltip_text = hint
    slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    slider.value_changed.connect(_on_slider_changed)
    _editor.add_child(slider)
    return slider


# --- What the dock asks of every picker ---------------------------------

## Adds the swept rectangle and highlights it, so the sliders are pointed at what was
## just picked. Returns how many pixels it covers, or zero when nothing was added.
func add_region(rect: Rect2i) -> int:
    var regions := _region_list()
    if regions == null:
        return 0
    var region := regions.add(rect)
    if region == null:
        return 0
    _refresh()
    _list.select(regions.size() - 1)
    _on_row_selected(regions.size() - 1)
    regions_changed.emit()
    return rect.size.x * rect.size.y


func set_pick_active(enabled: bool) -> void:
    _pick_button.set_pressed_no_signal(enabled)


func selected_index() -> int:
    return _list.selected_index() if _list != null else -1


## Every region's rectangle, for the dock to outline on the preview.
func get_regions() -> Array[Rect2i]:
    var out: Array[Rect2i] = []
    var regions := _region_list()
    if regions == null:
        return out
    for region in regions.regions:
        out.append(region.rect if region != null else Rect2i())
    return out


## Whether each region is switched on, in the same order, so a switched-off one can be
## drawn differently rather than hidden.
func get_enabled_flags() -> PackedByteArray:
    var out := PackedByteArray()
    var regions := _region_list()
    if regions == null:
        return out
    for region in regions.regions:
        out.append(1 if region != null and region.enabled else 0)
    return out


## Turns every control on or off together, for an entry that has been switched off.
func set_controls_enabled(enabled: bool) -> void:
    _interactive = enabled
    if _list != null:
        _list.set_interactive(enabled)
    _update_buttons()


# --- Internals ----------------------------------------------------------

## The list this control edits, resolved through the operation every time so that
## swapping the settings Resource for another image needs no re-pointing here.
func _region_list() -> HSVRegionList:
    if _operation == null:
        return null
    var settings := _operation.get_settings()
    if settings == null:
        return null
    return settings.get(_property) as HSVRegionList


func _selected_region() -> HSVRegion:
    var regions := _region_list()
    return regions.get_at(selected_index()) if regions != null else null


## Rebuilds the rows and points the sliders at whatever is highlighted.
func _refresh() -> void:
    var regions := _region_list()
    var rows := []
    if regions != null:
        for region in regions.regions:
            if region == null:
                continue
            rows.append({
                "color": _swatch_for(region),
                "text": region.describe(),
                "enabled": region.enabled,
            })
    _list.set_rows(rows)
    _load_editor()
    _update_buttons()
    _set_hint("" if not rows.is_empty()
            else "Press Pick, then drag a rectangle over the preview.")


## What a row's swatch shows: the hue this region turns to, at a readable strength.
##
## The regions have no colour of their own, so the swatch stands for the adjustment —
## which is the one thing about a row worth telling apart at a glance.
func _swatch_for(region: HSVRegion) -> Color:
    if region.is_neutral():
        return Color(0.6, 0.6, 0.6)
    var hue := region.hue - floorf(region.hue)
    return Color.from_hsv(hue, SWATCH_SATURATION, SWATCH_VALUE)


## Points the three sliders at the highlighted region, or hides them.
func _load_editor() -> void:
    var region := _selected_region()
    _editor.visible = region != null
    if region == null:
        return
    _loading_editor = true
    _hue.value = region.hue
    _saturation.value = region.saturation
    _value.value = region.value
    _loading_editor = false


func _update_buttons() -> void:
    var regions := _region_list()
    var any := regions != null and not regions.is_empty()
    _pick_button.disabled = not _interactive
    _clear_button.disabled = not _interactive or not any
    if _reset_button != null:
        _reset_button.disabled = not _interactive


## Shows [param text] under the list, or gives the line back when it is empty.
##
## Hidden rather than blanked: an empty Label still claims a line's height, and this dock
## has no room to spare.
func _set_hint(text: String) -> void:
    _hint.text = text
    _hint.visible = not text.is_empty()


func _on_row_selected(_index: int) -> void:
    _load_editor()
    _update_buttons()
    selection_changed.emit()


func _on_enabled_toggled(index: int, on: bool) -> void:
    var regions := _region_list()
    var region := regions.get_at(index) if regions != null else null
    if region == null:
        return
    region.enabled = on
    _list.update_row(index, {
        "color": _swatch_for(region),
        "text": region.describe(),
        "enabled": on,
    })
    regions_changed.emit()


## Named to avoid the value slider: a parameter called value would shadow it, and the
## three writes below would then be reading a float.
func _on_slider_changed(_moved_to: float) -> void:
    if _loading_editor:
        return
    var region := _selected_region()
    if region == null:
        return
    region.hue = _hue.value
    region.saturation = _saturation.value
    region.value = _value.value
    # One row rather than the whole list, so the label and swatch follow a dragged
    # slider without the rows being rebuilt under the pointer.
    _list.update_row(selected_index(), {
        "color": _swatch_for(region),
        "text": region.describe(),
        "enabled": region.enabled,
    })
    regions_changed.emit()


func _on_reset_pressed() -> void:
    var region := _selected_region()
    if region == null:
        return
    region.hue = 0.0
    region.saturation = 1.0
    region.value = 1.0
    _load_editor()
    _list.update_row(selected_index(), {
        "color": _swatch_for(region),
        "text": region.describe(),
        "enabled": region.enabled,
    })
    regions_changed.emit()



## Takes one row off the list, whether the button asked or a row's own cross did.
func _remove_entry(index: int) -> void:
    var regions := _region_list()
    if regions == null or index < 0 or index >= regions.size():
        return
    regions.remove_at(index)
    _refresh()
    regions_changed.emit()
    selection_changed.emit()


func _on_clear_pressed() -> void:
    var regions := _region_list()
    if regions == null or regions.is_empty():
        return
    regions.clear()
    _refresh()
    regions_changed.emit()
    selection_changed.emit()
