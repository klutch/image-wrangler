@tool
class_name SmoothHalos
extends IWStackOperation

## Flattens the faint ripples a JPEG leaves beside a hard edge.
##
## A sharp edge needs a lot of fine detail to describe and the encoder throws the finest
## of it away. What is left overshoots and undershoots as it crosses the edge, so the
## ground either side comes out rippled rather than flat.
##
## Only blocks holding an edge are touched, since the ripples cannot exist without one.
## Inside those, a pixel is averaged only with neighbours on its own side of the edge, so
## the average never reaches across the boundary however far Reach is set.
##
## [b]This makes the picture look better without making it easier to key.[/b] Measured on
## real sheets it leaves more background behind after keying, not less — smoothing
## spreads the error over more pixels rather than removing it, and a tolerance test
## counts pixels rather than error. Reach for it when the output image is the point. When
## a clean cut is the point, [SmoothColor] and [SmoothBlocks] are the two that help.
##
## Put it above [RemoveBackground]. It rewrites the source pixels, so anything that has
## already measured them would be measuring pixels that are gone.

var settings: SmoothHalosSettings


func _init() -> void:
    settings = SmoothHalosSettings.new()


func get_operation_name() -> String:
    return "Smooth Halos"


func get_operation_id() -> StringName:
    return &"smooth_halos"


func get_settings() -> Resource:
    return settings


func set_settings(new_settings: Resource) -> void:
    var typed := new_settings as SmoothHalosSettings
    if typed == null:
        push_error("Image Wrangler: SmoothHalos was handed settings of the wrong type.")
        return
    settings = typed


func make_settings() -> Resource:
    return SmoothHalosSettings.new()


## Nothing, for the same reason [Denoise] names nothing: the pipeline takes its suffix
## from the first enabled stage that offers one, and a repair stage should not be the
## one naming the file.
func get_output_suffix() -> String:
    return ""


func get_settings_schema() -> Array[Dictionary]:
    return [
        {
            "property": &"threshold",
            "label": "Threshold",
            "type": SettingType.FLOAT,
            "min": 0.0,
            "max": 1.0,
            "step": 0.01,
            "tooltip": "How much light-to-dark change a block needs before it counts as holding\nan edge.\n\nOnly blocks that hold one are touched, because that is the only place\nthese ripples come from. Lower reaches more of the image; higher confines\nthe repair to the strongest edges, which is where the ripple is worst.",
        },
        {
            "property": &"radius",
            "label": "Reach",
            "type": SettingType.INT,
            "min": 1,
            "max": 6,
            "step": 1,
            "tooltip": "How far the smoothing reaches, in pixels.\n\nThis is the setting that decides how much the stage can do at all. A\nripple is several pixels across, so a reach of 1 barely dents it. Raising\nthis is safe in the sense that matters — the average never crosses an\nedge whatever it is set to — but it costs more, since every pixel looks\nat every neighbour inside the reach.",
        },
        {
            "property": &"strength",
            "label": "Strength",
            "type": SettingType.FLOAT,
            "min": 0.0,
            "max": 1.0,
            "step": 0.05,
            "tooltip": "How much of the smoothed value is taken.\n\n0 changes nothing at all. 1 takes the smoothed value everywhere it is\nallowed to. Use it to dial back a reach that is doing too much rather\nthan lowering the reach itself, which changes what the filter can see.",
        },
    ]


## Two passes over the pixels, and most blocks are skipped outright — but the reach makes
## the middle one cost whatever it is set to.
func stage_weight() -> float:
    return 0.4


## It measures the image against itself, which needs no key.
func needs_keying() -> bool:
    return false


func establishes_keying() -> bool:
    return false


func process_context(ctx: IWPipelineContext) -> void:
    if settings.strength <= 0.0 or settings.threshold <= 0.0 or settings.radius <= 0:
        return
    if not report_progress(0.05):
        return

    IWStageKernels.smooth_halos(ctx, settings.threshold, settings.radius, settings.strength)

    # The distance map is measured off the colors that were just replaced, so it has to
    # be built again rather than left describing pixels that are gone. Clearing it is not
    # enough: Refine Edges skips its filter entirely when it is empty.
    ctx.key_dist = PackedFloat32Array()
    ctx.ensure_key_dist()
    report_progress(1.0)
