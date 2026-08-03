@tool
extends RefCounted

## Builds a settings form for an [IWOperation] from its declarative schema.
##
## Keeping this generic is what lets a new operation ship without any UI work:
## the operation lists its properties, this fills a container with controls wired
## straight back to them.

const IslandPicker := preload("res://addons/image_wrangler/ui/iw_island_picker.gd")
const ColorList := preload("res://addons/image_wrangler/ui/iw_color_list.gd")
const PolygonList := preload("res://addons/image_wrangler/ui/iw_polygon_list.gd")
const HSVList := preload("res://addons/image_wrangler/ui/iw_hsv_list.gd")
const BrushList := preload("res://addons/image_wrangler/ui/iw_brush_list.gd")
const ExcludeTilesList := preload("res://addons/image_wrangler/ui/iw_exclude_tiles.gd")
const ModelFolder := preload("res://addons/image_wrangler/ui/iw_model_folder.gd")

## Left indent applied to the contents of a named group.
const GROUP_INDENT := 8

## Caption width for the controls that need a label of their own.
const LABEL_WIDTH := 92

## Marks a control with the setting it edits, so [method refresh_values] can find
## it again without the builder having to keep a registry.
const META_PROPERTY := &"iw_property"

## Marks a control with the bool property that hides it, for the same reason and
## in the same way.
const META_HIDDEN_WHEN := &"iw_hidden_when"

## Marks a control with the property it is shown against, and the values of that
## property that keep it on screen.
##
## The other way round from [constant META_HIDDEN_WHEN], and it takes any property
## rather than a bool, so one dropdown can decide which of several settings apply.
const META_SHOWN_WHEN := &"iw_shown_when"
const META_SHOWN_VALUES := &"iw_shown_values"

## Where a readout keeps the name of the settings method that produces its line.
const META_TEXT_FROM := &"iw_text_from"


## Replaces the contents of [param container] with controls for every setting
## [param operation] declares. [param on_changed] is called after each edit.
##
## [param fold_state] carries which groups are folded, keyed by operation and
## group name. Read here for the initial state and written to as headings are
## clicked, so the caller holding it decides how long a fold survives — the dock
## keeps one for the session, so switching operations and coming back finds the
## form as it was left.
## [param key_prefix] scopes the fold keys to one form. The dock passes a stack
## entry's uid, because the same operation may appear in the stack twice and folding
## one of them must not fold the other — which keying by operation id would do.
static func build(operation: IWOperation, container: Container, on_changed: Callable, fold_state: Dictionary, key_prefix: String = "") -> void:
    for child in container.get_children():
        container.remove_child(child)
        child.queue_free()

    # Consecutive entries sharing a group name go under one heading. Tracking the
    # previous name is enough because the schema is already in display order.
    var open_group := ""
    var target := container

    for setting in operation.get_settings_schema():
        var property: StringName = setting.get("property", &"")
        # A folder fixed in code is the one entry with no setting behind it: what it shows
        # is a path in code and all it does is fetch. Everything else must name a property.
        if property == &"" and String(setting.get("folder", "")).is_empty():
            push_warning("Image Wrangler: setting schema entry is missing a property name.")
            continue

        var group: String = setting.get("group", "")
        if group != open_group:
            open_group = group
            # Keyed by the caller's scope as well as the group name, so two forms
            # that happen to name a group the same thing do not fold each other.
            var scope := key_prefix if not key_prefix.is_empty() else String(operation.get_operation_id())
            var key := "%s/%s" % [scope, group]
            # What the user last left it at, falling back to what the schema asks
            # for. The schema key is read off the entry that opens the group, since
            # that is the only one the heading exists for.
            var collapsed: bool = fold_state.get(key, bool(setting.get("collapsed", false)))
            target = _begin_group(container, group, collapsed, fold_state, key)

        var label: String = setting.get("label", String(property).capitalize())
        var tooltip: String = setting.get("tooltip", "")
        var type: int = setting.get("type", IWOperation.SettingType.FLOAT)
        var control: Control

        match type:
            IWOperation.SettingType.BOOL:
                control = _build_bool(operation, property, label, on_changed)
            IWOperation.SettingType.INT:
                control = _build_number(operation, property, label, setting, true, on_changed)
            IWOperation.SettingType.STRING:
                control = _build_string(operation, property, label, on_changed)
            IWOperation.SettingType.ENUM:
                control = _build_enum(operation, property, label, setting, on_changed)
            IWOperation.SettingType.COLOR:
                control = _build_color(operation, property, label, on_changed)
            IWOperation.SettingType.ISLAND_PICKER:
                control = _build_island_picker(operation, property)
            IWOperation.SettingType.COLOR_LIST:
                control = _build_color_list(operation, property)
            IWOperation.SettingType.POLYGON_LIST:
                control = _build_polygon_list(operation, property)
            IWOperation.SettingType.HSV_LIST:
                control = _build_hsv_list(operation, property)
            IWOperation.SettingType.BRUSH_LIST:
                control = _build_brush_list(operation, property)
            IWOperation.SettingType.READOUT:
                control = _build_readout(operation, label, setting)
            IWOperation.SettingType.EXCLUDE_TILES:
                control = _build_exclude_tiles(operation, property)
            IWOperation.SettingType.MODEL_FOLDER:
                control = _build_model_folder(operation, property, setting)
            _:
                control = _build_number(operation, property, label, setting, false, on_changed)

        if not control.has_meta(META_PROPERTY):
            control.set_meta(META_PROPERTY, property)
        # On the outermost control the entry produced, so hiding it takes the whole
        # row — a label with nothing beside it would be worse than showing both.
        var hidden_when: StringName = setting.get("hidden_when", &"")
        if hidden_when != &"":
            control.set_meta(META_HIDDEN_WHEN, hidden_when)
        var shown_when: StringName = setting.get("shown_when", &"")
        if shown_when != &"":
            control.set_meta(META_SHOWN_WHEN, shown_when)
            control.set_meta(META_SHOWN_VALUES, setting.get("shown_values", []))
        control.tooltip_text = tooltip
        target.add_child(control)

    refresh_visibility(operation, container)


## Opens a heading in [param container] and returns the box its members go into,
## or [param container] itself for the unnamed top-level group.
##
## The heading folds its group away. An operation with several list controls would
## otherwise be taller than the dock, and scrolling past three collapsed things to
## reach the one being used is the worst of both. [param collapsed] is the state
## it starts in; the schema entry that opens the group decides.
##
## [param collapsed] is the state it opens in, and every click writes the new one
## back to [param fold_state] under [param key], so the fold outlives the form.
static func _begin_group(container: Container, title: String, collapsed: bool, fold_state: Dictionary, key: String) -> Container:
    if title.is_empty():
        return container

    if container.get_child_count() > 0:
        container.add_child(HSeparator.new())

    # Heading and body share a box with no separation of its own, so the first
    # control sits directly under its heading rather than floating away from it.
    # Groups are still spaced apart by the outer container.
    var group := VBoxContainer.new()
    group.add_theme_constant_override("separation", 0)
    container.add_child(group)

    var indent := MarginContainer.new()
    indent.add_theme_constant_override("margin_left", GROUP_INDENT)

    # A flat toggle rather than a Label: it reads as a heading, but the whole
    # width of it is the hit target, which a disclosure arrow on its own is not.
    var heading := Button.new()
    heading.text = title
    heading.toggle_mode = true
    heading.button_pressed = not collapsed
    heading.flat = true
    heading.alignment = HORIZONTAL_ALIGNMENT_LEFT
    # Never focused: the settings form is tabbed through to reach the controls,
    # and a heading in that path is a stop nobody wants.
    heading.focus_mode = Control.FOCUS_NONE
    heading.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
    heading.tooltip_text = "Show or hide %s." % title
    group.add_child(heading)

    group.add_child(indent)
    indent.visible = not collapsed

    heading.toggled.connect(
        func(pressed: bool) -> void:
            indent.visible = pressed
            # A Dictionary is a reference, so this writes straight into the store
            # the caller handed in and outlives the form being rebuilt.
            fold_state[key] = not pressed
            _apply_fold_arrow(heading)
    )
    # Re-resolved on a theme switch, since the arrow comes out of the theme and
    # the icon already handed over would be the old theme's.
    heading.theme_changed.connect(_apply_fold_arrow.bind(heading))
    _apply_fold_arrow(heading)

    var body := VBoxContainer.new()
    body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    indent.add_child(body)
    return body


## Points the heading's disclosure arrow at its current fold state.
##
## Guarded rather than assumed: outside the editor there is no [code]EditorIcons[/code]
## theme type, and a heading with no arrow is still perfectly usable.
static func _apply_fold_arrow(heading: Button) -> void:
    var icon_name := &"GuiTreeArrowDown" if heading.button_pressed else &"GuiTreeArrowRight"
    if heading.has_theme_icon(icon_name, &"EditorIcons"):
        heading.icon = heading.get_theme_icon(icon_name, &"EditorIcons")


## Island pickers are deliberately not wired to [param on_changed] here. Picking
## needs the preview, which only the dock can reach, so it connects the picker's
## signals itself and re-runs the operation from there.
static func _build_island_picker(operation: IWOperation, property: StringName) -> Control:
    var picker := IslandPicker.new()
    picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    picker.setup(operation, property)
    return picker


## Colour lists are left unwired here for the same reason island pickers are:
## their Pick button needs the preview, and only the dock can reach it. The dock
## connects the signals and re-runs the operation from there.
static func _build_color_list(operation: IWOperation, property: StringName) -> Control:
    var list := ColorList.new()
    list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    list.setup(operation, property)
    return list


## Polygon lists are left unwired here for the same reason the other two are:
## drawing needs the preview, and only the dock can reach it.
static func _build_polygon_list(operation: IWOperation, property: StringName) -> Control:
    var list := PolygonList.new()
    list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    list.setup(operation, property)
    return list


## Left unwired here for the same reason the other three are: picking needs the
## preview, and only the dock can reach it.
static func _build_hsv_list(operation: IWOperation, property: StringName) -> Control:
    var list := HSVList.new()
    list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    list.setup(operation, property)
    return list


## Left unwired here for the same reason the other four are: painting needs the
## preview, and only the dock can reach it.
static func _build_brush_list(operation: IWOperation, property: StringName) -> Control:
    var list := BrushList.new()
    list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    list.setup(operation, property)
    return list


## Left unwired here for the same reason the other five are: picking needs the
## preview, and only the dock can reach it.
static func _build_exclude_tiles(operation: IWOperation, property: StringName) -> Control:
    var list := ExcludeTilesList.new()
    list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    list.setup(operation, property)
    return list


## The folder a neural model lives in, with what is wrong with it and a way to fill it.
##
## Left unwired like the pick controls, and for the same reason: the download reports to the
## preview's overlay, and only the dock can reach that. See
## [code]IWModelFolder.bind_download[/code].
static func _build_model_folder(operation: IWOperation, property: StringName,
        setting: Dictionary) -> Control:
    var field := ModelFolder.new()
    field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    # The whole entry goes along either way: the control reads its label and where its model
    # can be fetched from off the schema, so a second operation with a different model needs
    # no edit here.
    var fixed := String(setting.get("folder", ""))
    if fixed.is_empty():
        field.setup(operation, property, String(setting.get("default", "")), setting)
    else:
        field.setup_fixed(fixed, setting)
    return field


## A line the settings work out, shown rather than edited.
##
## The text comes from a method on the settings named by the schema, and is asked again
## whenever anything in the form changes, so it keeps up with the control it describes.
static func _build_readout(operation: IWOperation, label: String, setting: Dictionary) -> Control:
    var value := Label.new()
    value.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
    # Dimmer than a real control, because it is an answer rather than a thing to reach for.
    value.modulate = Color(1, 1, 1, 0.7)
    value.set_meta(META_TEXT_FROM, StringName(setting.get("text_from", &"")))
    _read_into(operation.get_settings(), value)
    return _labelled_row(label, value)


## Asks one readout's method for its line again.
static func _read_into(settings: Resource, value: Label) -> void:
    if settings == null:
        return
    var method: StringName = value.get_meta(META_TEXT_FROM, &"")
    if method == &"" or not settings.has_method(method):
        value.text = ""
        return
    value.text = String(settings.call(method))


## A labelled row. The numeric controls carry their own label, but a LineEdit or
## an OptionButton does not, so these get one alongside.
static func _labelled_row(label: String, editor: Control) -> Control:
    var row := HBoxContainer.new()
    var caption := Label.new()
    caption.text = label
    caption.custom_minimum_size = Vector2(LABEL_WIDTH, 0)
    # Ellipsised for the same reason every other label here is: the settings form
    # cannot scroll sideways, so a long label would set a floor under the column.
    caption.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
    row.add_child(caption)
    editor.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    row.add_child(editor)
    return row


static func _build_string(operation: IWOperation, property: StringName, label: String, on_changed: Callable) -> Control:
    var field := LineEdit.new()
    field.text = String(operation.get_settings().get(property))
    field.set_meta(META_PROPERTY, property)
    field.text_changed.connect(
        func(value: String) -> void:
            var settings := operation.get_settings()
            if settings == null:
                return
            settings.set(property, value)
            on_changed.call()
    )
    return _labelled_row(label, field)


static func _build_enum(operation: IWOperation, property: StringName, label: String, setting: Dictionary, on_changed: Callable) -> Control:
    var choice := OptionButton.new()
    var options: Array = setting.get("options", [])
    for option in options:
        choice.add_item(String(option))
    var current := int(operation.get_settings().get(property))
    if current >= 0 and current < choice.item_count:
        choice.select(current)
    choice.set_meta(META_PROPERTY, property)
    choice.item_selected.connect(
        func(index: int) -> void:
            var settings := operation.get_settings()
            if settings == null:
                return
            settings.set(property, index)
            on_changed.call()
    )
    return _labelled_row(label, choice)


## A colour swatch, alpha included.
##
## [ColorPickerButton] has no no-signal setter, so [method refresh_values] writing
## to it fires this handler for a change nobody made. That is why the dock keeps a
## refreshing flag — [code]on_changed[/code] resolves to a handler that early-
## returns on it, and this control is the reason that flag exists at all.
static func _build_color(operation: IWOperation, property: StringName, label: String, on_changed: Callable) -> Control:
    var swatch := ColorPickerButton.new()
    swatch.edit_alpha = true
    swatch.custom_minimum_size = Vector2(0, 24)
    swatch.color = operation.get_settings().get(property)
    swatch.set_meta(META_PROPERTY, property)
    swatch.color_changed.connect(
        func(value: Color) -> void:
            var settings := operation.get_settings()
            if settings == null:
                return
            settings.set(property, value)
            on_changed.call()
    )
    return _labelled_row(label, swatch)


static func _build_bool(operation: IWOperation, property: StringName, label: String, on_changed: Callable) -> Control:
    var check := CheckBox.new()
    check.text = label
    check.button_pressed = operation.get_settings().get(property)
    # The lambda captures the operation, which is stable, and dereferences its
    # settings when it fires. Capturing the settings Resource instead would bind
    # the control to whichever image was selected when the form was built.
    check.toggled.connect(
        func(pressed: bool) -> void:
            var settings := operation.get_settings()
            if settings == null:
                return
            settings.set(property, pressed)
            on_changed.call()
    )
    return check


static func _build_number(operation: IWOperation, property: StringName, label: String, setting: Dictionary, is_int: bool, on_changed: Callable) -> Control:
    var slider := EditorSpinSlider.new()
    slider.label = label
    slider.min_value = setting.get("min", 0.0)
    slider.max_value = setting.get("max", 1.0)
    slider.step = setting.get("step", 1.0 if is_int else 0.01)
    slider.rounded = is_int
    slider.value = operation.get_settings().get(property)
    slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    slider.value_changed.connect(
        func(value: float) -> void:
            var settings := operation.get_settings()
            if settings == null:
                return
            settings.set(property, int(value) if is_int else value)
            on_changed.call()
    )
    return slider


## Pushes the operation's current settings into the controls [method build]
## created, without firing their change signals — with one exception noted in
## [method _build_color], which has no way to be set quietly.
##
## Used when the settings Resource behind the form is swapped for another image.
## Rebuilding instead would work, but it would destroy the list controls — losing
## the island picker's highlighted row, which drives the emphasised marker, and
## the colour list's, which drives its editor — and reset the settings form's
## scroll position on every click through the image list.
static func refresh_values(operation: IWOperation, container: Node) -> void:
    var settings := operation.get_settings()
    if settings == null:
        return
    _refresh_into(settings, container)
    refresh_visibility(operation, container)


## Shows or hides the controls whose schema entry named a [code]hidden_when[/code]
## or [code]shown_when[/code] property, against what that property now says.
##
## Separate from [method refresh_values] because it also has to run after an
## ordinary edit: ticking the box that hides a control is itself just a settings
## change, and nothing else would notice.
static func refresh_visibility(operation: IWOperation, container: Node) -> void:
    var settings := operation.get_settings()
    if settings == null:
        return
    _visibility_into(settings, container)
    _readouts_into(settings, container)


static func _visibility_into(settings: Resource, node: Node) -> void:
    for child in node.get_children():
        if child is Control and child.has_meta(META_HIDDEN_WHEN):
            var gate: StringName = child.get_meta(META_HIDDEN_WHEN)
            (child as Control).visible = not bool(settings.get(gate))
        if child is Control and child.has_meta(META_SHOWN_WHEN):
            var against: StringName = child.get_meta(META_SHOWN_WHEN)
            var allowed: Array = child.get_meta(META_SHOWN_VALUES, [])
            (child as Control).visible = allowed.has(settings.get(against))
        _visibility_into(settings, child)


## Asks every readout in the form for its line again.
##
## Ridden along with the visibility pass rather than given a call of its own, because the
## two answer the same question — something changed, what does the form say now — and
## every place that has to remember one would have had to remember the other.
static func _readouts_into(settings: Resource, node: Node) -> void:
    for child in node.get_children():
        if child is Label and child.has_meta(META_TEXT_FROM):
            _read_into(settings, child as Label)
        _readouts_into(settings, child)


static func _refresh_into(settings: Resource, node: Node) -> void:
    for child in node.get_children():
        if child.has_meta(META_PROPERTY):
            var property: StringName = child.get_meta(META_PROPERTY)
            var value: Variant = settings.get(property)
            if child is CheckBox:
                (child as CheckBox).set_pressed_no_signal(bool(value))
            elif child is Range:
                (child as Range).set_value_no_signal(float(value))
                # EditorSpinSlider paints its own value, and the no-signal setter
                # deliberately skips the notification that would repaint it.
                (child as Control).queue_redraw()
            elif child is OptionButton:
                var choice := child as OptionButton
                var index := int(value)
                if index >= 0 and index < choice.item_count:
                    choice.select(index)
            elif child is LineEdit:
                (child as LineEdit).text = String(value)
            elif child is ColorPickerButton:
                # The one control here that cannot be set quietly; see
                # _build_color for why that turns out to be harmless.
                (child as ColorPickerButton).color = value
            elif child is IslandPicker:
                (child as IslandPicker).refresh()
            elif child is ColorList:
                (child as ColorList).refresh()
            elif child is PolygonList:
                (child as PolygonList).refresh()
            elif child is BrushList:
                (child as BrushList).refresh()
            elif child is ModelFolder:
                (child as ModelFolder).refresh()
        _refresh_into(settings, child)
