@tool
extends EditorPlugin

## Registers the Image Wrangler dock in the editor's bottom panel.

const PanelScript := preload("res://addons/image_wrangler/ui/iw_panel.gd")

var _panel: Control


func _enter_tree() -> void:
	_panel = PanelScript.new()
	_panel.name = "ImageWrangler"
	add_control_to_bottom_panel(_panel, "Image Wrangler")


func _exit_tree() -> void:
	if is_instance_valid(_panel):
		remove_control_from_bottom_panel(_panel)
		_panel.queue_free()
	_panel = null


func _get_plugin_name() -> String:
	return "Image Wrangler"
