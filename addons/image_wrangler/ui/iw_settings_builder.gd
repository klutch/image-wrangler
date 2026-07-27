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

## Left indent applied to the contents of a named group.
const GROUP_INDENT := 8

## Caption width for the controls that need a label of their own.
const LABEL_WIDTH := 92

## Marks a control with the setting it edits, so [method refresh_values] can find
## it again without the builder having to keep a registry.
const META_PROPERTY := &"iw_property"


## Replaces the contents of [param container] with controls for every setting
## [param operation] declares. [param on_changed] is called after each edit.
static func build(operation: IWOperation, container: Container, on_changed: Callable) -> void:
	for child in container.get_children():
		container.remove_child(child)
		child.queue_free()

	# Consecutive entries sharing a group name go under one heading. Tracking the
	# previous name is enough because the schema is already in display order.
	var open_group := ""
	var target := container

	for setting in operation.get_settings_schema():
		var property: StringName = setting.get("property", &"")
		if property == &"":
			push_warning("Image Wrangler: setting schema entry is missing a property name.")
			continue

		var group: String = setting.get("group", "")
		if group != open_group:
			open_group = group
			target = _begin_group(container, group)

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
			IWOperation.SettingType.ISLAND_PICKER:
				control = _build_island_picker(operation, property)
			IWOperation.SettingType.COLOR_LIST:
				control = _build_color_list(operation, property)
			IWOperation.SettingType.POLYGON_LIST:
				control = _build_polygon_list(operation, property)
			_:
				control = _build_number(operation, property, label, setting, false, on_changed)

		if not control.has_meta(META_PROPERTY):
			control.set_meta(META_PROPERTY, property)
		control.tooltip_text = tooltip
		target.add_child(control)


## Opens a heading in [param container] and returns the box its members go into,
## or [param container] itself for the unnamed top-level group.
static func _begin_group(container: Container, title: String) -> Container:
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

	var heading := Label.new()
	heading.text = title
	heading.modulate = Color(1, 1, 1, 0.7)
	heading.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	group.add_child(heading)

	var indent := MarginContainer.new()
	indent.add_theme_constant_override("margin_left", GROUP_INDENT)
	group.add_child(indent)

	var body := VBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	indent.add_child(body)
	return body


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
## created, without firing their change signals.
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
			elif child is IslandPicker:
				(child as IslandPicker).refresh()
			elif child is ColorList:
				(child as ColorList).refresh()
			elif child is PolygonList:
				(child as PolygonList).refresh()
		_refresh_into(settings, child)
