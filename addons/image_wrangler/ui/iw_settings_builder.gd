@tool
extends RefCounted

## Builds a settings form for an [IWOperation] from its declarative schema.
##
## Keeping this generic is what lets a new tool ship without any UI work: the
## operation lists its properties, this fills a container with controls wired
## straight back to them.

const PointListEditor := preload("res://addons/image_wrangler/ui/iw_point_list_editor.gd")


## Replaces the contents of [param container] with controls for every setting
## [param operation] declares. [param on_changed] is called after each edit.
static func build(operation: IWOperation, container: Container, on_changed: Callable) -> void:
	for child in container.get_children():
		container.remove_child(child)
		child.queue_free()

	for setting in operation.get_settings_schema():
		var property: StringName = setting.get("property", &"")
		if property == &"":
			push_warning("Image Wrangler: setting schema entry is missing a property name.")
			continue

		var label: String = setting.get("label", String(property).capitalize())
		var tooltip: String = setting.get("tooltip", "")
		var type: int = setting.get("type", IWOperation.SettingType.FLOAT)
		var control: Control

		match type:
			IWOperation.SettingType.BOOL:
				control = _build_bool(operation, property, label, on_changed)
			IWOperation.SettingType.INT:
				control = _build_number(operation, property, label, setting, true, on_changed)
			IWOperation.SettingType.POINT_LIST:
				control = _build_point_list(operation, property, label)
			_:
				control = _build_number(operation, property, label, setting, false, on_changed)

		control.tooltip_text = tooltip
		container.add_child(control)


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


## Point lists are deliberately not wired to [param on_changed] here. Picking
## needs the preview, which only the dock can reach, so it connects the editor's
## signals itself and re-runs the operation from there.
static func _build_point_list(operation: IWOperation, property: StringName, label: String) -> Control:
	var editor := PointListEditor.new()
	editor.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	editor.setup(operation, property, label)
	return editor


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
