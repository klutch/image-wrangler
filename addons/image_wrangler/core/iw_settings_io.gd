@tool
extends RefCounted

## Reads and writes the JSON sidecar that carries one image's settings.
##
## The sidecar sits beside the image with its extension replaced:
## [code]flower.png[/code] → [code]flower.json[/code]. It holds a block per
## operation, keyed by [method IWOperation.get_operation_id], so a second
## operation can start saving its own settings without breaking the format:
## [codeblock]
## {
##     "format": "image_wrangler",
##     "version": 1,
##     "operations": {
##         "remove_background": { "tolerance": 0.02, ... }
##     }
## }
## [/codeblock]
##
## Encoding is generic, driven by reflection over the settings Resource rather
## than hand-written per class. The addon's whole premise is that adding an
## operation needs no plumbing beyond the operation itself, and persistence has
## to follow the same rule as the UI does or that promise is only half true. It
## also means a value no schema entry ever names — [member
## RemoveColorEntry.color_tolerance] is one, sitting a level below the property
## the schema declares — persists anyway, and that a fourteenth tunable cannot be
## added and silently not saved.

const FORMAT := "image_wrangler"
const VERSION := 1


## Sidecar path for a source image: the same path with its extension replaced.
static func sidecar_path(source_path: String) -> String:
	return source_path.get_basename() + ".json"


## Whether the file at [param path] is a sidecar this addon wrote.
##
## False for a missing or unreadable file, and false for somebody else's JSON
## sitting where a sidecar would go. Callers use it before overwriting: the same
## judgement [method save_settings] makes, exposed for the rename path, which
## writes sidecars without going through it.
static func is_sidecar(path: String) -> bool:
	if not FileAccess.file_exists(path):
		return false
	return not _read_envelope(path).is_empty()


## Settings loaded from [param source_path]'s sidecar, or [code]null[/code] when
## there is nothing usable there.
##
## Null covers every failure — no file, unreadable, unparseable, written by
## another tool, a newer format version, or simply no block for this operation.
## The caller treats them all the same way, by falling back to defaults.
static func load_settings(source_path: String, operation: IWOperation) -> Resource:
	var path := sidecar_path(source_path)
	if not FileAccess.file_exists(path):
		return null

	var envelope := _read_envelope(path)
	if envelope.is_empty():
		return null
	if int(envelope.get("version", 0)) > VERSION:
		push_warning("Image Wrangler: %s was written by a newer version; ignoring it." % path.get_file())
		return null

	var operations: Dictionary = envelope.get("operations", {})
	var id := String(operation.get_operation_id())
	if not operations.has(id):
		return null

	var settings := operation.make_settings()
	if settings == null:
		return null
	apply_dict(settings, operations[id])
	return settings


## Writes [param settings] into [param source_path]'s sidecar under this
## operation's id, leaving any other operation's block alone.
##
## Returns [code]OK[/code], or a failure code. Refuses [code]ERR_FILE_CORRUPT[/code]
## when a file of that name already exists and was written by something else —
## [code]sprite.json[/code] beside [code]sprite.png[/code] is exactly what
## Aseprite names its atlas descriptor, and this addon works in precisely those
## folders.
static func save_settings(source_path: String, operation: IWOperation, settings: Resource) -> Error:
	var path := sidecar_path(source_path)
	var envelope := {}

	if FileAccess.file_exists(path):
		envelope = _read_envelope(path)
		if envelope.is_empty():
			# Present but not ours, or not parseable. Either way it is somebody
			# else's file and overwriting it would destroy their data.
			return ERR_FILE_CORRUPT

	var operations: Dictionary = envelope.get("operations", {})
	operations[String(operation.get_operation_id())] = to_dict(settings)
	envelope["format"] = FORMAT
	envelope["version"] = VERSION
	envelope["operations"] = operations

	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(JSON.stringify(envelope, "\t"))
	file.close()
	return OK


## Parsed envelope, or an empty Dictionary when the file is missing, unreadable,
## not JSON, or not one of ours.
static func _read_envelope(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var text := file.get_as_text()
	file.close()

	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return {}
	var envelope: Dictionary = parsed
	if String(envelope.get("format", "")) != FORMAT:
		return {}
	return envelope


# --- Codec --------------------------------------------------------------

## Every stored property of [param resource], encoded for JSON.
##
## The usage filter is what keeps this to the [code]@export[/code]ed script
## variables and out of [code]resource_path[/code], [code]resource_name[/code]
## and the rest of the Resource machinery.
static func to_dict(resource: Resource) -> Dictionary:
	var data := {}
	if resource == null:
		return data
	for property in resource.get_property_list():
		var usage: int = property.get("usage", 0)
		if not (usage & PROPERTY_USAGE_STORAGE):
			continue
		if not (usage & PROPERTY_USAGE_SCRIPT_VARIABLE):
			continue
		var name: String = property.get("name", "")
		if name.is_empty():
			continue
		data[name] = _encode(resource.get(name))
	return data


## Applies [param data] to [param resource], leaving anything it does not
## mention at whatever the resource already holds.
##
## Decoding is driven by the type of the value already sitting in the target,
## not by inspecting the JSON — which is what lets a typed array keep its element
## type without anyone parsing a property hint string. Keys the resource does not
## have are ignored, so a file from a newer version loads cleanly.
static func apply_dict(resource: Resource, data: Dictionary) -> void:
	if resource == null:
		return
	for property in resource.get_property_list():
		var usage: int = property.get("usage", 0)
		if not (usage & PROPERTY_USAGE_STORAGE):
			continue
		if not (usage & PROPERTY_USAGE_SCRIPT_VARIABLE):
			continue
		var name: String = property.get("name", "")
		if name.is_empty() or not data.has(name):
			continue
		var current: Variant = resource.get(name)
		var decoded: Variant = _decode(current, data[name])
		# _decode returns the target untouched when the stored value is the
		# wrong shape, so a single malformed entry costs that one setting rather
		# than the whole file.
		if decoded != null:
			resource.set(name, decoded)


static func _encode(value: Variant) -> Variant:
	match typeof(value):
		TYPE_COLOR:
			var color: Color = value
			return [color.r, color.g, color.b, color.a]
		TYPE_VECTOR2I:
			var point: Vector2i = value
			return [point.x, point.y]
		TYPE_ARRAY:
			var encoded := []
			for item in (value as Array):
				encoded.append(_encode(item))
			return encoded
		TYPE_OBJECT:
			return to_dict(value as Resource)
	return value


## The stored value converted to match [param target]'s type, or [param target]
## itself when the stored value cannot be read that way.
static func _decode(target: Variant, encoded: Variant) -> Variant:
	match typeof(target):
		TYPE_BOOL:
			return bool(encoded) if encoded is bool else target
		TYPE_INT:
			return int(encoded) if (encoded is float or encoded is int) else target
		TYPE_FLOAT:
			return float(encoded) if (encoded is float or encoded is int) else target
		TYPE_STRING:
			return String(encoded) if encoded is String else target
		TYPE_VECTOR2I:
			if not (encoded is Array) or (encoded as Array).size() < 2:
				return target
			var pair: Array = encoded
			return Vector2i(int(pair[0]), int(pair[1]))
		TYPE_COLOR:
			if not (encoded is Array) or (encoded as Array).size() < 4:
				return target
			var channels: Array = encoded
			return Color(float(channels[0]), float(channels[1]), float(channels[2]), float(channels[3]))
		TYPE_ARRAY:
			if not (encoded is Array):
				return target
			# duplicate() then clear() keeps the array's element type, so the
			# appends below stay typed without anyone reading a hint string.
			var out: Array = (target as Array).duplicate()
			out.clear()
			for item in (encoded as Array):
				# A fresh blank per item, not one hoisted out of the loop. For a
				# primitive that is the same value either way, but an object blank
				# is decoded into *in place* — reusing one would append the same
				# instance under every index and every entry would read alike.
				out.append(_decode(_blank_element(target as Array), item))
			return out
		TYPE_OBJECT:
			if not (encoded is Dictionary) or target == null:
				return target
			apply_dict(target as Resource, encoded as Dictionary)
			return target
	return target


## A zero value of [param array]'s element type, to decode each item against.
##
## For an array of Resources that means a real instance at its own defaults,
## built from the element script the array is typed to. Without it a stored entry
## would decode against [code]null[/code] and come back as null, so an
## [code]Array[RemoveColorEntry][/code] would survive a save as a row of nothing.
static func _blank_element(array: Array) -> Variant:
	if not array.is_typed():
		return null
	match array.get_typed_builtin():
		TYPE_BOOL: return false
		TYPE_INT: return 0
		TYPE_FLOAT: return 0.0
		TYPE_STRING: return ""
		TYPE_VECTOR2I: return Vector2i.ZERO
		TYPE_VECTOR2: return Vector2.ZERO
		TYPE_COLOR: return Color.WHITE
		TYPE_OBJECT:
			var element_script: Variant = array.get_typed_script()
			if element_script is Script:
				return (element_script as Script).new()
	return null


## Round-trips a settings Resource through the codec and reports any property
## that does not survive.
##
## The reflective path is the one part of this addon that cannot be reasoned
## about from source alone — it depends on property usage flags and typed-array
## behaviour. Called from [code]plugin.gd[/code] behind a constant so the first
## real run can turn it on and get an unmissable failure.
static func self_test(operation: IWOperation) -> bool:
	var original := operation.make_settings()
	var restored := operation.make_settings()
	if original == null or restored == null:
		push_error("Image Wrangler self-test: operation has no settings to test.")
		return false

	# Drive every property away from its default, so a value that fails to
	# round-trip cannot coincidentally match.
	for property in original.get_property_list():
		var usage: int = property.get("usage", 0)
		if not (usage & PROPERTY_USAGE_STORAGE) or not (usage & PROPERTY_USAGE_SCRIPT_VARIABLE):
			continue
		var name: String = property.get("name", "")
		match typeof(original.get(name)):
			TYPE_BOOL: original.set(name, not bool(original.get(name)))
			TYPE_INT: original.set(name, int(original.get(name)) + 7)
			TYPE_FLOAT: original.set(name, float(original.get(name)) + 0.125)
			TYPE_COLOR: original.set(name, Color(0.25, 0.5, 0.75, 1.0))
			TYPE_OBJECT:
				var nested := original.get(name)
				if nested is IslandList:
					(nested as IslandList).points = [Vector2i(128, 64), Vector2i(3, 900)]
				elif nested is RemoveColorList:
					# Two entries with different tolerances, because one would not
					# catch a decoder that returned the same instance for every
					# index — the failure an array of Resources invites.
					var colors := nested as RemoveColorList
					colors.clear()
					colors.add(Color(0.25, 0.5, 0.75), 0.011)
					colors.add(Color(0.9, 0.1, 0.2), 0.333)
				elif nested is BlackoutList:
					# The deepest nesting this codec has to survive: a typed array
					# of Vector2i inside a Resource inside a typed array of
					# Resources. Two polygons of different lengths, so a decoder
					# that reused one instance or one point array shows up as a
					# length mismatch rather than needing the values compared.
					var regions := nested as BlackoutList
					regions.clear()
					var triangle := regions.add()
					triangle.points = [Vector2i(3, 4), Vector2i(90, 12), Vector2i(40, 77)]
					triangle.color = Color(0.1, 0.9, 0.4, 1.0)
					var quad := regions.add()
					quad.points = [Vector2i(0, 0), Vector2i(8, 0), Vector2i(8, 8), Vector2i(0, 8)]
					quad.color = Color(0.8, 0.2, 0.6, 1.0)

	var round_tripped: Variant = JSON.parse_string(JSON.stringify(to_dict(original)))
	if not (round_tripped is Dictionary):
		push_error("Image Wrangler self-test: encoded settings did not survive JSON.")
		return false
	apply_dict(restored, round_tripped)

	var passed := true
	for property in original.get_property_list():
		var usage: int = property.get("usage", 0)
		if not (usage & PROPERTY_USAGE_STORAGE) or not (usage & PROPERTY_USAGE_SCRIPT_VARIABLE):
			continue
		var name: String = property.get("name", "")
		var before: Variant = original.get(name)
		var after: Variant = restored.get(name)
		if before is Resource:
			# Compared through the codec rather than by identity, since two
			# Resources holding identical values are never the same object. This
			# is the only comparison that reaches inside a nested list.
			var before_dict := JSON.stringify(to_dict(before as Resource))
			var after_dict := JSON.stringify(to_dict(after as Resource) if after is Resource else {})
			if before_dict != after_dict:
				push_error("Image Wrangler self-test: %s did not round-trip (%s vs %s)."
						% [name, before_dict, after_dict])
				passed = false
		elif before != after:
			push_error("Image Wrangler self-test: %s did not round-trip (%s vs %s)." % [name, before, after])
			passed = false
	return passed
