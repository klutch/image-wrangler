@tool
extends EditorPlugin

## Registers Image Wrangler as a main screen, alongside 2D, 3D and Script.
##
## A main screen rather than a bottom panel because the dock is mostly a
## viewport: three columns and an image to inspect at 800% want the whole editor
## area, not a strip along the bottom.

const PanelScript := preload("res://addons/image_wrangler/ui/iw_panel.gd")
const SettingsIO := preload("res://addons/image_wrangler/core/iw_settings_io.gd")

## Round-trips the settings codec on plugin enable and reports any property that
## does not survive.
##
## The codec is reflective — it walks property usage flags and relies on typed
## arrays keeping their element type through a duplicate. That is the one part of
## this addon that cannot be reasoned about from the source alone, so this exists
## to turn on when something looks wrong with saved settings. Off by default: it
## is a diagnostic, not a startup cost everyone should pay.
const RUN_SELF_TEST := false

var _panel: Control


func _enter_tree() -> void:
	if RUN_SELF_TEST:
		_run_self_test()

	_panel = PanelScript.new()
	_panel.name = "ImageWrangler"
	# The main screen is a VBoxContainer, and it only hands out space to children
	# that ask for it.
	_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# EditorPlugin used to wrap this as add_control_to_main_screen_container();
	# that pair was removed, and parenting to the main screen directly is what
	# replaced it.
	EditorInterface.get_editor_main_screen().add_child(_panel)
	# The editor drives visibility through _make_visible, and the screen it is
	# already showing wins on startup.
	_panel.hide()


## Round-trips every operation the dock offers, not just the first one.
##
## One operation proving the codec proves it for one shape of settings. Each
## operation brings its own — a list of colours, a list of polygons, a handful of
## numbers — and it is the shapes the reflective encoder can get wrong.
func _run_self_test() -> void:
	var passed := true
	for path: String in PanelScript.operation_scripts():
		var script: Script = load(path)
		if script == null:
			push_error("Image Wrangler self-test: could not load %s." % path)
			passed = false
			continue
		var operation: IWOperation = script.new()
		if operation.make_settings() == null:
			# Legitimate: an operation may hold no settings at all.
			continue
		if not SettingsIO.self_test(operation):
			passed = false
	if passed:
		print("Image Wrangler: settings codec self-test passed.")


func _exit_tree() -> void:
	if is_instance_valid(_panel):
		var main_screen := EditorInterface.get_editor_main_screen()
		if main_screen != null and _panel.get_parent() == main_screen:
			main_screen.remove_child(_panel)
		_panel.queue_free()
	_panel = null


## Asks the editor for a tab of our own next to 2D, 3D and Script.
func _has_main_screen() -> bool:
	return true


func _make_visible(visible: bool) -> void:
	if is_instance_valid(_panel):
		_panel.visible = visible


## The tab's label.
func _get_plugin_name() -> String:
	return "Image Wrangler"


## The tab's icon. Borrowed from the editor theme so it matches the weight and
## palette of the tabs either side of it; null is a valid answer and the editor
## falls back to a default, so a theme without the icon is not a failure.
func _get_plugin_icon() -> Texture2D:
	var base := EditorInterface.get_base_control()
	if base != null and base.has_theme_icon(&"ImageTexture", &"EditorIcons"):
		return base.get_theme_icon(&"ImageTexture", &"EditorIcons")
	return null
