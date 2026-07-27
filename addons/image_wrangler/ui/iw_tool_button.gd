@tool
extends RefCounted

## Artwork and styling for the dock's arming buttons — the two Picks and Draw.
##
## Shared because all three are the same kind of control doing the same kind of
## thing: they claim the preview until they are switched off, and while one is
## armed a click on the image means something other than it usually does. That is
## worth being loud about, so they get more than a pressed border.

## Eyedropper artwork for the pick buttons. Loaded rather than preloaded so that a
## missing or not-yet-imported file leaves a plain button instead of breaking the
## addon at parse time.
const PICK_ICON_PATH := "res://addons/image_wrangler/ui/color-picker.png"

## Edge length the icon is resampled to, before editor DPI scaling.
const PICK_ICON_SIZE := 16

## Strength of the accent wash behind an armed button. Enough to read across the
## dock at a glance, short of the solid fill that would make it look disabled.
const ARMED_ALPHA := 0.55


## Gives [param button] the eyedropper, built for the theme currently in force.
##
## Call from [code]NOTIFICATION_THEME_CHANGED[/code] rather than at construction:
## the editor theme is only reachable once the control is in the tree, and the
## artwork depends on it.
static func apply_pick_icon(button: Button) -> void:
	var font_color := button.get_theme_color(&"font_color", &"Button")
	var icon := build_pick_icon(font_color.get_luminance() > 0.5)
	if icon != null:
		button.icon = icon
	elif button.has_theme_icon(&"ColorPick", &"EditorIcons"):
		# Only reachable before the editor has imported the PNG.
		button.icon = button.get_theme_icon(&"ColorPick", &"EditorIcons")


## Gives [param button] an editor icon with the colour taken out of it.
##
## Godot's node icons are colour-coded by category, so borrowing one leaves a
## button that looks permanently switched on. Tinting cannot fix that: modulation
## multiplies, so it can deepen a colour but never drain it. The pixels have to be
## rewritten, and then the theme is free to colour the result — including the
## pressed tint, so an armed button still goes blue and now that means something.
static func apply_theme_icon(button: Button, icon_name: StringName) -> void:
	if not button.has_theme_icon(icon_name, &"EditorIcons"):
		return
	var drained := drain(button.get_theme_icon(icon_name, &"EditorIcons"))
	if drained != null:
		button.icon = drained


## Paints [param button] with the editor accent while it is pressed.
##
## The default pressed look is a slightly different border, which is easy to miss
## on a small button in a busy dock — and missing it means clicking the image and
## getting a picked colour when a pan was wanted. A filled accent is unmissable.
##
## Call from [code]NOTIFICATION_THEME_CHANGED[/code], since the accent comes out
## of the theme.
static func style_armed(button: Button) -> void:
	# Asked for rather than assumed: reading a theme colour that is not there logs
	# an error, and outside the editor there is no Editor theme type at all.
	var accent := Color(0.4, 0.6, 1.0)
	if button.has_theme_color(&"accent_color", &"Editor"):
		accent = button.get_theme_color(&"accent_color", &"Editor")

	var armed := StyleBoxFlat.new()
	armed.bg_color = Color(accent, ARMED_ALPHA)
	armed.set_corner_radius_all(3)
	armed.set_content_margin_all(4)
	button.add_theme_stylebox_override(&"pressed", armed)

	# Hovering an armed button must not wash the accent away, or the state
	# disappears exactly while the pointer is on its way to switching it off.
	var hovered := armed.duplicate() as StyleBoxFlat
	hovered.bg_color = Color(accent, minf(ARMED_ALPHA + 0.15, 1.0))
	button.add_theme_stylebox_override(&"hover_pressed", hovered)

	# Against a filled accent the ordinary font colour can fall away, so both it
	# and the icon are pinned to something that holds up on it.
	var on_accent := Color.WHITE if accent.get_luminance() < 0.6 else Color.BLACK
	button.add_theme_color_override(&"font_pressed_color", on_accent)
	button.add_theme_color_override(&"font_hover_pressed_color", on_accent)
	button.add_theme_color_override(&"icon_pressed_color", on_accent)
	button.add_theme_color_override(&"icon_hover_pressed_color", on_accent)


## The eyedropper at editor scale, inverted when [param invert] is set. Null when
## the artwork is missing or cannot be read.
##
## The artwork is two-tone line art — a dark outline with light interior detail —
## so on a dark editor theme the outline would sink into the panel and leave a
## shapeless blob. Inverting it there keeps the linework reading the same way
## round in both themes.
static func build_pick_icon(invert: bool) -> Texture2D:
	var source := load(PICK_ICON_PATH) as Texture2D
	if source == null:
		return null
	var image := _readable(source)
	if image == null:
		return null

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


## [param source] with its colour taken out, leaving grey at the same lightness.
##
## Draining rather than flattening to a silhouette, so the shape keeps its
## interior lines.
static func drain(source: Texture2D) -> Texture2D:
	var image := _readable(source)
	if image == null:
		return null

	# Rec. 709 luma, so a saturated blue lands as dark as it looks rather than as
	# the mid grey a flat channel average would give.
	var data := image.get_data()
	for i in range(0, data.size(), 4):
		var luma := roundi(0.2126 * data[i] + 0.7152 * data[i + 1] + 0.0722 * data[i + 2])
		data[i] = luma
		data[i + 1] = luma
		data[i + 2] = luma
	# Alpha is left alone, so the silhouette is unchanged.
	return ImageTexture.create_from_image(
			Image.create_from_data(image.get_width(), image.get_height(), false, Image.FORMAT_RGBA8, data))


## An editable RGBA8 copy of [param source]'s image, or null when it has none.
static func _readable(source: Texture2D) -> Image:
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
	return image
