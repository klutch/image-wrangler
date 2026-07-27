@tool
class_name IWOperation
extends Resource

## Base class for every image operation offered by Image Wrangler.
##
## An operation is the algorithm; its tunables live in a separate settings
## Resource it points at, so the dock can swap in a different set per image
## without rebuilding anything. [method get_settings_schema] describes those
## tunables, and the dock builds the settings form from that description — so
## adding an operation never means touching the UI code: write a subclass, give
## it a settings Resource, list its settings, register it in
## [code]iw_panel.gd[/code].

## Setting kinds the dock knows how to build a control for.
enum SettingType {
	BOOL,
	INT,
	FLOAT,
	## A line of free text.
	STRING,
	## A fixed choice. The entry must carry an [code]options[/code] key listing
	## the labels; the property holds the chosen index.
	ENUM,
	## A single colour, alpha included. The property must hold a [Color].
	COLOR,
	## A list of image positions the user picks off the preview, each standing
	## for a region to act on. The property must hold an [IslandList].
	ISLAND_PICKER,
	## A list of colours, each with a tolerance of its own, sampled off the
	## preview or set by hand. The property must hold a [RemoveColorList].
	COLOR_LIST,
	## A list of polygons the user draws over the preview, each standing for a
	## region to act on. The property must hold a [PolygonRegionList].
	POLYGON_LIST,
}


## Name shown in the operation dropdown.
func get_operation_name() -> String:
	return "Operation"


## Stable identifier for this operation in saved files.
##
## Deliberately not [method get_operation_name]: that is user-facing prose and
## is exactly the kind of string that gets reworded, which would orphan every
## file keyed off it.
func get_operation_id() -> StringName:
	return &""


## Appended to the source file name when writing the processed image.
func get_output_suffix() -> String:
	return "_out"


## Whether processing rewrites the pixels.
##
## [code]false[/code] means the source file is copied to the destination
## byte-for-byte instead of being re-encoded, so an operation that only moves a
## file around cannot quietly turn a JPEG into a PNG behind the extension.
func transforms_pixels() -> bool:
	return true


## Whether these settings belong to one image or to the whole session.
##
## Per-image is the default, and the dock then keeps a set per source and saves
## it beside the file. An operation that describes the batch rather than any one
## image returns false: one set is held for as long as the dock is open, nothing
## is read or written to a sidecar, and every image is processed by it.
func settings_are_per_image() -> bool:
	return true


## Whether a source should be offered for deletion once its output is written.
##
## Only ever an offer: the dock confirms with the user and verifies the copy
## before acting on it. An operation that rewrites pixels has no business
## returning true, since its output is not a copy of anything.
func removes_sources() -> bool:
	return false


## Name to write [param source_path]'s result under, without any directory.
##
## [param suffix] is the dock's Output suffix, and [param index] is the source's
## position in the list, which is what lets a numbering scheme count. The default
## keeps the source's own name and takes the extension from
## [method transforms_pixels], since anything re-encoded is written as PNG.
func get_output_name(source_path: String, suffix: String, _index: int) -> String:
	var extension := "png" if transforms_pixels() else source_path.get_extension()
	return source_path.get_file().get_basename() + suffix + "." + extension


## One line describing what processing [param source_path] would produce, for the
## status bar. Empty when the result speaks for itself.
##
## An operation whose whole effect is on the file name has nothing to show in the
## preview, so this is how it stays inspectable before being run.
func describe_output(_source_path: String, _suffix: String, _index: int) -> String:
	return ""


## The Resource holding this operation's tunables.
##
## Every [code]property[/code] named in [method get_settings_schema], and the one
## named by [method get_key_color_property], resolves against this object rather
## than against the operation.
func get_settings() -> Resource:
	return null


## Points the operation at a different settings Resource. Implementations reject
## a Resource of the wrong type rather than storing it.
func set_settings(_settings: Resource) -> void:
	pass


## A settings Resource of this operation's type, at its defaults.
##
## Loading a saved file decodes into one of these, so a key the file is missing
## comes out at its default rather than at whatever happened to be dialled in.
func make_settings() -> Resource:
	return null


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
## Property names resolve against [method get_settings], not against the
## operation.
##
## Consecutive entries sharing a [code]group[/code] are boxed under a heading of
## that name; entries without one sit at the top level. Since grouping follows
## the order given here, an operation lists its settings grouped together.
##
## Every named group folds. Put [code]collapsed[/code] on the entry that opens
## one and it starts folded away — worth doing for anything but the group the
## user reaches for first, since a form of open groups is taller than the dock.
##
## [code]hidden_when[/code] names a [bool] property; the entry disappears from the
## form while that property is true. For a setting the other one replaces outright
## — a colour picked by hand against one worked out from the image — showing both
## would mean showing one that does nothing.
func get_settings_schema() -> Array[Dictionary]:
	return []


## Pulls every numeric setting back inside the range its schema declares.
##
## The schema is the only place ranges are written down, so it is also the only
## thing that can enforce them on values that did not come from the sliders. A
## hand-edited file carrying a tolerance of 50 would otherwise leave the setting
## at 50 while the slider clamps its *display* to 0.5 — the form and the
## processing silently disagreeing.
##
## [param settings] defaults to the operation's own, but a Resource loaded from a
## file is clamped before the operation is pointed at it, so the target has to be
## nameable.
func clamp_settings_to_schema(settings: Resource = null) -> void:
	if settings == null:
		settings = get_settings()
	if settings == null:
		return
	for entry in get_settings_schema():
		var property: StringName = entry.get("property", &"")
		var type: int = entry.get("type", SettingType.FLOAT)
		if property == &"":
			continue
		if type != SettingType.INT and type != SettingType.FLOAT:
			continue
		if not entry.has("min") and not entry.has("max"):
			continue
		var low: float = entry.get("min", -INF)
		var high: float = entry.get("max", INF)
		var value := clampf(float(settings.get(property)), low, high)
		settings.set(property, int(value) if type == SettingType.INT else value)


## Called with a fraction from 0 to 1 as [method process_image] advances, when
## something has asked to be told.
##
## Deliberately not exported and not part of the settings: it belongs to one run
## rather than to the image, and the dock sets it on a throwaway copy of the
## operation before handing that copy to a worker thread.
##
## An operation that reports nothing is not broken — it simply finishes without
## the bar having moved, which is the right answer for one that is instant.
var progress_reporter := Callable()


## Reports [param fraction] complete, if anyone is listening.
##
## Called from whichever thread is doing the work, so what is on the other end
## must expect that — the dock's reporter defers to the main thread rather than
## touching a control from the worker.
func report_progress(fraction: float) -> void:
	if progress_reporter.is_valid():
		progress_reporter.call(clampf(fraction, 0.0, 1.0))


## Runs the operation. [param source] is left untouched; a new image is returned.
##
## May be called on a worker thread, and for anything but a trivial image it will
## be. It must therefore touch nothing but its own settings and the image it was
## given — no dock state, no shared resources, nothing the editor might be reading
## at the same time.
func process_image(source: Image) -> Image:
	return source
