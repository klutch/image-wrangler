@tool
class_name Rename
extends IWOperation

## Writes each source out under a new name, leaving its pixels untouched.
##
## The odd one out: every other operation here answers "what should this image
## look like", and this one answers "what should this file be called". It fits
## the same dock because the two questions are asked at the same moment — you are
## already looking at a list of images and about to write them somewhere — and
## because the answer still goes through the same Process buttons.
##
## Its settings are held once for the session rather than per image: a rename
## scheme describes the batch, and a counter that restarted for every file would
## mean nothing. Nothing is written to a sidecar.
##
## Nothing is renamed in place. Processing writes copies under the new names, to
## wherever the Process buttons ask for, and the sources are left alone. A rename
## tool that moved the originals would be a different and much less forgiving
## thing to point at a folder of art.
##
## Because it does not touch pixels, [method transforms_pixels] returns false and
## the dock copies each file byte-for-byte rather than re-encoding it — so a JPEG
## renamed by this stays a JPEG rather than becoming a PNG wearing a .jpg name.
##
## A JSON file sharing an image's name travels with it, and is removed on the same
## terms. That file is the image's settings, and a name is not worth losing them
## over.

var settings: RenameSettings


func _init() -> void:
	settings = RenameSettings.new()


func get_operation_name() -> String:
	return "Rename"


func get_operation_id() -> StringName:
	return &"rename"


func get_output_suffix() -> String:
	return ""


func settings_are_per_image() -> bool:
	return false


func transforms_pixels() -> bool:
	return false


func removes_sources() -> bool:
	return settings.remove_old_files


func get_settings() -> Resource:
	return settings


func set_settings(new_settings: Resource) -> void:
	var typed := new_settings as RenameSettings
	if typed == null:
		push_error("Image Wrangler: Rename was handed settings of the wrong type.")
		return
	settings = typed


func make_settings() -> Resource:
	return RenameSettings.new()


func get_settings_schema() -> Array[Dictionary]:
	return [
		{
			"property": &"base_name",
			"label": "Base Name",
			"group": "Name",
			"type": SettingType.STRING,
			"tooltip": "Replaces every file's name. Leave it empty and each file keeps its own,\nwhich is what makes Find and numbering useful across a mixed batch.",
		},
		{
			"property": &"find",
			"label": "Find",
			"group": "Name",
			"type": SettingType.STRING,
			"tooltip": "Text to look for in the name. Empty switches the replacement off, so an\nempty Replace With cannot quietly strip something.",
		},
		{
			"property": &"replace_with",
			"label": "Replace With",
			"group": "Name",
			"type": SettingType.STRING,
			"tooltip": "What Find becomes. Empty deletes the matched text.",
		},
		{
			"property": &"prefix",
			"label": "Prefix",
			"group": "Name",
			"type": SettingType.STRING,
			"tooltip": "Goes in front of the finished name, ahead of any number.",
		},
		{
			"property": &"start_at",
			"label": "Start At",
			"group": "Numbering",
			"type": SettingType.INT,
			"min": 0,
			"max": 100000,
			"step": 1,
			"tooltip": "Counter value for the first file in the list.",
		},
		{
			"property": &"step",
			"label": "Step",
			"group": "Numbering",
			"type": SettingType.INT,
			"min": 1,
			"max": 1000,
			"step": 1,
			"tooltip": "How much the counter moves per file.",
		},
		{
			"property": &"digits",
			"label": "Digits",
			"group": "Numbering",
			"type": SettingType.INT,
			"min": 1,
			"max": 8,
			"step": 1,
			"tooltip": "Zero-pads the counter to at least this many digits, so the names sort\ncorrectly in a file browser.",
		},
		{
			"property": &"separator",
			"label": "Separator",
			"group": "Numbering",
			"type": SettingType.STRING,
			"tooltip": "Text between the name and the counter.",
		},
		{
			"property": &"number_at",
			"label": "Number At",
			"group": "Numbering",
			"type": SettingType.ENUM,
			"options": ["End", "Start"],
			"tooltip": "Which end of the name the counter goes on.",
		},
		{
			"property": &"letter_case",
			"label": "Letter Case",
			"group": "Format",
			"type": SettingType.ENUM,
			"options": ["Unchanged", "lowercase", "UPPERCASE", "Title Case"],
			"tooltip": "Applied to the whole finished name, never to the extension.",
		},
		{
			"property": &"lowercase_extension",
			"label": "Lowercase Extension",
			"group": "Format",
			"type": SettingType.BOOL,
			"tooltip": "So a folder of mixed .PNG and .png files comes out consistent.",
		},
		{
			"property": &"remove_old_files",
			"label": "Remove Old Files",
			"group": "Format",
			"type": SettingType.BOOL,
			"tooltip": "Delete each source once its copy has been written.\nYou are asked first, every copy is checked against its source by checksum,\nand nothing is deleted unless all of them match. The originals go to the\nsystem trash, not straight out.\n\nA matching .json file counts as part of the image: it is copied to the new\nname and removed under the same checks.",
		},
	]


## The new name for one source.
##
## Composed in a fixed order, so the result is predictable rather than depending
## on which fields happen to be filled in:
## [codeblock]
##     base name (or the file's own)
##       -> find/replace
##       -> prefix, and the dock's Output suffix
##       -> number, at whichever end
##       -> letter case
##       -> extension
## [/codeblock]
func get_output_name(source_path: String, suffix: String, index: int) -> String:
	var name := settings.base_name if not settings.base_name.is_empty() else source_path.get_file().get_basename()

	# Guarded on find rather than on the pair, so clearing only Replace With is a
	# deliberate deletion and clearing Find is an off switch.
	if not settings.find.is_empty():
		name = name.replace(settings.find, settings.replace_with)

	name = settings.prefix + name + suffix

	# Always numbered: the counter is what makes a batch rename a batch rename.
	# Its value comes from the file's position in the list, so a single run and
	# a whole run agree on what any one file is called.
	var counter := settings.start_at + index * settings.step
	var digits := maxi(settings.digits, 1)
	var number := str(absi(counter)).pad_zeros(digits)
	if counter < 0:
		number = "-" + number
	if settings.number_at == RenameSettings.NumberAt.START:
		name = number + settings.separator + name
	else:
		name = name + settings.separator + number

	match settings.letter_case:
		RenameSettings.LetterCase.LOWER:
			name = name.to_lower()
		RenameSettings.LetterCase.UPPER:
			name = name.to_upper()
		RenameSettings.LetterCase.TITLE:
			name = name.capitalize()

	var extension := source_path.get_extension()
	if settings.lowercase_extension:
		extension = extension.to_lower()
	if extension.is_empty():
		return name
	return name + "." + extension


## Renaming has nothing to show in the preview — the pixels are unchanged — so
## the new name goes to the status bar instead.
func describe_output(source_path: String, suffix: String, index: int) -> String:
	var result := get_output_name(source_path, suffix, index)
	if result == source_path.get_file():
		return "%s — unchanged" % source_path.get_file()
	return "%s → %s" % [source_path.get_file(), result]
