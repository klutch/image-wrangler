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
	"res://addons/image_wrangler/core/rename.gd",
]

## Extensions [method Image.load_from_file] can read.
const SUPPORTED_EXTENSIONS := ["png", "jpg", "jpeg", "bmp", "tga", "webp"]

## Auto preview is switched off above this size, since every settings tweak
## would otherwise re-run the whole image and stall the editor.
const AUTO_PREVIEW_PIXEL_LIMIT := 4_194_304

## Settings edits arrive in bursts while a slider is dragged; collapse them.
const PREVIEW_DEBOUNCE := 0.15

## How close a zoom has to be to a ladder rung to count as that rung rather than
## as a value of its own. Comfortably under the smallest gap in the ladder.
const _ZOOM_MATCH := 0.01

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
var _zoom_select: OptionButton
var _zoom_entry: LineEdit
var _refresh_button: Button
var _remove_button: Button
var _clear_button: Button
var _suffix_edit: LineEdit
var _process_selected_button: Button
var _process_all_button: Button
var _debounce: Timer
var _autosave: Timer
var _open_dialog: FileDialog
var _output_dialog: FileDialog
var _save_dialog: FileDialog

## Which source a pending Save As belongs to, held between opening the dialog
## and the user choosing a name.
var _save_source := ""
var _overwrite_dialog: ConfirmationDialog
var _removal_dialog: ConfirmationDialog

## Sources whose originals may be deleted, mapped to the copy that replaced them.
## Filled during a run and acted on only after the user confirms and every copy
## has been proved identical to its source.
var _pending_removals: Dictionary = {}


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

	_clear_button = Button.new()
	_clear_button.text = "Clear"
	_clear_button.tooltip_text = "Remove every image from the list. The files are not touched."
	_clear_button.pressed.connect(_on_clear_pressed)
	header.add_child(_clear_button)

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
	zoom_out_button.tooltip_text = "Zoom out one step."
	zoom_out_button.pressed.connect(func() -> void: _preview.zoom_out())
	zoom.add_child(zoom_out_button)

	_zoom_select = OptionButton.new()
	_zoom_select.custom_minimum_size = Vector2(76, 0)
	_zoom_select.tooltip_text = "Zoom level. The buttons, the wheel and this list all step through the same\nstops. The wheel zooms towards the pixel under the cursor.\nRight-click to type an exact value instead.\nFit can land between stops; such a value is shown here too, until you\nleave it. Drag to pan — while a tool is active, use middle or Ctrl+left."
	_zoom_select.item_selected.connect(_on_zoom_selected)
	# The signal fires ahead of OptionButton's own handling, so accepting the
	# event here is what stops a right-click also opening the popup.
	_zoom_select.gui_input.connect(_on_zoom_select_input)
	zoom.add_child(_zoom_select)

	# Shares the slot with the dropdown; only ever one of the two is visible.
	_zoom_entry = LineEdit.new()
	_zoom_entry.custom_minimum_size = _zoom_select.custom_minimum_size
	_zoom_entry.alignment = HORIZONTAL_ALIGNMENT_CENTER
	_zoom_entry.tooltip_text = "Type a zoom from 1 to 1000. Enter accepts, Escape cancels."
	_zoom_entry.hide()
	_zoom_entry.text_submitted.connect(_commit_zoom_entry)
	_zoom_entry.focus_exited.connect(func() -> void: _commit_zoom_entry(_zoom_entry.text))
	_zoom_entry.gui_input.connect(_on_zoom_entry_input)
	zoom.add_child(_zoom_entry)

	_refresh_zoom_items(100.0)

	var zoom_in_button := Button.new()
	zoom_in_button.text = "+"
	zoom_in_button.tooltip_text = "Zoom in one step."
	zoom_in_button.pressed.connect(func() -> void: _preview.zoom_in())
	zoom.add_child(zoom_in_button)

	var fit_button := Button.new()
	fit_button.text = "Fit"
	fit_button.tooltip_text = "Zoom so the image fills the frame, whichever axis runs out first."
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
	_suffix_edit.tooltip_text = "Appended to the file name. Results are always written as PNG.\nSuggests a name when saving one image, and names them all when\nprocessing the whole list."
	_suffix_edit.text_changed.connect(func(_text: String) -> void: _suffix_is_default = false)
	suffix_row.add_child(_suffix_edit)

	_process_selected_button = Button.new()
	_process_selected_button.text = "Process Current Only"
	_process_selected_button.tooltip_text = "Process the selected image and ask where to save it."
	_process_selected_button.pressed.connect(_on_process_selected)
	section.add_child(_process_selected_button)

	_process_all_button = Button.new()
	_process_all_button.text = "Process All"
	_process_all_button.tooltip_text = "Process every image in the list and ask for a folder to put them in."
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
	_output_dialog.title = "Process All Into Folder"
	_output_dialog.dir_selected.connect(_on_output_dir_chosen)
	add_child(_output_dialog)

	# Save mode prompts about an existing file itself, which is why the single
	# image path does not also go through the overwrite dialog.
	_save_dialog = FileDialog.new()
	_save_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	_save_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_save_dialog.title = "Save Processed Image"
	_save_dialog.add_filter("*.png", "PNG Image")
	_save_dialog.file_selected.connect(_on_save_file_chosen)
	add_child(_save_dialog)

	_overwrite_dialog = ConfirmationDialog.new()
	_overwrite_dialog.title = "Overwrite Existing Files?"
	_overwrite_dialog.ok_button_text = "Overwrite"
	_overwrite_dialog.confirmed.connect(_write_pending_outputs)
	_overwrite_dialog.canceled.connect(func() -> void: _pending_outputs.clear())
	add_child(_overwrite_dialog)

	_removal_dialog = ConfirmationDialog.new()
	_removal_dialog.title = "Remove Old Files?"
	_removal_dialog.ok_button_text = "Remove"
	_removal_dialog.confirmed.connect(_verify_then_remove_sources)
	_removal_dialog.canceled.connect(func() -> void: _pending_removals.clear())
	add_child(_removal_dialog)


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


## Empties the Images list. Like Remove, this only changes what the dock is
## pointed at — nothing on disk is touched, and any sidecars stay where they are
## to be picked up again if the same files are re-added.
func _on_clear_pressed() -> void:
	if _sources.is_empty():
		return
	# A pending write goes out before the entry it belongs to disappears.
	_flush_autosave()
	_sources = PackedStringArray()
	_settings_by_path.clear()
	_autosave_failures.clear()
	_source_image = null
	_result_image = null
	_refresh_file_list()
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
	# A newly opened image starts fitted, so it arrives filling the frame rather
	# than as a corner crop or a speck in the middle.
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
	# Any pending write belongs to the operation on its way out, and the flush
	# resolves it by the *current* operation's id — so it has to go first.
	_flush_autosave()
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

	# An operation whose settings describe the batch keeps one set for the whole
	# session: no per-path entry, no sidecar, nothing to swap.
	if not _operation.settings_are_per_image():
		return _operation.get_settings()

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
	if _operation != null and not _operation.settings_are_per_image():
		# Nothing to save: these settings do not belong to any one file.
		return
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
	# An operation whose effect is not visible in the pixels — a rename — reports
	# what it would do instead, so it is still inspectable before being run.
	var path := _current_path()
	var note := _operation.describe_output(path, _suffix_edit.text, maxi(_sources.find(path), 0)) if not path.is_empty() else ""
	if note.is_empty():
		_set_status("%s in %d ms" % [_operation.get_operation_name(), elapsed])
	else:
		_set_status(note)
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


## Right-clicking the dropdown swaps it for a text field, so a zoom that is not
## on the list can still be asked for by name.
func _on_zoom_select_input(event: InputEvent) -> void:
	var button := event as InputEventMouseButton
	if button == null or not button.pressed or button.button_index != MOUSE_BUTTON_RIGHT:
		return
	_zoom_select.accept_event()
	_begin_zoom_entry()


func _begin_zoom_entry() -> void:
	# Rounded, because it is a starting point to edit rather than a reading. The
	# exact value is only lost if the user accepts what is shown.
	_zoom_entry.text = "%d" % roundi(_preview.get_zoom())
	_zoom_select.hide()
	_zoom_entry.show()
	_zoom_entry.grab_focus()
	_zoom_entry.select_all()


## Applies whatever was typed and puts the dropdown back.
##
## Reached from Enter and from losing focus, and hiding a focused field raises
## focus_exited — so this has to be safe to call twice for one edit.
func _commit_zoom_entry(text: String) -> void:
	if not _zoom_entry.visible:
		return
	_end_zoom_entry()
	var cleaned := text.strip_edges().trim_suffix("%").strip_edges()
	if cleaned.is_valid_float():
		_preview.set_zoom(cleaned.to_float())
	# set_zoom clamps, and stays quiet when the value has not moved, so the
	# dropdown is rebuilt from the view rather than from what was typed.
	_refresh_zoom_items(_preview.get_zoom())


func _on_zoom_entry_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.keycode != KEY_ESCAPE:
		return
	_zoom_entry.accept_event()
	_end_zoom_entry()
	_refresh_zoom_items(_preview.get_zoom())


func _end_zoom_entry() -> void:
	_zoom_entry.hide()
	_zoom_select.show()


func _on_zoom_selected(index: int) -> void:
	# The exact value rides in the metadata: the label is rounded for display,
	# and picking "15%" should restore the 14.65% Fit actually chose.
	_preview.set_zoom(_zoom_select.get_item_metadata(index))


func _on_zoom_changed(percent: float) -> void:
	_refresh_zoom_items(percent)


## Rebuilds the dropdown around [param percent] and selects it.
##
## The list is [constant PreviewView.ZOOM_STOPS], the same stops the buttons and
## the wheel step through. Fit can land between them, so a value that is not on
## the list gets a row of its own, in sorted position, for as long as the view
## sits there — the control has to be able to say what the zoom actually is, not
## merely the nearest thing it can offer.
func _refresh_zoom_items(percent: float) -> void:
	var values := PackedFloat32Array()
	var placed := false
	for stop in PreviewView.zoom_stops():
		if not placed and absf(stop - percent) < _ZOOM_MATCH:
			placed = true
		elif not placed and percent < stop:
			values.append(percent)
			placed = true
		values.append(stop)
	if not placed:
		values.append(percent)

	_zoom_select.clear()
	for i in values.size():
		# Rounded for display only; the view keeps the exact value, which matters
		# after Fit lands on something like 14.65%.
		_zoom_select.add_item("%d%%" % roundi(values[i]))
		_zoom_select.set_item_metadata(i, values[i])
		if absf(values[i] - percent) < _ZOOM_MATCH:
			# select() does not re-emit item_selected, so this cannot loop back
			# into _on_zoom_selected.
			_zoom_select.select(i)


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
	_clear_button.disabled = not has_any
	_refresh_button.disabled = _source_image == null
	_process_selected_button.disabled = _source_image == null
	_process_all_button.disabled = not has_any


# --- Writing results ----------------------------------------------------

## Processing one image asks where to put it, so the Save As dialog carries the
## whole decision — no destination is remembered between runs.
func _on_process_selected() -> void:
	var index := _selected_index()
	if index < 0 or _operation == null:
		return
	var path := _sources[index]
	_save_source = path
	_save_dialog.current_dir = path.get_base_dir()
	_save_dialog.current_file = _output_name_for(path)
	_save_dialog.popup_centered_ratio(0.6)


func _on_save_file_chosen(destination: String) -> void:
	var source := _save_source
	_save_source = ""
	if source.is_empty():
		return
	# FILE_MODE_SAVE_FILE has already asked about replacing an existing file, so
	# this goes straight to writing.
	_pending_outputs = {source: destination}
	_write_pending_outputs()


## Processing the whole list asks for a folder instead: one dialog cannot name
## every output, so the suffix does the naming and this only picks where.
func _on_process_all() -> void:
	if _sources.is_empty() or _operation == null:
		return
	_output_dialog.current_dir = _sources[0].get_base_dir()
	_output_dialog.popup_centered_ratio(0.6)


func _on_output_dir_chosen(directory: String) -> void:
	if _operation == null:
		return

	# Sidecars travel with their image on the copy path, so they can be replaced by
	# a run too and belong in the warning below.
	var carries_sidecars := not _operation.transforms_pixels()

	var jobs := {}
	var existing := PackedStringArray()
	for path in _sources:
		var destination := directory.path_join(_output_name_for(path))
		jobs[path] = destination
		if FileAccess.file_exists(destination):
			existing.append(destination.get_file())
		if not carries_sidecars or not FileAccess.file_exists(SettingsIO.sidecar_path(path)):
			continue
		# Only ours is listed: one belonging to something else is refused rather
		# than replaced, so naming it here would promise a write that never comes.
		var destination_sidecar := SettingsIO.sidecar_path(destination)
		if SettingsIO.is_sidecar(destination_sidecar):
			existing.append(destination_sidecar.get_file())

	_pending_outputs = jobs
	if existing.is_empty():
		_write_pending_outputs()
		return

	# No native prompt on a folder pick, so this names what would be replaced.
	var preview := existing
	var trailer := ""
	if existing.size() > 8:
		preview = existing.slice(0, 8)
		trailer = "\n... and %d more" % (existing.size() - 8)
	_overwrite_dialog.dialog_text = "These files already exist and will be replaced:\n\n%s%s" % [
		"\n".join(preview), trailer,
	]
	_overwrite_dialog.popup_centered()


## Whether two paths name the same file on disk.
##
## Compared after globalising, because a source dragged from the FileSystem dock
## arrives as res:// while the destination comes back from a native dialog as an
## OS path — textually different, same file.
static func _is_same_file(a: String, b: String) -> bool:
	return ProjectSettings.globalize_path(a).simplify_path() 			== ProjectSettings.globalize_path(b).simplify_path()


## Asks before deleting anything, naming how many and which.
func _confirm_source_removal() -> void:
	if _pending_removals.is_empty():
		return

	var names := PackedStringArray()
	for source: String in _pending_removals:
		names.append(source.get_file())
	var listed := names
	var trailer := ""
	if names.size() > 8:
		listed = names.slice(0, 8)
		trailer = "\n... and %d more" % (names.size() - 8)

	_removal_dialog.dialog_text = "Are you sure you want to remove %d file(s)?\n\n%s%s\n\nEach copy is checked against its source first, and they go to the trash." % [
		names.size(), "\n".join(listed), trailer,
	]
	_removal_dialog.popup_centered()


## Proves every copy is byte-identical to its source, then trashes the sources.
##
## All or nothing on purpose. A partial delete after a partial verification is
## the worst outcome available here, so a single mismatch stops the lot.
func _verify_then_remove_sources() -> void:
	var candidates := _pending_removals
	_pending_removals = {}
	if candidates.is_empty():
		return

	# Two sources landing on one destination means the second overwrote the
	# first, and the first's original is now the only copy of it in existence.
	# Deleting on a checksum match would destroy it, because the survivor
	# matches its own source perfectly.
	var claimed := {}
	for source: String in candidates:
		var destination: String = candidates[source]
		if claimed.has(destination):
			_set_status("Nothing removed: %s and %s were both written to %s." % [
				String(claimed[destination]).get_file(), source.get_file(), destination.get_file(),
			])
			push_warning("Image Wrangler: refused to remove sources, two of them share an output name.")
			return
		claimed[destination] = source

	var unverified := PackedStringArray()
	for source: String in candidates:
		var destination: String = candidates[source]
		if not FileAccess.file_exists(destination) or not FileAccess.file_exists(source):
			unverified.append(source.get_file())
			continue
		var source_hash := FileAccess.get_sha256(source)
		if source_hash.is_empty() or source_hash != FileAccess.get_sha256(destination):
			unverified.append(source.get_file())

	if not unverified.is_empty():
		_set_status("Nothing removed: %d copy/copies did not match their source: %s" % [
			unverified.size(), ", ".join(unverified),
		])
		push_error("Image Wrangler: refused to remove sources, %s did not verify." % ", ".join(unverified))
		return

	var removed := 0
	var failures := PackedStringArray()
	# Only the ones that actually went get re-pointed below, so a file that
	# refused to move keeps its entry rather than being sent somewhere it isn't.
	var moved := {}
	for source: String in candidates:
		# Trash rather than unlink: the copy is verified, but the judgement that
		# the original is no longer wanted is the user's to reverse.
		if OS.move_to_trash(ProjectSettings.globalize_path(source)) == OK:
			removed += 1
			moved[source] = candidates[source]
		else:
			failures.append(source.get_file())

	_repoint_sources(moved)

	if failures.is_empty():
		_set_status("Removed %d original(s) to the trash; the Images list now points at the new files." % removed)
	else:
		_set_status("Removed %d original(s); %d could not be removed: %s" % [
			removed, failures.size(), ", ".join(failures),
		])
		push_error("Image Wrangler: could not remove %s" % ", ".join(failures))

	if Engine.is_editor_hint():
		EditorInterface.get_resource_filesystem().scan()


## Points the Images list at the files that replaced the ones just removed.
##
## Only reached when originals were actually deleted, which is the only time an
## entry goes stale — a rename that left its sources alone has nothing to fix.
## Left unrepointed, selecting one of those rows would fail to load and a second
## run would skip it.
##
## [param moved] carries the sidecars that travelled alongside their images as
## well. They match nothing here — the list and the settings map are both keyed by
## image path — so they pass through without needing to be filtered out.
func _repoint_sources(moved: Dictionary) -> void:
	if moved.is_empty():
		return

	# Tracked by path rather than index, because the rebuild below can drop a row.
	var selected := _current_path()
	var rebuilt := PackedStringArray()
	for source in _sources:
		var path: String = moved[source] if moved.has(source) else source
		# A destination already in the list would otherwise appear twice.
		if not rebuilt.has(path):
			rebuilt.append(path)
		if source == selected:
			selected = path
	_sources = rebuilt

	# Per-image settings describe the image, so they follow it to its new path —
	# in memory here, and on disk as the sidecar copied during the run.
	for source: String in moved:
		if not _settings_by_path.has(source):
			continue
		_settings_by_path[moved[source]] = _settings_by_path[source]
		_settings_by_path.erase(source)

	# A pending write against the old path would resolve to nothing now.
	if moved.has(_autosave_path):
		_autosave_path = moved[_autosave_path]

	_refresh_file_list()
	var index := _sources.find(selected)
	if index >= 0:
		_file_list.select(index)
		# Reloads the image from its new path, so the preview is not left showing
		# a file that no longer exists.
		_on_file_selected(index)
	_update_controls()


## Output file name for a source, which the operation decides: a rename has a
## whole scheme to apply, where an image operation just keeps the name.
func _output_name_for(path: String) -> String:
	if _operation == null:
		return path.get_file()
	var index := _sources.find(path)
	return _operation.get_output_name(path, _suffix_edit.text, maxi(index, 0))


## Sidecar paths that sources outside [param jobs] still read from.
##
## A sidecar is named from the basename alone, so [code]flower.png[/code] and
## [code]flower.jpg[/code] in one folder share [code]flower.json[/code]. Renaming
## only one of them must not carry that file away from the other, which would
## strip settings off an image this run never touched.
func _sidecars_held_outside(jobs: Dictionary) -> Dictionary:
	var held := {}
	for path in _sources:
		var source := String(path)
		if not jobs.has(source):
			held[SettingsIO.sidecar_path(source)] = true
	return held


## Copies a source's JSON counterpart alongside the copy of the image, and queues
## the original for the same removal check the image gets.
##
## The sidecar describes the image, so a rename that left it behind would strand
## every per-image setting the moment the dock was reopened — and, with Remove Old
## Files ticked, orphan it beside a file now in the trash. Whatever sits at the
## sidecar path travels, ours or not: [code]sprite.json[/code] beside
## [code]sprite.png[/code] is as likely to be an Aseprite atlas descriptor, and
## that belongs with the image just as much.
##
## Returns the empty String when the sidecar was carried or there was none, and
## the name of the file left behind otherwise. Never fails the image: by the time
## this runs the image is already written, and reporting a rename as failed
## because of its sidecar would be a lie about what is on disk.
func _carry_sidecar(source_path: String, destination: String, held: Dictionary) -> String:
	var source_sidecar := SettingsIO.sidecar_path(source_path)
	if not FileAccess.file_exists(source_sidecar):
		return ""

	# Both sidecars are named from their image's basename, so a rename that only
	# changed the extension's case leaves them the same file. Copying it onto
	# itself would truncate it.
	var destination_sidecar := SettingsIO.sidecar_path(destination)
	if _is_same_file(source_sidecar, destination_sidecar):
		return ""

	# The one case where refusing beats writing: a JSON already at the new name
	# that this addon did not write is somebody else's, and a rename is no licence
	# to destroy it. Same judgement [method SettingsIO.save_settings] makes.
	if FileAccess.file_exists(destination_sidecar) and not SettingsIO.is_sidecar(destination_sidecar):
		return destination_sidecar.get_file()
	if DirAccess.copy_absolute(source_sidecar, destination_sidecar) != OK:
		return source_sidecar.get_file()

	# Queued on the same terms as the image — checksummed against its copy, all or
	# nothing with the rest, and to the trash rather than straight out. Held back
	# only when a source this run is not processing still reads it; the copy has
	# been made either way.
	if _operation.removes_sources() and not held.has(source_sidecar):
		_pending_removals[source_sidecar] = destination_sidecar
	return ""


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

	var rewrites_pixels := _operation.transforms_pixels()
	# Worked out once for the whole run rather than per file, since it depends on
	# which sources the run leaves alone.
	var held_sidecars := _sidecars_held_outside(jobs)

	var written := 0
	var failures := PackedStringArray()
	var sidecar_failures := PackedStringArray()
	for source_path: String in jobs:
		var destination: String = jobs[source_path]
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

		if not rewrites_pixels:
			# Copied rather than decoded and re-encoded, so a format this addon
			# cannot write is not turned into a PNG wearing the wrong extension.
			if source_path == destination or DirAccess.copy_absolute(source_path, destination) != OK:
				failures.append(source_path.get_file())
				continue
			written += 1
			# Only a candidate, and only because this one copy landed. Whether any
			# of them are actually deleted is decided after the whole run.
			if _operation.removes_sources() and not _is_same_file(source_path, destination):
				_pending_removals[source_path] = destination
			# After the image, so a copy that failed leaves no sidecar stranded
			# beside a file that was never written.
			var stalled := _carry_sidecar(source_path, destination, held_sidecars)
			if not stalled.is_empty():
				sidecar_failures.append(stalled)
			continue

		var image := _load_image(source_path)
		if image == null:
			failures.append(source_path.get_file())
			continue
		var result := _operation.process_image(image)
		if result.save_png(destination) != OK:
			failures.append(source_path.get_file())
			continue
		written += 1

	_operation.set_settings(template)

	var report := "Wrote %d file(s)." % written
	if not failures.is_empty():
		report = "Wrote %d file(s), %d failed: %s" % [written, failures.size(), ", ".join(failures)]
		push_error("Image Wrangler: failed to process %s" % ", ".join(failures))
	# Appended rather than replacing the line: the image is what the run was for,
	# and a sidecar left behind must not read as a failed rename.
	if not sidecar_failures.is_empty():
		report += " %d settings file(s) stayed put: %s" % [sidecar_failures.size(), ", ".join(sidecar_failures)]
		push_warning("Image Wrangler: could not carry %s across; the original stays." % ", ".join(sidecar_failures))
	_set_status(report)

	if Engine.is_editor_hint():
		EditorInterface.get_resource_filesystem().scan()

	# Last, so the outcome of the run is already on screen when the question is
	# asked, and so a failed copy has had its chance to keep its source off the
	# list above.
	_confirm_source_removal()
