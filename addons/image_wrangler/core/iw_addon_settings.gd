@tool
class_name IWAddonSettings
extends RefCounted

## The addon's own settings, held once for the editor rather than per image or per batch.
##
## Plain JSON in the project's user data, so it can be read and corrected by hand:
## [codeblock]
## {
##     "add_dir": "C:/art/flowers"
## }
## [/codeblock]
##
## [b]Only for how the dock behaves, never for what an image looks like.[/b] Anything that
## describes a picture belongs in that image's [code].iwc[/code] file, and anything that
## describes a batch belongs in its export config — both of those travel with the work, and
## this does not.
##
## Unknown keys are kept on write, so a file written by a later version does not lose
## whatever it knew that this one does not.

const PATH := "user://image_wrangler/settings.json"

## The folder the last successful Add came from. See [method last_add_dir].
const KEY_ADD_DIR := "add_dir"

## How the file is indented. Spaces rather than a tab, to match everything else here.
const INDENT := "    "

## Read once and kept, so opening a dialog costs nothing.
static var _data := {}
static var _loaded := false


## Everything in the file, read on the first call.
static func _all() -> Dictionary:
    if _loaded:
        return _data
    _loaded = true
    _data = {}
    if not FileAccess.file_exists(PATH):
        return _data
    var file := FileAccess.open(PATH, FileAccess.READ)
    if file == null:
        return _data
    var parsed: Variant = JSON.parse_string(file.get_as_text())
    # Anything that is not an object is somebody else's file, or a truncated write. Started
    # again rather than refused: nothing in here is worth stopping the dock over.
    if parsed is Dictionary:
        _data = parsed
    return _data


## What [param key] holds, or [param fallback] when it is missing.
static func get_value(key: String, fallback: Variant) -> Variant:
    return _all().get(key, fallback)


## Writes [param key] and saves. Returns whether the file was written.
static func set_value(key: String, value: Variant) -> bool:
    var data := _all()
    if data.get(key) == value:
        return true
    data[key] = value
    return _save()


static func _save() -> bool:
    # Inside user data rather than beside anything, so nothing else makes the folder.
    DirAccess.make_dir_recursive_absolute(PATH.get_base_dir())
    var file := FileAccess.open(PATH, FileAccess.WRITE)
    if file == null:
        push_warning("Image Wrangler: could not write %s." % PATH)
        return false
    file.store_string(JSON.stringify(_data, INDENT))
    return true


## The folder the last successful Add came from, or empty.
##
## Empty as well when the folder has since been moved or unmounted, so the caller can let the
## dialog open wherever it would have. The stored value is left alone in that case: a drive
## that is not plugged in today is not a wrong answer.
static func last_add_dir() -> String:
    var dir := String(get_value(KEY_ADD_DIR, ""))
    if dir.is_empty() or not DirAccess.dir_exists_absolute(dir):
        return ""
    return dir


static func set_last_add_dir(dir: String) -> void:
    if not dir.is_empty():
        set_value(KEY_ADD_DIR, dir)
