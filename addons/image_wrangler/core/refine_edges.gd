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
	return "Needs a Remove Background above it."


func process_context(ctx: IWPipelineContext) -> void:
	if not ctx.has_keying or ctx.coverage.is_empty():
		return

	var radius := settings.refine_radius
	var alpha_floor := settings.alpha_floor
	var alpha_ceiling := settings.alpha_ceiling

	if radius > 0 and not ctx.key_dist.is_empty():
		ctx.coverage = _guided_refine(ctx.coverage, ctx.key_dist, ctx.width, ctx.height, radius)
	if not report_progress(0.8):
		return
	if alpha_floor > 0.0 or alpha_ceiling < 1.0:
		_clip_alpha(ctx, alpha_floor, alpha_ceiling)
	report_progress(1.0)


## Stretches alpha so [param low] and below lands on clear and [param high] and
## above on solid. Edits the coverage in place.
func _clip_alpha(ctx: IWPipelineContext, low: float, high: float) -> void:
	# Letting the ceiling sit at or under the floor is a legitimate request for a
	# hard cutoff at that value, so it is honoured rather than rejected — just not
	# by dividing by zero.
	var span := maxf(high - low, IWPipelineContext.EPSILON)
	var coverage := ctx.coverage
	for i in coverage.size():
		coverage[i] = clampf((coverage[i] - low) / span, 0.0, 1.0)
	ctx.coverage = coverage


func _guided_refine(coverage: PackedFloat32Array, guide: PackedFloat32Array, width: int, height: int, radius: int) -> PackedFloat32Array:
	var pixel_count := width * height

	var guide_squared := PackedFloat32Array()
	guide_squared.resize(pixel_count)
	var guide_times_alpha := PackedFloat32Array()
	guide_times_alpha.resize(pixel_count)
	for i in pixel_count:
		guide_squared[i] = guide[i] * guide[i]
		guide_times_alpha[i] = guide[i] * coverage[i]

	var mean_guide := IWPixelMath.box_mean(guide, width, height, radius)
	var mean_alpha := IWPixelMath.box_mean(coverage, width, height, radius)
	var mean_guide_squared := IWPixelMath.box_mean(guide_squared, width, height, radius)
	var mean_guide_alpha := IWPixelMath.box_mean(guide_times_alpha, width, height, radius)

	var slope := PackedFloat32Array()
	slope.resize(pixel_count)
	var offset := PackedFloat32Array()
	offset.resize(pixel_count)
	for i in pixel_count:
		var variance := mean_guide_squared[i] - mean_guide[i] * mean_guide[i]
		var covariance := mean_guide_alpha[i] - mean_guide[i] * mean_alpha[i]
		# The regularisation is what decides how hard an edge has to be before
		# the filter follows it rather than smoothing across it.
		var a := covariance / (variance + _REFINE_EPSILON)
		slope[i] = a
		offset[i] = mean_alpha[i] - a * mean_guide[i]

	var mean_slope := IWPixelMath.box_mean(slope, width, height, radius)
	var mean_offset := IWPixelMath.box_mean(offset, width, height, radius)

	var refined := PackedFloat32Array()
	refined.resize(pixel_count)
	for i in pixel_count:
		refined[i] = clampf(mean_slope[i] * guide[i] + mean_offset[i], 0.0, 1.0)
	return refined
