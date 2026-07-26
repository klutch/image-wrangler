@tool
class_name IWOperation
extends RefCounted

## Base class for every image operation offered by Image Wrangler.
##
## An operation keeps its settings as ordinary properties and describes them
## through [method get_settings_schema]. The dock builds the settings form from
## that description, so adding a new tool never means touching the UI code:
## write a subclass, list its settings, register it in [code]iw_panel.gd[/code].

## Setting kinds the dock knows how to build a control for.
enum SettingType {
	BOOL,
	INT,
	FLOAT,
}


## Name shown in the tool dropdown.
func get_operation_name() -> String:
	return "Operation"


## One-line explanation shown underneath the tool dropdown.
func get_operation_description() -> String:
	return ""


## Appended to the source file name when writing the processed image.
func get_output_suffix() -> String:
	return "_out"


## Describes the editable settings, in display order.
##
## Recognised dictionary keys:
## [code]property[/code] (StringName, required), [code]label[/code] (String),
## [code]type[/code] ([enum SettingType]), [code]min[/code], [code]max[/code],
## [code]step[/code] (numeric settings only) and [code]tooltip[/code] (String).
func get_settings_schema() -> Array[Dictionary]:
	return []


## Runs the operation. [param source] is left untouched; a new image is returned.
func process_image(source: Image) -> Image:
	return source
