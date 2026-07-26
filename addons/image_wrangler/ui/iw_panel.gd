@tool
extends VBoxContainer

## The Image Wrangler main screen: pick images, tweak an operation, write results.

const SettingsBuilder := preload("res://addons/image_wrangler/ui/iw_settings_builder.gd")
const PreviewView := preload("res://addons/image_wrangler/ui/iw_preview_view.gd")
const IslandPicker := preload("res://addons/image_wrangler/ui/iw_island_picker.gd")
const SettingsIO := preload("res://addons/image_wrangler/core/iw_settings_io.gd")

## Every operation the dock offers. Add new [IWOperation] subclasses here.
const OPERATION_SCRIPTS := [
	"res://addons/image_wrangler/core/remove_background.gd",
]

## Extensions [method Image.load_from_file] can read.
const SUPPORTED_EXTENSIONS := ["png", "jpg", "jpeg", "bmp", "tga", "webp"]

## Auto preview is switched off above this size, since every settings tweak
## would otherwise re-run the whole image and stall the editor.
const AUTO_PREVIEW_PIXEL_LIMIT := 4_194_304

## Settings edits arrive in bursts while a slider is dragged; collapse them.
const PREVIEW_DEBOUNCE := 0.15

## Longer than the preview debounce on purpose. The preview has to feel live; a
## disk write must not happen seven times a second while a slider is dragged.
const AUTOSAVE_DEBOUNCE := 0.75

var _operations: Array[IWOperation] = []
var _operation: IWOperation
var _sources: PackedStringArray = PackedStringArray()
var _source_image: Image
var _result_image: Image
var _suffix_is_default := true
var _pending_outputs: Dictionary = {}

## Settings keyed by source path, then by operation id. An entry appears the
## first time an image is selected or processed: loaded from its JSON sidecar
## when it has one, carried over from whatever is dialled in when it does not.
##
## While the dock is open this is the source of truth — the sidecar is read once
## per path and never re-read, so a half-written file or an external edit landing
## mid-drag cannot clobber live state.
var _settings_by_path: Dictionary = {}

## Set while the form is being repointed at another image's settings. Every
## change handler early-returns on it.
##
## The no-signal setters in [SettingsBuilder] should make this unnecessary, but
## the cost of one leaking through is no longer a stray preview — it is writing
## one image's values into another image's sidecar at the moment of the swap. And
## [ColorPickerButton] has no no-signal setter at all, so for the swatch this is
## the only defence.
var _refreshing := false

## Path the pending autosave belongs to, captured when it was scheduled: the
## selection can move before the timer fires.
var _autosave_path := ""

## Paths whose sidecar could not be written, so the failure is reported once
## rather than on every tick of a slider drag.
var _autosave_failures := {}

var _file_list: ItemList
var _preview: PreviewView

## The current operation's island picker, when it has one. Non-null means the
## preview can be picked on.
var _island_picker: IslandPicker
var _status_label: Label
var _detail_label: Label
var _operation_selector: OptionButton
var _key_color_row: HBoxContainer
var _key_color_button: ColorPickerButton

## Property the key-colour swatch writes to, or empty when the operation has none.
var _key_color_property := &""
var _settings_box: VBoxContainer
var _show_original: CheckButton
var _auto_preview: CheckButton
var _zoom_field: LineEdit
var _refresh_button: Button
var _remove_button: Button
var _suffix_edit: LineEdit
var _output_dir_edit: LineEdit
var _output_dir_button: Button
var _use_source_dir: CheckBox
var _process_selected_button: Button
var _process_all_button: Button
var _debounce: Timer
var _autosave: Timer
var _open_dialog: FileDialog
var _output_dialog: FileDialog
var _overwrite_dialog: ConfirmationDialog


func _ready() -> void:
	# Only a floor, so the splitters between the columns stay freely draggable.
	custom_minimum_size = Vector2(0, 240)
	_build_operations()
	_build_ui()
	_select_operation(0)
	_refresh_file_list()
	_update_controls()


## H toggles the island markers, which otherwise sit right on top of the edges
## you are trying to judge.
##
## Scoped to the dock rather than bound globally: it only fires while the panel
## is on screen and the pointer is inside it, so H stays free everywhere else in
## the editor. Being unhandled input, it also never steals a keystroke from a
## focused text field.
func _unhandled_key_input(event: InputEvent) -> void:
	if _preview == null or not is_visible_in_tree():
		return
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	if key.keycode != KEY_H or key.ctrl_pressed or key.alt_pressed or key.shift_pressed or key.meta_pressed:
		return
	if not get_global_rect().has_point(get_global_mouse_position()):
		return
	var shown := _preview.toggle_markers()
	_set_status("Island markers %s." % ("shown" if shown else "hidden"))
	accept_event()


## A pending write must not die with the dock: this runs on plugin disable and on
## editor shutdown. It deliberately touches only the settings store and the
## codec, nothing that needs the panel to still be in the tree.
func _exit_tree() -> void:
	_flush_autosave()


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
	right_split.add_child(_build_operation_column())

	_build_dialogs()

	_debounce = Timer.new()
	_debounce.one_shot = true
	_debounce.wait_time = PREVIEW_DEBOUNCE
	_debounce.timeout.connect(_run_preview)
	add_child(_debounce)

	_autosave = Timer.new()
	_autosave.one_shot = true
	_autosave.wait_time = AUTOSAVE_DEBOUNCE
	_autosave.timeout.connect(_flush_autosave)
	add_child(_autosave)


func _build_source_column() -> Control:
	var column := VBoxContainer.new()
	column.custom_minimum_size = Vector2(140, 0)

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
	column.custom_minimum_size = Vector2(140, 0)

	var toolbar := HBoxContainer.new()
	column.add_child(toolbar)

	# Labels are kept short on purpose: a container's minimum width comes from
	# its children, so a chatty toolbar would pin this column open and stop the
	# splitters from moving.
	_show_original = CheckButton.new()
	_show_original.text = "Original"
	_show_original.tooltip_text = "Toggle between the source image and the processed result."
	_show_original.toggled.connect(func(_pressed: bool) -> void: _update_preview_texture())
	toolbar.add_child(_show_original)

	_auto_preview = CheckButton.new()
	_auto_preview.text = "Auto"
	_auto_preview.button_pressed = true
	_auto_preview.tooltip_text = "Re-run the operation whenever a setting changes."
	_auto_preview.toggled.connect(_on_auto_preview_toggled)
	toolbar.add_child(_auto_preview)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	toolbar.add_child(spacer)

	_refresh_button = Button.new()
	_refresh_button.text = "Refresh"
	_refresh_button.tooltip_text = "Re-run the operation on the selected image."
	_refresh_button.pressed.connect(_run_preview)
	toolbar.add_child(_refresh_button)

	_preview = PreviewView.new()
	_preview.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_preview.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_preview.pixel_picked.connect(_on_pixel_picked)
	_preview.zoom_changed.connect(_on_zoom_changed)
	column.add_child(_preview)

	column.add_child(_build_status_row())

	return column


## The bar under the viewport, Photoshop-style: zoom on the left, status text
## filling the middle, image size hard right. It belongs to the image, so it
## spans the viewport rather than the whole dock.
func _build_status_row() -> Control:
	var row := HBoxContainer.new()

	# The zoom controls keep a zero separation of their own so the buttons stay
	# flush against the field, while the outer row still spaces them off the
	# status text.
	var zoom := HBoxContainer.new()
	zoom.add_theme_constant_override("separation", 0)
	row.add_child(zoom)

	var zoom_out_button := Button.new()
	zoom_out_button.text = "-"
	zoom_out_button.tooltip_text = "Zoom out. 25% steps below 100%, 100% steps above."
	zoom_out_button.pressed.connect(func() -> void: _preview.zoom_out())
	zoom.add_child(zoom_out_button)

	_zoom_field = LineEdit.new()
	_zoom_field.text = "100%"
	_zoom_field.alignment = HORIZONTAL_ALIGNMENT_CENTER
	_zoom_field.custom_minimum_size = Vector2(58, 0)
	_zoom_field.tooltip_text = "Zoom level, 1% to 1000%. Type a value and press Enter.\nThe mouse wheel zooms towards the pixel under the cursor, in 10% steps\nbelow 50% and 25% steps above.\nDrag to pan. While a tool is active, pan with the middle button or Ctrl+left."
	_zoom_field.text_submitted.connect(_on_zoom_submitted)
	_zoom_field.focus_exited.connect(func() -> void: _on_zoom_submitted(_zoom_field.text))
	zoom.add_child(_zoom_field)

	var zoom_in_button := Button.new()
	zoom_in_button.text = "+"
	zoom_in_button.tooltip_text = "Zoom in. 25% steps below 100%, 100% steps above."
	zoom_in_button.pressed.connect(func() -> void: _preview.zoom_in())
	zoom.add_child(zoom_in_button)

	var fit_button := Button.new()
	fit_button.text = "Fit"
	fit_button.tooltip_text = "Zoom so the whole image is visible, never past 100%."
	fit_button.pressed.connect(func() -> void: _preview.fit_to_view())
	zoom.add_child(fit_button)

	# Messages here name files and can run long. Ellipsising, and letting the
	# label soak up the free space rather than demand it, stops a status message
	# from setting a floor under the preview column's width.
	_status_label = Label.new()
	_status_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_set_status("No image selected.")
	row.add_child(_status_label)

	_detail_label = Label.new()
	_detail_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_detail_label.modulate = Color(1, 1, 1, 0.6)
	row.add_child(_detail_label)

	return row


func _build_operation_column() -> Control:
	var column := VBoxContainer.new()
	column.custom_minimum_size = Vector2(220, 0)

	var title := Label.new()
	title.text = "Operation"
	column.add_child(title)

	_operation_selector = OptionButton.new()
	for operation in _operations:
		_operation_selector.add_item(operation.get_operation_name())
	_operation_selector.item_selected.connect(_select_operation)
	column.add_child(_operation_selector)

	# The colour an operation keys out sits right under the operation itself: it
	# is what the operation is about, not a knob controlling how it works.
	_key_color_row = HBoxContainer.new()
	column.add_child(_key_color_row)

	var key_color_label := Label.new()
	key_color_label.text = "Remove Color"
	_key_color_row.add_child(key_color_label)

	_key_color_button = ColorPickerButton.new()
	_key_color_button.edit_alpha = false
	_key_color_button.custom_minimum_size = Vector2(0, 24)
	_key_color_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_key_color_button.tooltip_text = "The background color to key out.\nThe picker's eyedropper can sample it off the screen."
	_key_color_button.color_changed.connect(_on_key_color_changed)
	_key_color_row.add_child(_key_color_button)

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
		_set_status("Skipped %d unsupported file(s)." % skipped)
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
	# Its settings go with it, but its sidecar does not: the button's tooltip
	# promises the file is not touched, and a settings file beside the art is a
	# file. Re-adding the image loads it back.
	_flush_autosave()
	_settings_by_path.erase(_sources[index])
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
		_clear_settings_context()
		_set_status("No image selected.")
		_detail_label.text = ""
	_update_controls()


func _on_file_selected(index: int) -> void:
	if index < 0 or index >= _sources.size():
		return
	# The outgoing image's pending write goes out before the settings swap, or it
	# would be written against whatever came next.
	_flush_autosave()
	var path := _sources[index]
	_source_image = _load_image(path)
	_result_image = null
	if _source_image == null:
		_set_status("Could not read %s" % path.get_file())
		_detail_label.text = ""
		_preview.set_image(null)
		_clear_settings_context()
		_update_controls()
		return

	# The settings belong to this image, and the form must agree with them before
	# anything is processed, so both happen before the preview below.
	_apply_settings_for(path)

	var pixel_count := _source_image.get_width() * _source_image.get_height()
	if pixel_count > AUTO_PREVIEW_PIXEL_LIMIT and _auto_preview.button_pressed:
		_auto_preview.button_pressed = false
		_set_status("Auto preview off: %s is large. Press Refresh to process it." % path.get_file())

	_update_controls()
	if _auto_preview.button_pressed:
		_run_preview()
	else:
		_update_preview_texture()
		_update_detail_label()
	# A newly opened image starts fitted, so a large one is not shown as a
	# corner crop. Fit never magnifies, so a small one still lands at 100%.
	_preview.fit_to_view()


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
	_bind_key_color()
	SettingsBuilder.build(_operation, _settings_box, _on_setting_changed)
	_bind_island_picker()
	# _bind_island_picker already applied this image's settings for the operation
	# just selected, so the form and the operation agree before the first run.

	# Only reset the suffix while the user has not claimed it as their own.
	if _suffix_is_default or _suffix_edit.text == previous_suffix:
		_suffix_edit.text = _operation.get_output_suffix()
		_suffix_is_default = true

	_result_image = null
	if _auto_preview.button_pressed:
		_schedule_preview()


## Points the swatch at the current operation's key colour, hiding it for
## operations that do not key one out.
func _bind_key_color() -> void:
	_key_color_property = _operation.get_key_color_property()
	_key_color_row.visible = _key_color_property != &""
	_refresh_key_color()


func _on_key_color_changed(color: Color) -> void:
	if _refreshing or _operation == null or _key_color_property == &"":
		return
	var settings := _operation.get_settings()
	if settings == null:
		return
	settings.set(_key_color_property, color)
	_on_setting_changed()


## Searches the settings form for the picker at any depth.
##
## A grouped setting is nested inside its heading box rather than sitting
## directly in the form, so scanning only the form's own children finds nothing
## and every picker feature goes quietly dead.
func _find_island_picker(node: Node) -> IslandPicker:
	for child in node.get_children():
		if child is IslandPicker:
			return child
		var found := _find_island_picker(child)
		if found != null:
			return found
	return null


## Hooks up the island picker the settings builder just created, if the
## operation declared one. Operations without one leave picking switched off.
func _bind_island_picker() -> void:
	_island_picker = _find_island_picker(_settings_box)
	if _island_picker != null:
		_island_picker.pick_toggled.connect(_on_pick_toggled)
		_island_picker.islands_changed.connect(_on_islands_changed)
		_island_picker.selection_changed.connect(_update_markers)
		_island_picker.set_color_provider(_sample_source_color)
	# Switching operations always drops out of pick mode, so a fresh settings
	# form never inherits a crosshair from the one before it.
	_preview.pick_mode = false
	if _island_picker != null:
		_island_picker.set_pick_active(false)
	_apply_settings_for(_current_path())
	_update_markers()


## Path of the highlighted source, or an empty string when nothing is selected.
func _current_path() -> String:
	var index := _selected_index()
	if index < 0 or index >= _sources.size():
		return ""
	return _sources[index]


## Settings for one source, created on demand.
##
## [param template] is what the values are carried over from when the image has
## no sidecar. It is passed in rather than read from the operation because the
## batch run swaps the operation's settings as it goes — reading them there would
## make an untouched image inherit whichever image the loop happened to process
## last, and the result would depend on job order.
func _settings_for(path: String, template: Resource) -> Resource:
	if path.is_empty() or _operation == null:
		return null

	var id := _operation.get_operation_id()
	if not _settings_by_path.has(path):
		_settings_by_path[path] = {}
	var per_operation: Dictionary = _settings_by_path[path]
	if per_operation.has(id):
		return per_operation[id]

	var settings := SettingsIO.load_settings(path, _operation)
	if settings != null:
		# Clamped here rather than after the swap, so the batch path — which
		# never goes through _apply_settings_for — gets it too.
		_operation.clamp_settings_to_schema(settings)
	elif template != null and template.has_method("duplicate_for_new_image"):
		# Carries everything but the islands: a coordinate in one image means
		# nothing in another.
		settings = template.duplicate_for_new_image()
	else:
		settings = _operation.make_settings()
	per_operation[id] = settings
	return settings


## Points the operation and the form at [param path]'s settings.
func _apply_settings_for(path: String) -> void:
	if _operation == null:
		return
	var settings := _settings_for(path, _operation.get_settings())
	if settings == null:
		return

	_refreshing = true
	_operation.set_settings(settings)
	SettingsBuilder.refresh_values(_operation, _settings_box)
	_refresh_key_color()
	if _island_picker != null:
		_island_picker.refresh()
		_island_picker.set_context_label(path.get_file())
	_update_markers()
	_refreshing = false


## Writes the sidecar for whichever image the pending save belongs to.
func _flush_autosave() -> void:
	if _autosave != null:
		_autosave.stop()
	var path := _autosave_path
	_autosave_path = ""
	if path.is_empty() or _operation == null:
		return

	# Read rather than resolve: resolving would create and cache an entry, so a
	# stale pending path could write a sidecar for an image never touched.
	var per_operation: Dictionary = _settings_by_path.get(path, {})
	var settings: Resource = per_operation.get(_operation.get_operation_id())
	if settings == null:
		return
	var error := SettingsIO.save_settings(path, _operation, settings)
	if error == OK:
		_autosave_failures.erase(path)
		return
	if _autosave_failures.has(path):
		return
	_autosave_failures[path] = true
	if error == ERR_FILE_CORRUPT:
		_set_status("Cannot save settings: %s already exists and was written by something else."
				% SettingsIO.sidecar_path(path).get_file())
	else:
		_set_status("Could not write settings for %s." % path.get_file())


func _schedule_autosave() -> void:
	var path := _current_path()
	if path.is_empty() or _autosave == null:
		return
	# A pending save for a different image is written now rather than dropped.
	if not _autosave_path.is_empty() and _autosave_path != path:
		_flush_autosave()
	_autosave_path = path
	_autosave.start()


## Drops the form back to a blank context when no image is selected. The
## operation keeps whatever is dialled in, so it stays the carry-over template.
func _clear_settings_context() -> void:
	if _operation == null:
		return
	_refreshing = true
	var current := _operation.get_settings()
	if current != null and current.has_method("duplicate_for_new_image"):
		# Keeps the dialled-in values as the carry-over template, but drops the
		# departed image's islands rather than leaving them in the picker.
		_operation.set_settings(current.duplicate_for_new_image())
	if _island_picker != null:
		_island_picker.refresh()
		_island_picker.set_context_label("")
	_update_markers()
	_refreshing = false


## Pushes the current settings' key colour into the swatch.
func _refresh_key_color() -> void:
	if _key_color_property == &"" or _operation == null:
		return
	var settings := _operation.get_settings()
	if settings != null:
		_key_color_button.color = settings.get(_key_color_property)


## Colour behind a pixel of the image on screen, for the island row swatches.
func _sample_source_color(pixel: Vector2i) -> Color:
	if _source_image == null:
		return Color.MAGENTA
	if pixel.x < 0 or pixel.y < 0 or pixel.x >= _source_image.get_width() or pixel.y >= _source_image.get_height():
		return Color.MAGENTA
	return _source_image.get_pixelv(pixel)


func _on_pick_toggled(enabled: bool) -> void:
	_preview.pick_mode = enabled
	if enabled:
		_set_status("Click a spot in the preview to add it to the list.")


func _on_pixel_picked(pixel: Vector2i) -> void:
	if _island_picker == null or _source_image == null:
		return
	_island_picker.add_island(pixel)
	_set_status("Picked (%d, %d)." % [pixel.x, pixel.y])


func _on_islands_changed() -> void:
	# Nothing to store: the picker edited the IslandList inside this image's
	# settings directly, so it is already where it belongs.
	_update_markers()
	_on_setting_changed()


func _update_markers() -> void:
	if _island_picker == null:
		var empty: Array[Vector2i] = []
		_preview.set_markers(empty, -1)
		return
	_preview.set_markers(_island_picker.get_islands(), _island_picker.selected_index())


func _on_setting_changed() -> void:
	if _refreshing:
		return
	_schedule_autosave()
	if _auto_preview.button_pressed:
		_schedule_preview()
	else:
		_set_status("Settings changed. Press Refresh to update the preview.")


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
	_set_status("%s in %d ms" % [_operation.get_operation_name(), elapsed])
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


## Accepts "150", "150%" or whitespace around either; anything unparseable snaps
## the field back to the zoom actually in force.
func _on_zoom_submitted(text: String) -> void:
	var cleaned := text.strip_edges().trim_suffix("%").strip_edges()
	if cleaned.is_valid_float():
		_preview.set_zoom(cleaned.to_float())
	_show_zoom(_preview.get_zoom())


func _on_zoom_changed(percent: float) -> void:
	_show_zoom(percent)


func _show_zoom(percent: float) -> void:
	# Rounded for display only; the view keeps the exact value, which matters
	# after Fit lands on something like 14.65%.
	var shown := "%d%%" % roundi(percent)
	if _zoom_field.text != shown:
		_zoom_field.text = shown


## The status label ellipsises, so the full message is kept as its tooltip.
func _set_status(text: String) -> void:
	_status_label.text = text
	_status_label.tooltip_text = text


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
		_set_status("Choose an output folder first.")
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

	# Resolved up front: _settings_for carries over from the template, and the
	# template has to stay the selected image's settings rather than becoming
	# whichever image the loop swapped in last.
	_flush_autosave()
	var template := _operation.get_settings()
	var settings_for_job := {}
	for source_path: String in jobs:
		settings_for_job[source_path] = _settings_for(source_path, template)

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
		# Each image is processed with its own settings, not the selected image's.
		# The form is left alone and the selection's settings restored below.
		if settings_for_job.has(source_path):
			_operation.set_settings(settings_for_job[source_path])
		var result := _operation.process_image(image)
		if result.save_png(destination) != OK:
			failures.append(source_path.get_file())
			continue
		written += 1

	_operation.set_settings(template)

	if failures.is_empty():
		_set_status("Wrote %d file(s)." % written)
	else:
		_set_status("Wrote %d file(s), %d failed: %s" % [written, failures.size(), ", ".join(failures)])
		push_error("Image Wrangler: failed to process %s" % ", ".join(failures))

	if Engine.is_editor_hint():
		EditorInterface.get_resource_filesystem().scan()
