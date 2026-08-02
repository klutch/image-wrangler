@tool
class_name Posterize
extends IWStackOperation

## Cuts an image down to a small set of colors.
##
## Even Steps puts each of red, green and blue on a fixed ladder, so a color lands in the
## same place whatever the picture is. Best Colors counts the colors actually in the image
## and picks the set that fits it, which holds a subtle picture together far better and
## gives a different answer for every image. One palette covers the whole image either way.
##
## Without dithering a gradient comes out as flat steps, which is the poster look and is
## usually the point. Floyd-Steinberg passes the leftover color on to the neighbours not
## yet reached, so the same gradient comes out as a fine speckle of two palette colors
## instead. [b]Alpha is not color and is never touched[/b], and a pixel that is not visible
## takes no part: it is neither recolored, nor counted toward the palette, nor given any
## leftover color to carry.
##
## [b]Put it below everything that keys.[/b] It rewrites the source pixels, and a key
## measures how far apart two colors are — flattening them first throws away the gradations
## a matte is recovered from. Below [SmoothColor] and [SmoothBlocks] as well, since
## posterizing first locks a JPEG's damage into the palette instead of repairing it.
##
## One placement costs real time rather than quality: [NeuralRemoveBackground] keeps its
## last answer against a hash of the source pixels, so a Posterize above it changes those
## pixels on every slider drag and forces the network to run again each time.

## The color this operation's marks are drawn in on the preview.
##
## Written out rather than worked out, and its own rather than the stack's, so it is the
## same color every session. A unit-length color, so no operation's marks arrive brighter
## than another's.
const TINT := Color(0.451, 0.560, 0.695)


var settings: PosterizeSettings


func _init() -> void:
    settings = PosterizeSettings.new()


func get_operation_name() -> String:
    return "Posterize"


func get_operation_id() -> StringName:
    return &"posterize"


func get_tint() -> Color:
    return TINT


func get_settings() -> Resource:
    return settings


func set_settings(new_settings: Resource) -> void:
    var typed := new_settings as PosterizeSettings
    if typed == null:
        push_error("Image Wrangler: Posterize was handed settings of the wrong type.")
        return
    settings = typed


func make_settings() -> Resource:
    return PosterizeSettings.new()


## Nothing, for the same reason [SmoothColor] names nothing: the pipeline takes its suffix
## from the first enabled stage that offers one, and a change of look should not be the one
## naming the file.
func get_output_suffix() -> String:
    return ""


func get_settings_schema() -> Array[Dictionary]:
    return [
        {
            "property": &"palette_mode",
            "label": "Palette",
            "type": SettingType.ENUM,
            "options": ["Even Steps", "Best Colors"],
            "tooltip": "Where the colors that survive come from.\n\nEven Steps puts each of red, green and blue on a fixed ladder, so the same\ncolor always lands in the same place whatever the picture is. Best Colors\ncounts the colors actually in the image and picks the set that fits it, which\nholds a subtle picture together far better but answers differently for every\nimage.",
        },
        {
            "property": &"levels",
            "label": "Levels",
            "type": SettingType.INT,
            "min": 2,
            "max": 32,
            "step": 1,
            "shown_when": &"palette_mode",
            "shown_values": [PosterizeSettings.Palette.EVEN_STEPS],
            "tooltip": "How many steps each of red, green and blue is allowed.\n\nTwo gives eight colors in all, three gives twenty-seven, and so on. Low\nnumbers are the hard poster look. High numbers only touch the gentlest\ngradients. Black stays black and white stays white at every setting.",
        },
        {
            "property": &"color_count",
            "label": "Colors",
            "type": SettingType.INT,
            "min": 2,
            "max": 256,
            "step": 1,
            "shown_when": &"palette_mode",
            "shown_values": [PosterizeSettings.Palette.BEST_COLORS],
            "tooltip": "How many colors the palette holds.\n\nOne palette covers the whole image, so this is the total rather than a count\nper channel. Sixteen is enough for most sprite art. Past about sixty-four the\nresult stops looking posterized and starts looking like the original.\n\nAn image with fewer colors than this simply gets fewer.",
        },
        {
            "property": &"dither_mode",
            "label": "Dither",
            "type": SettingType.ENUM,
            "options": ["None", "Floyd-Steinberg"],
            "tooltip": "What happens to the color a pixel could not have.\n\nNone drops it, which leaves clean flat areas and a visible step across every\ngradient. Floyd-Steinberg passes it on to the neighbours not yet reached, so a\ngradient comes out as a fine speckle of two palette colors instead of a step.\n\nTransparent pixels take no part either way, so nothing is smeared out past an\nobject's outline.",
        },
        {
            "property": &"dither_strength",
            "label": "Strength",
            "type": SettingType.FLOAT,
            "min": 0.0,
            "max": 1.0,
            "step": 0.05,
            "shown_when": &"dither_mode",
            "shown_values": [PosterizeSettings.Dither.FLOYD_STEINBERG],
            "tooltip": "How much of the leftover color is passed on.\n\nOne is the full pattern, which is right for a photograph and visibly noisy on\nflat cel-shaded art. Lower values leave some of the stepping in and lay down\nless speckle. Zero is the same as no dither at all.",
        },
    ]


## One pass to count the colors, a palette build that costs the same whatever the image
## size, and one pass to write.
func stage_weight() -> float:
    return 0.35


## It reads color, which every image has.
func needs_keying() -> bool:
    return false


func establishes_keying() -> bool:
    return false


## Never an error. Only a note that with nothing keyed out there is no background to leave
## out of the count, so it gets a share of the palette like anything else.
func prerequisite_note(ctx: IWPipelineContext) -> String:
    if settings.palette_mode != PosterizeSettings.Palette.BEST_COLORS:
        return ""
    if ctx == null or ctx.has_keying or not ctx.coverage.is_empty():
        return ""
    return "Picking the palette off the whole image, background included."


func process_context(ctx: IWPipelineContext) -> void:
    if not report_progress(0.05):
        return

    IWStageKernels.posterize(
            ctx,
            settings.palette_mode,
            settings.levels,
            settings.color_count,
            settings.dither_mode,
            settings.dither_strength)

    # The distance map is measured off the colors that were just replaced, so it has to be
    # built again rather than left describing pixels that are gone. Clearing it is not
    # enough: Refine Edges skips its filter entirely when it is empty.
    ctx.key_dist = PackedFloat32Array()
    ctx.ensure_key_dist()
    report_progress(1.0)
