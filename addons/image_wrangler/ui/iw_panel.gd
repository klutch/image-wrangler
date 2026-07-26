@tool
extends VBoxContainer

## The Image Wrangler bottom panel: pick images, tweak a tool, write results.

const SettingsBuilder := preload("res://addons/image_wrangler/ui/iw_settings_builder.gd")
const PreviewView := preload("res://addons/image_wrangler/ui/iw_preview_view.gd")
const PointListEditor := preload("res://addons/image_wrangler/ui/iw_point_list_editor.gd")

## Every tool the dock offers. Add new [IWOperation] subclasses here.
const OPERATION_SCRIPTS := [
	"res://addons/image_wrangler/core/iw_background_remover.gd",
]

## Extensions [method Image.load_from_file] can read.
const SUPPORTED_EXTENSIONS := ["png", "jpg", "jpeg", "bmp", "tga", "webp"]

## Auto preview is switched off above this size, since every settings tweak
## would otherwise re-run the whole image and stall the editor.
const AUTO_PREVIEW_PIXEL_LIMIT := 4_194_304

## Settings edits arrive in bursts while a slider is dragged; collapse them.
const PREVIEW_DEBOUNCE := 0.15

var _operations: Array[IWOperation] = []
var _operation: IWOperation
var _sources: PackedStringArray = PackedStringArray()
var _source_image: Image
var _result_image: Image
var _suffix_is_default := true
var _pending_outputs: Dictionary = {}

var _file_list: ItemList
var _preview: PreviewView

## The current tool's point-list control, when it has one. Non-null means the
## preview can be picked on.
var _point_editor: PointListEditor
var _status_label: Label
var _detail_label: Label
var _operation_selector: OptionButton
var _operation_description: Label
var _settings_box: VBoxContainer
var _show_original: CheckButton
var _auto_preview: CheckButton
var _refresh_button: Button
var _remove_button: Button
var _suffix_edit: LineEdit
var _output_dir_edit: LineEdit
var _output_dir_button: Button
var _use_source_dir: CheckBox
var _process_selected_button: Button
var _process_all_button: Button
var _debounce: Timer
var _open_dialog: FileDialog
var _output_dialog: FileDialog
var _overwrite_dialog: ConfirmationDialog


func _ready() -> void:
	custom_minimum_size = Vector2(0, 360)
	_build_operations()
	_build_ui()
	_select_operation(0)
	_refresh_file_list()
	_update_controls()


func _build_operations() -> void:
	for path: String in OPERATION_SCRIPTS:
		var script: GDScript = load(path)
		if script == null:
			push_error("Image Wrangler: could not load operation script at %s" % path)
			continue
		_operations.append(script.new())


# --- Layout -------------------------------------------------------------

func _build_ui() -> void:
	add_theme_constant_override("separation", 4)

	var columns := HSplitContainer.new()
	columns.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(columns)

	columns.add_child(_build_source_column())

	var right_split := HSplitContainer.new()
	right_split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	columns.add_child(right_split)
	right_split.add_child(_build_preview_column())
	right_split.add_child(_build_tool_column())

	add_child(_build_status_bar())
	_build_dialogs()

	_debounce = Timer.new()
	_debounce.one_shot = true
	_debounce.wait_time = PREVIEW_DEBOUNCE
	_debounce.timeout.connect(_run_preview)
	add_child(_debounce)


func _build_source_column() -> Control:
	var column := VBoxContainer.new()
	column.custom_minimum_size = Vector2(220, 0)

	var header := HBoxContainer.new()
	column.add_child(header)

	var title := Label.new()
	title.text = "Images"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)

	var add_button := Button.new()
	add_button.text = "Add"
	add_button.tooltip_text = "Add image files."
	add_button.pressed.connect(func() -> void: _open_dialog.popup_centered_ratio(0.6))
	header.add_child(add_button)

	_remove_button = Button.new()
	_remove_button.text = "Remove"
	_remove_button.tooltip_text = "Remove the selected image from the list. The file is not touched."
	_remove_button.pressed.connect(_on_remove_pressed)
	header.add_child(_remove_button)

	_file_list = ItemList.new()
	_file_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_file_list.allow_reselect = true
	_file_list.item_selected.connect(_on_file_selected)
	column.add_child(_file_list)

	var hint := Label.new()
	hint.text = "Drag images here from the FileSystem dock."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.modulate = Color(1, 1, 1, 0.6)
	column.add_child(hint)

	return column


func _build_preview_column() -> Control:
	var column := VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.custom_minimum_size = Vector2(240, 0)

	var toolbar := HBoxContainer.new()
	column.add_child(toolbar)

	_show_original = CheckButton.new()
	_show_original.text = "Show Original"
	_show_original.tooltip_text = "Toggle between the source image and the processed result."
	_show_original.toggled.connect(func(_pressed: bool) -> void: _update_preview_texture())
	toolbar.add_child(_show_original)

	_auto_preview = CheckButton.new()
	_auto_preview.text = "Auto Preview"
	_auto_preview.button_pressed = true
	_auto_preview.tooltip_text = "Re-run the tool whenever a setting changes."
	_auto_preview.toggled.connect(_on_auto_preview_toggled)
	toolbar.add_child(_auto_preview)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	toolbar.add_child(spacer)

	_refresh_button = Button.new()
	_refresh_button.text = "Refresh"
	_refresh_button.tooltip_text = "Re-run the tool on the selected image."
	_refresh_button.pressed.connect(_run_preview)
	toolbar.add_child(_refresh_button)

	_preview = PreviewView.new()
	_preview.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_preview.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_preview.pixel_picked.connect(_on_pixel_picked)
	column.add_child(_preview)

	return column


func _build_tool_column() -> Control:
	var column := VBoxContainer.new()
	column.custom_minimum_size = Vector2(280, 0)

	var title := Label.new()
	title.text = "Tool"
	column.add_child(title)

	_operation_selector = OptionButton.new()
	for operation in _operations:
		_operation_selector.add_item(operation.get_operation_name())
	_operation_selector.item_selected.connect(_select_operation)
	column.add_child(_operation_selector)

	_operation_description = Label.new()
	_operation_description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_operation_description.modulate = Color(1, 1, 1, 0.6)
	column.add_child(_operation_description)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	column.add_child(scroll)

	_settings_box = VBoxContainer.new()
	_settings_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_settings_box)

	column.add_child(HSeparator.new())
	column.add_child(_build_output_section())

	return column


func _build_output_section() -> Control:
	var section := VBoxContainer.new()

	var title := Label.new()
	title.text = "Output"
	section.add_child(title)

	var suffix_row := HBoxContainer.new()
	section.add_child(suffix_row)
	var suffix_label := Label.new()
	suffix_label.text = "Suffix"
	suffix_row.add_child(suffix_label)
	_suffix_edit = LineEdit.new()
	_suffix_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_suffix_edit.tooltip_text = "Appended to the file name. Results are always written as PNG.\nLeave empty to write over the source when saving beside it."
	_suffix_edit.text_changed.connect(func(_text: String) -> void: _suffix_is_default = false)
	suffix_row.add_child(_suffix_edit)

	_use_source_dir = CheckBox.new()
	_use_source_dir.text = "Save Beside Source"
	_use_source_dir.button_pressed = true
	_use_source_dir.toggled.connect(_on_use_source_dir_toggled)
	section.add_child(_use_source_dir)

	var dir_row := HBoxContainer.new()
	section.add_child(dir_row)
	_output_dir_edit = LineEdit.new()
	_output_dir_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_output_dir_edit.text = "res://"
	_output_dir_edit.editable = false
	dir_row.add_child(_output_dir_edit)
	_output_dir_button = Button.new()
	_output_dir_button.text = "..."
	_output_dir_button.disabled = true
	_output_dir_button.pressed.connect(func() -> void: _output_dialog.popup_centered_ratio(0.6))
	dir_row.add_child(_output_dir_button)

	_process_selected_button = Button.new()
	_process_selected_button.text = "Process Selected"
	_process_selected_button.pressed.connect(_on_process_selected)
	section.add_child(_process_selected_button)

	_process_all_button = Button.new()
	_process_all_button.text = "Process All"
	_process_all_button.pressed.connect(_on_process_all)
	section.add_child(_process_all_button)

	return section


func _build_status_bar() -> Control:
	var bar := HBoxContainer.new()

	_status_label = Label.new()
	_status_label.text = "No image selected."
	bar.add_child(_status_label)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(spacer)

	_detail_label = Label.new()
	_detail_label.modulate = Color(1, 1, 1, 0.6)
	bar.add_child(_detail_label)

	return bar


func _build_dialogs() -> void:
	_open_dialog = FileDialog.new()
	_open_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILES
	_open_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_open_dialog.title = "Add Images"
	var patterns := PackedStringArray()
	for extension: String in SUPPORTED_EXTENSIONS:
		patterns.append("*." + extension)
	_open_dialog.add_filter(", ".join(patterns), "Images")
	_open_dialog.files_selected.connect(_add_sources)
	add_child(_open_dialog)

	_output_dialog = FileDialog.new()
	_output_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	_output_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_output_dialog.title = "Choose Output Folder"
	_output_dialog.dir_selected.connect(func(dir: String) -> void: _output_dir_edit.text = dir)
	add_child(_output_dialog)

	_overwrite_dialog = ConfirmationDialog.new()
	_overwrite_dialog.title = "Overwrite Existing Files?"
	_overwrite_dialog.ok_button_text = "Overwrite"
	_overwrite_dialog.confirmed.connect(_write_pending_outputs)
	_overwrite_dialog.canceled.connect(func() -> void: _pending_outputs.clear())
	add_child(_overwrite_dialog)


# --- Sources ------------------------------------------------------------

func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	if not (data is Dictionary) or data.get("type", "") != "files":
		return false
	for path in data.get("files", []):
		if _is_supported(String(path)):
			return true
	return false


func _drop_data(_at_position: Vector2, data: Variant) -> void:
	_add_sources(data.get("files", PackedStringArray()))


static func _is_supported(path: String) -> bool:
	return SUPPORTED_EXTENSIONS.has(path.get_extension().to_lower())


func _add_sources(paths: PackedStringArray) -> void:
	var skipped := 0
	var first_new := -1
	for raw_path in paths:
		var path := String(raw_path)
		if not _is_supported(path):
			skipped += 1
			continue
		if _sources.has(path):
			continue
		if first_new < 0:
			first_new = _sources.size()
		_sources.append(path)

	_refresh_file_list()
	if first_new >= 0 and _file_list.get_selected_items().is_empty():
		_file_list.select(first_new)
		_on_file_selected(first_new)
	elif skipped > 0:
		_status_label.text = "Skipped %d unsupported file(s)." % skipped
	_update_controls()


func _refresh_file_list() -> void:
	var selected := _selected_index()
	_file_list.clear()
	for path in _sources:
		var index := _file_list.add_item(path.get_file())
		_file_list.set_item_tooltip(index, path)
	if selected >= 0 and selected < _file_list.item_count:
		_file_list.select(selected)


func _selected_index() -> int:
	var selection := _file_list.get_selected_items()
	return selection[0] if not selection.is_empty() else -1


func _on_remove_pressed() -> void:
	var index := _selected_index()
	if index < 0:
		return
	_sources.remove_at(index)
	_source_image = null
	_result_image = null
	_refresh_file_list()
	if _file_list.item_count > 0:
		var next := mini(index, _file_list.item_count - 1)
		_file_list.select(next)
		_on_file_selected(next)
	else:
		_preview.set_image(null)
		_status_label.text = "No image selected."
		_detail_label.text = ""
	_update_controls()


func _on_file_selected(index: int) -> void:
	if index < 0 or index >= _sources.size():
		return
	var path := _sources[index]
	_source_image = _load_image(path)
	_result_image = null
	if _source_image == null:
		_status_label.text = "Could not read %s" % path.get_file()
		_detail_label.text = ""
		_preview.set_image(null)
		_update_controls()
		return

	var pixel_count := _source_image.get_width() * _source_image.get_height()
	if pixel_count > AUTO_PREVIEW_PIXEL_LIMIT and _auto_preview.button_pressed:
		_auto_preview.button_pressed = false
		_status_label.text = "Auto preview off: %s is large. Press Refresh to process it." % path.get_file()

	_update_controls()
	if _auto_preview.button_pressed:
		_run_preview()
	else:
		_update_preview_texture()
		_update_detail_label()


static func _load_image(path: String) -> Image:
	var image := Image.load_from_file(path)
	if image == null or image.is_empty():
		return null
	return image


# --- Operations and preview ---------------------------------------------

func _select_operation(index: int) -> void:
	if index < 0 or index >= _operations.size():
		return
	var previous_suffix := _operation.get_output_suffix() if _operation != null else ""
	_operation = _operations[index]
	_operation_selector.selected = index
	_operation_description.text = _operation.get_operation_description()
	SettingsBuilder.build(_operation, _settings_box, _on_setting_changed)
	_bind_point_editor()

	# Only reset the suffix while the user has not claimed it as their own.
	if _suffix_is_default or _suffix_edit.text == previous_suffix:
		_suffix_edit.text = _operation.get_output_suffix()
		_suffix_is_default = true

	_result_image = null
	if _auto_preview.button_pressed:
		_schedule_preview()


## Hooks up the point-list control the settings builder just created, if the
## tool declared one. Tools without one leave picking switched off.
func _bind_point_editor() -> void:
	_point_editor = null
	for child in _settings_box.get_children():
		if child is PointListEditor:
			_point_editor = child
			_point_editor.pick_toggled.connect(_on_pick_toggled)
			_point_editor.points_changed.connect(_on_points_changed)
			_point_editor.selection_changed.connect(_update_markers)
			break
	# Switching tools always drops out of pick mode, so a fresh settings form
	# never inherits a crosshair from the tool before it.
	_preview.pick_mode = false
	if _point_editor != null:
		_point_editor.set_pick_active(false)
	_update_markers()


func _on_pick_toggled(enabled: bool) -> void:
	_preview.pick_mode = enabled
	if enabled:
		_status_label.text = "Click a spot in the preview to add it to the list."


func _on_pixel_picked(pixel: Vector2i) -> void:
	if _point_editor == null or _source_image == null:
		return
	_point_editor.add_point(pixel, _source_image.get_pixelv(pixel))
	_status_label.text = "Picked (%d, %d)." % [pixel.x, pixel.y]


func _on_points_changed() -> void:
	_update_markers()
	_on_setting_changed()


func _update_markers() -> void:
	if _point_editor == null:
		var empty: Array[Vector2i] = []
		_preview.set_markers(empty, -1)
		return
	_preview.set_markers(_point_editor.get_points(), _point_editor.selected_index())


func _on_setting_changed() -> void:
	if _auto_preview.button_pressed:
		_schedule_preview()
	else:
		_status_label.text = "Settings changed. Press Refresh to update the preview."


func _on_auto_preview_toggled(pressed: bool) -> void:
	if pressed:
		_schedule_preview()


func _schedule_preview() -> void:
	if _source_image == null:
		return
	_debounce.start()


func _run_preview() -> void:
	_debounce.stop()
	if _source_image == null or _operation == null:
		return
	var started := Time.get_ticks_msec()
	_result_image = _operation.process_image(_source_image)
	var elapsed := Time.get_ticks_msec() - started
	_status_label.text = "%s in %d ms" % [_operation.get_operation_name(), elapsed]
	_update_preview_texture()
	_update_detail_label()


func _update_preview_texture() -> void:
	if _source_image == null:
		_preview.set_image(null)
		return
	if _show_original.button_pressed or _result_image == null:
		_preview.set_image(_source_image)
	else:
		_preview.set_image(_result_image)


func _update_detail_label() -> void:
	if _source_image == null:
		_detail_label.text = ""
		return
	_detail_label.text = "%d x %d" % [_source_image.get_width(), _source_image.get_height()]


func _update_controls() -> void:
	var has_selection := _selected_index() >= 0
	var has_any := not _sources.is_empty()
	_remove_button.disabled = not has_selection
	_refresh_button.disabled = _source_image == null
	_process_selected_button.disabled = _source_image == null
	_process_all_button.disabled = not has_any


func _on_use_source_dir_toggled(pressed: bool) -> void:
	_output_dir_edit.editable = not pressed
	_output_dir_button.disabled = pressed


# --- Writing results ----------------------------------------------------

func _on_process_selected() -> void:
	var index := _selected_index()
	if index < 0:
		return
	_start_jobs(PackedStringArray([_sources[index]]))


func _on_process_all() -> void:
	_start_jobs(_sources)


## Maps each source to its destination, then asks before clobbering anything.
func _start_jobs(paths: PackedStringArray) -> void:
	if paths.is_empty() or _operation == null:
		return
	if not _use_source_dir.button_pressed and _output_dir_edit.text.strip_edges().is_empty():
		_status_label.text = "Choose an output folder first."
		return

	var jobs := {}
	var existing := PackedStringArray()
	for path in paths:
		var destination := _output_path_for(path)
		jobs[path] = destination
		if FileAccess.file_exists(destination):
			existing.append(destination.get_file())

	_pending_outputs = jobs
	if existing.is_empty():
		_write_pending_outputs()
		return

	var preview := existing
	var trailer := ""
	if existing.size() > 8:
		preview = existing.slice(0, 8)
		trailer = "\n... and %d more" % (existing.size() - 8)
	_overwrite_dialog.dialog_text = "These files already exist and will be replaced:\n\n%s%s" % [
		"\n".join(preview), trailer,
	]
	_overwrite_dialog.popup_centered()


func _output_path_for(path: String) -> String:
	var directory := path.get_base_dir() if _use_source_dir.button_pressed else _output_dir_edit.text.strip_edges()
	return directory.path_join(path.get_file().get_basename() + _suffix_edit.text + ".png")


## Runs the operation over every queued source and writes the results.
func _write_pending_outputs() -> void:
	var jobs := _pending_outputs
	_pending_outputs = {}
	if jobs.is_empty() or _operation == null:
		return

	var written := 0
	var failures := PackedStringArray()
	for source_path: String in jobs:
		var destination: String = jobs[source_path]
		var image := _load_image(source_path)
		if image == null:
			failures.append(source_path.get_file())
			continue
		var directory := destination.get_base_dir()
		if not DirAccess.dir_exists_absolute(directory):
			var make_error := DirAccess.make_dir_recursive_absolute(directory)
			if make_error != OK:
				failures.append(source_path.get_file())
				continue
		var result := _operation.process_image(image)
		if result.save_png(destination) != OK:
			failures.append(source_path.get_file())
			continue
		written += 1

	if failures.is_empty():
		_status_label.text = "Wrote %d file(s)." % written
	else:
		_status_label.text = "Wrote %d file(s), %d failed: %s" % [written, failures.size(), ", ".join(failures)]
		push_error("Image Wrangler: failed to process %s" % ", ".join(failures))

	if Engine.is_editor_hint():
		EditorInterface.get_resource_filesystem().scan()
