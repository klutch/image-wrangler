@tool
class_name SmoothColor
extends IWStackOperation

## Flattens an image's color while leaving its brightness alone.
##
## A JPEG keeps color at half the width and half the height of the brightness and
## stretches it back out on the way in. Color ends up smeared sideways past every edge,
## so a flat background stops being flat next to a subject — which is what pushes those
## pixels outside a key's tolerance and leaves the halos the stages below have to chase.
##
## Every pixel takes the average color of its neighbours, but only counts a neighbour
## about as bright as it is. A background pixel next to a dark subject therefore averages
## with the background alone and lands back on the background's own color. Brightness is
## never touched, so nothing sharp is lost, and alpha is not color so it comes through
## untouched.
##
## Put it above [RemoveBackground]. It rewrites the source pixels, so anything that has
## already measured them would be measuring colors that are gone.

## The colour this operation's marks are drawn in on the preview.
##
## Written out rather than worked out, and its own rather than the stack's, so it is the
## same colour every session. A unit-length colour, so no operation's marks arrive
## brighter than another's.
const TINT := Color(0.566, 0.002, 0.824)


var settings: SmoothColorSettings


func _init() -> void:
    settings = SmoothColorSettings.new()


func get_operation_name() -> String:
    return "Smooth Color"


func get_operation_id() -> StringName:
    return &"smooth_color"


func get_tint() -> Color:
    return TINT


func get_settings() -> Resource:
    return settings


func set_settings(new_settings: Resource) -> void:
    var typed := new_settings as SmoothColorSettings
    if typed == null:
        push_error("Image Wrangler: SmoothColor was handed settings of the wrong type.")
        return
    settings = typed


func make_settings() -> Resource:
    return SmoothColorSettings.new()


## Nothing, for the same reason [Denoise] names nothing: the pipeline takes its suffix
## from the first enabled stage that offers one, and a repair stage should not be the
## one naming the file.
func get_output_suffix() -> String:
    return ""


func get_settings_schema() -> Array[Dictionary]:
    return [
        {
            "property": &"radius",
            "label": "Radius",
            "type": SettingType.INT,
            "min": 1,
            "max": 8,
            "step": 1,
            "tooltip": "How far the smoothing reaches, in pixels.\n\nA JPEG smears color about two pixels past an edge, so two is a sensible\nplace to start. Larger values flatten a blotchy background further and cost\nmore, since every pixel looks at every neighbour inside this reach.",
        },
        {
            "property": &"strength",
            "label": "Strength",
            "type": SettingType.FLOAT,
            "min": 0.0,
            "max": 1.0,
            "step": 0.05,
            "tooltip": "How much color change counts as noise rather than a real edge.\n\nLow values only flatten what is nearly flat already. High values smooth\nacross weaker edges too, which clears more but can pull color over a soft\nboundary.\n\nEdges are judged by brightness, not by color, so a colored edge with no\nchange in brightness is one this cannot see.",
        },
        {
            "property": &"amount",
            "label": "Amount",
            "type": SettingType.FLOAT,
            "min": 0.0,
            "max": 1.0,
            "step": 0.05,
            "tooltip": "How much of the smoothed color is mixed back over the original.\n\n0 changes nothing at all. 1 uses the smoothed color everywhere. Mixed in the\ncolor itself rather than afterwards, so a value in between lands on a color\nbetween the two rather than on a different brightness.",
        },
    ]


## Ten passes over the image, none of which cost more for a larger radius.
func stage_weight() -> float:
    return 0.5


## It measures brightness, which every image has.
func needs_keying() -> bool:
    return false


func establishes_keying() -> bool:
    return false


func process_context(ctx: IWPipelineContext) -> void:
    if settings.amount <= 0.0 or settings.radius <= 0:
        return
    if not report_progress(0.05):
        return

    IWStageKernels.smooth_color(ctx, settings.radius, settings.strength, settings.amount)

    # The distance map is measured off the colors that were just replaced, so it has to
    # be built again rather than left describing pixels that are gone. Clearing it is not
    # enough: Refine Edges skips its filter entirely when it is empty.
    ctx.key_dist = PackedFloat32Array()
    ctx.ensure_key_dist()
    report_progress(1.0)
