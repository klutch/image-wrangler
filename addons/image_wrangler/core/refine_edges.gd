@tool
class_name RefineEdges
extends IWStackOperation

## Tidies the alpha a keying stage produced, without softening the silhouette.
##
## Two jobs, in this order and for a reason.
##
## [b]The guided filter[/b] (He, Sun and Tang, ECCV 2010 — the "guided feathering"
## application) smooths the alpha while following the edges of a guide signal.
## Within each window the output is fitted as a linear function of the guide,
## [code]q = a * I + b[/code], with the coefficients chosen by least squares and
## then averaged over the windows covering each pixel. Where the guide is flat the
## fit degenerates to the local mean and the alpha is smoothed; where the guide has
## an edge the fit follows it, so the alpha snaps to that edge instead of blurring
## across it. Ragged crevices get tidied without the silhouette going soft.
##
## The guide is distance-from-key rather than the image's luminance. It is already
## computed by the keying stage above, and it is the better signal: its edges are
## exactly the background/subject boundary whatever the hue, so it separates a
## green screen from an equally bright subject, which luminance cannot.
##
## A flat region is preserved exactly, not approximately. Where the alpha is
## uniform the covariance term is zero, so [code]a = 0[/code] and [code]b[/code] is
## that value — a solid interior cannot be dragged off 1.0.
##
## [b]The alpha clip[/b] then stretches what is left so that everything at or below
## the floor lands on clear and everything at or above the ceiling on solid. Last,
## so it settles the filter's leftovers rather than being smoothed back into a haze
## by it.
##
## A radius of zero switches the filter off and leaves the clip, which is a real
## request: an edge that only needs its extremes pushed apart does not want
## smoothing first.

## The colour this operation's marks are drawn in on the preview.
##
## Written out rather than worked out, and its own rather than the stack's, so it is the
## same colour every session. A unit-length colour, so no operation's marks arrive
## brighter than another's.
const TINT := Color(0.197, 0.001, 0.980)


## Regularisation for the guided filter. Small enough that it follows any real
## silhouette rather than averaging across it, large enough that a flat region does
## not divide by near-zero variance.
##
## Measured rather than guessed: swept from 1e-3 to 1e-7 against known coverage,
## this is where the edge error bottoms out and the bleed into solid interiors
## disappears. Looser lets a low-contrast subject wash out — a near-white one lost
## 8% of its interior alpha at 1e-3 — and tighter changes nothing.
const _REFINE_EPSILON := 0.000001

var settings: RefineEdgesSettings


func _init() -> void:
    settings = RefineEdgesSettings.new()


func get_operation_name() -> String:
    return "Refine Edges"


func get_operation_id() -> StringName:
    return &"refine_edges"


func get_tint() -> Color:
    return TINT


func get_settings() -> Resource:
    return settings


func set_settings(new_settings: Resource) -> void:
    var typed := new_settings as RefineEdgesSettings
    if typed == null:
        push_error("Image Wrangler: RefineEdges was handed settings of the wrong type.")
        return
    settings = typed


func make_settings() -> Resource:
    return RefineEdgesSettings.new()


func get_settings_schema() -> Array[Dictionary]:
    return [
        {
            "property": &"refine_radius",
            "label": "Refine Radius",
            "type": SettingType.INT,
            "min": 0,
            "max": 16,
            "step": 1,
            "tooltip": "Window radius for the guided filter: roughly how far a ragged patch of alpha\nmay sit from a real edge and still be pulled onto it.\n\n0 switches the filter off and leaves the two clips below, which is worth\nhaving on its own — an edge that only needs its extremes pushed apart does\nnot want smoothing first.",
        },
        {
            "property": &"alpha_floor",
            "label": "Alpha Floor",
            "type": SettingType.FLOAT,
            "min": 0.0,
            "max": 1.0,
            "step": 0.01,
            "tooltip": "Alpha at or below this is forced fully clear.\nApplied after the filter, so it also clears the faint ghosts that leaves where\nit smooths leftover background instead of removing it. Around 0.5 does that;\nthe cost is that genuinely faint edge pixels go with them.",
        },
        {
            "property": &"alpha_ceiling",
            "label": "Alpha Ceiling",
            "type": SettingType.FLOAT,
            "min": 0.0,
            "max": 1.0,
            "step": 0.01,
            "tooltip": "Alpha at or above this is forced fully solid, with everything between the\nfloor and here stretched across the two. Bring it down towards the floor for\na harder cutoff, leave it at 1 for a soft one.",
        },
    ]


func stage_weight() -> float:
    return 0.30


## The filter's guide is the distance-from-key map, and the clip has nothing to
## clip until something has produced alpha.
func prerequisite_note(ctx: IWPipelineContext) -> String:
    if ctx != null and ctx.has_keying:
        return ""
    return "Needs a stage above it that removes the background."


func process_context(ctx: IWPipelineContext) -> void:
    if not ctx.has_keying or ctx.coverage.is_empty():
        return

    var radius := settings.refine_radius
    var alpha_floor := settings.alpha_floor
    var alpha_ceiling := settings.alpha_ceiling

    # Both passes are native; what stays here is the decision about whether each runs at
    # all, which is a question about the settings rather than about the pixels.
    if radius > 0 and not ctx.key_dist.is_empty():
        ctx.coverage = IWStageKernels.guided_refine(
                ctx.coverage, ctx.key_dist, ctx.width, ctx.height, radius)
        # The filter rebuilt the coverage knowing nothing about the drawn regions, so a
        # cut above would be smeared half shut. Folding them back in here keeps every
        # standing declaration where its own stage put it.
        ctx.apply_regions_to_coverage()
    if not report_progress(0.8):
        return
    if alpha_floor > 0.0 or alpha_ceiling < 1.0:
        IWStageKernels.clip_alpha(ctx, alpha_floor, alpha_ceiling)
    report_progress(1.0)
