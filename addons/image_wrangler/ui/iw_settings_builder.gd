@tool
extends RefCounted

## Builds a settings form for an [IWOperation] from its declarative schema.
##
## Keeping this generic is what lets a new operation ship without any UI work:
## the operation lists its properties, this fills a container with controls wired
## straight back to them.

const IslandPicker := preload("res://addons/image_wrangler/ui/iw_island_picker.gd")

## Left indent applied to the contents of a named group.
const GROUP_INDENT := 8


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
			IWOperation.SettingType.ISLAND_PICKER:
				control = _build_island_picker(operation, property)
			_:
				control = _build_number(operation, property, label, setting, false, on_changed)

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


static func _build_bool(operation: IWOperation, property: StringName, label: String, on_changed: Callable) -> Control:
	var check := CheckBox.new()
	check.text = label
	check.button_pressed = operation.get(property)
	check.toggled.connect(
		func(pressed: bool) -> void:
			operation.set(property, pressed)
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
	slider.value = operation.get(property)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.value_changed.connect(
		func(value: float) -> void:
			operation.set(property, int(value) if is_int else value)
			on_changed.call()
	)
	return slider
