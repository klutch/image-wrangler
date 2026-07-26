@tool
extends RefCounted

## Eyedropper artwork for the Pick button on the list controls.
##
## Shared rather than duplicated. The Island Picker and the Remove Colors list
## carry the same button doing the same job, and the theme handling below is more
## than either wants to own a copy of.

## Loaded rather than preloaded so that a missing or not-yet-imported file leaves
## a plain button instead of breaking the addon at parse time.
const PICK_ICON_PATH := "res://addons/image_wrangler/ui/color-picker.png"

## Edge length the icon is resampled to, before editor DPI scaling.
const PICK_ICON_SIZE := 16


## Gives [param button] the eyedropper, built for the theme currently in force.
##
## Call from [code]NOTIFICATION_THEME_CHANGED[/code] rather than at construction:
## the editor theme is only reachable once the control is in the tree, and the
## artwork depends on it.
##
## The icon is what makes the pressed state readable — a [Button] tints its icon
## with the theme's pressed colour, which in the editor is the accent blue, so a
## picker that is armed looks armed. A button with no icon has nothing to tint.
static func apply_to(button: Button) -> void:
	var font_color := button.get_theme_color(&"font_color", &"Button")
	var icon := build(font_color.get_luminance() > 0.5)
	if icon != null:
		button.icon = icon
	elif button.has_theme_icon(&"ColorPick", &"EditorIcons"):
		# Only reachable before the editor has imported the PNG.
		button.icon = button.get_theme_icon(&"ColorPick", &"EditorIcons")


## The eyedropper at editor scale, inverted when [param invert] is set. Null when
## the artwork is missing or cannot be read.
##
## The artwork is two-tone line art — a dark outline with light interior detail —
## so on a dark editor theme the outline would sink into the panel and leave a
## shapeless blob. Inverting it there keeps the linework reading the same way
## round in both themes. Tinting cannot do this job: modulation multiplies, so it
## can darken the light parts but never lift the dark ones.
static func build(invert: bool) -> Texture2D:
	var source := load(PICK_ICON_PATH) as Texture2D
	if source == null:
		return null
	var image := source.get_image()
	if image == null:
		return null

	image = image.duplicate()
	if image.is_compressed():
		image.decompress()
	if image.get_format() != Image.FORMAT_RGBA8:
		image.convert(Image.FORMAT_RGBA8)

	var edge := PICK_ICON_SIZE
	if Engine.is_editor_hint():
		edge = maxi(roundi(PICK_ICON_SIZE * EditorInterface.get_editor_scale()), 1)
	if image.get_width() != edge or image.get_height() != edge:
		image.resize(edge, edge, Image.INTERPOLATE_LANCZOS)

	if invert:
		# Alpha is left alone, so the silhouette is unchanged.
		var data := image.get_data()
		for i in range(0, data.size(), 4):
			data[i] = 255 - data[i]
			data[i + 1] = 255 - data[i + 1]
			data[i + 2] = 255 - data[i + 2]
		image = Image.create_from_data(edge, edge, false, Image.FORMAT_RGBA8, data)

	return ImageTexture.create_from_image(image)
