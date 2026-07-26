@tool
class_name IWOperation
extends RefCounted

## Base class for every image operation offered by Image Wrangler.
##
## An operation keeps its settings as ordinary properties and describes them
## through [method get_settings_schema]. The dock builds the settings form from
## that description, so adding a new operation never means touching the UI code:
## write a subclass, list its settings, register it in [code]iw_panel.gd[/code].

## Setting kinds the dock knows how to build a control for.
enum SettingType {
	BOOL,
	INT,
	FLOAT,
	## A list of image positions the user picks off the preview, each standing
	## for a region to act on. The property must be an
	## [code]Array[Vector2i][/code].
	ISLAND_PICKER,
}


## Name shown in the operation dropdown.
func get_operation_name() -> String:
	return "Operation"


## Appended to the source file name when writing the processed image.
func get_output_suffix() -> String:
	return "_out"


## Name of a [Color] property that is this operation's primary input, or an
## empty name when it has none.
##
## The dock gives it a swatch directly under the operation picker instead of
## burying it in the settings form, since it is the thing the operation is
## *about* rather than a parameter of how it works.
func get_key_color_property() -> StringName:
	return &""


## Describes the editable settings, in display order.
##
## Recognised dictionary keys:
## [code]property[/code] (StringName, required), [code]label[/code] (String),
## [code]type[/code] ([enum SettingType]), [code]min[/code], [code]max[/code],
## [code]step[/code] (numeric settings only), [code]tooltip[/code] (String) and
## [code]group[/code] (String).
##
## Consecutive entries sharing a [code]group[/code] are boxed under a heading of
## that name; entries without one sit at the top level. Since grouping follows
## the order given here, an operation lists its settings grouped together.
func get_settings_schema() -> Array[Dictionary]:
	return []


## Runs the operation. [param source] is left untouched; a new image is returned.
func process_image(source: Image) -> Image:
	return source
