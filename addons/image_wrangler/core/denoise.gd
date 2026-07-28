@tool
class_name Denoise
extends IWStackOperation

## Takes the sensor and compression noise off the source pixels, before anything reads
## them.
##
## Intel Open Image Denoise's RT filter, which is a trained model rather than a blur: it
## lifts grain and JPEG mosquito noise while leaving an edge where it found it. That
## property is the whole reason for reaching outside for this — a bilateral or a median
## smooths the same grain and takes the silhouette with it, which on a keying tool is
## the one thing that cannot be given away.
##
## [b]It is the only stage that rewrites [member IWPipelineContext.data].[/b] Every other
## stage writes coverage, a mask or a side buffer and leaves the source colours for
## [IWCompose] to read at the end. This one replaces them outright, which is coherent
## only because of where it is allowed to run.
##
## [b]So it stands down below anything that keys.[/b] Once a key has been registered the
## run is carrying maps built from the very pixels this would replace: [member
## IWPipelineContext.key_dist] measured against the first key, the [Color]s in [member
## IWPipelineContext.keys] sampled off the image, [member IWPipelineContext.nearest] and
## the coverage that reads it. Rewriting the colours underneath those does not invalidate
## them — [method IWPipelineContext.ensure_key_dist] is a no-op once the map exists, so
## nothing downstream would ever find out. A silent wrong answer is worse than no answer,
## so the stage does nothing and says why on its entry.
##
## [b]Why not simply force it first.[/b] The stack is reorderable on purpose and nothing
## polices an order. Standing down is what turns "above the keying" into a fact the dock
## can state, in the same way every other order-sensitive stage states its own.
##
## [b]It changes what the keyer sees, and that is the point.[/b] A flat ground with grain
## on it needs a tolerance wide enough to swallow the grain, and that width is what eats
## into the subject. Denoised first, the same ground keys at a fraction of it. The
## corollary is that tolerances dialled in with this stage on are not the same numbers
## with it off.

## Shown on the entry when the stage has been dragged below something that keys.
const STAND_DOWN_NOTE := "Runs before any keying. Move it above the Remove Background."

var settings: DenoiseSettings


func _init() -> void:
	settings = DenoiseSettings.new()


func get_operation_name() -> String:
	return "Denoise"


func get_operation_id() -> StringName:
	return &"denoise"


func get_settings() -> Resource:
	return settings


func set_settings(new_settings: Resource) -> void:
	var typed := new_settings as DenoiseSettings
	if typed == null:
		push_error("Image Wrangler: Denoise was handed settings of the wrong type.")
		return
	settings = typed


func make_settings() -> Resource:
	return DenoiseSettings.new()


## Nothing, deliberately.
##
## [method IWPipeline.get_output_suffix] takes the first enabled stage that names one,
## and this stage is designed to sit at the top of the stack — naming a suffix here would
## rename the output of every stack that has a Denoise in it. What comes out is still
## whatever the rest of the stack made of it, and should still be called that.
func get_output_suffix() -> String:
	return ""


func get_settings_schema() -> Array[Dictionary]:
	return [
		{
			"property": &"blend",
			"label": "Amount",
			"type": SettingType.FLOAT,
			"min": 0.0,
			"max": 1.0,
			"step": 0.01,
			"tooltip": "How much of the filtered result replaces the original.\n\nAt 1 the pixels below are entirely the filter's. Bring it down when the\nfilter is taking the tooth off drawn line art along with the grain — it is\ntrained on rendered images, and a drawn edge is not one.\n\nAt 0 the stage does nothing, which is also what switching the entry off\ndoes.",
		},
		{
			"property": &"quality",
			"label": "Quality",
			"type": SettingType.ENUM,
			"options": ["Fast", "Balanced", "High"],
			"tooltip": "What the filter trades against how long it takes.\n\nHigh by default, because this stage is one you went and added rather than\none that was already there. Drop to Fast while dialling the rest of the\nstack in on a large sheet, then put it back before processing the batch —\nthe result is not the same image.",
		},
	]


## Not cheap, and not the most expensive thing in a stack: one pass over the image
## against a trained model, where the classification below it is a flood plus a
## nearest-subject map.
func stage_weight() -> float:
	return 0.8


## Nothing above it, ever. This is the stage that produces the pixels a keyer measures.
func needs_keying() -> bool:
	return false


func establishes_keying() -> bool:
	return false


## The one stage that answers true. See the class docs.
func precedes_keying() -> bool:
	return true


## Only ever asked when the stage is somewhere it will not work.
##
## [param ctx] is the run so far, or null when the dock is only asking what the stack
## looks like — and with a null one the caller has already established that something
## above establishes keying, since that is the only reason it asks this stage at all.
## With a run in hand the buffers answer instead, which is the stricter test.
func prerequisite_note(ctx: IWPipelineContext) -> String:
	if ctx != null and not (ctx.has_keying or ctx.has_classification()):
		return ""
	return STAND_DOWN_NOTE


func process_context(ctx: IWPipelineContext) -> void:
	# Stands down rather than failing, and rather than trying to invalidate what it would
	# have invalidated. See the class docs: the maps built off these pixels are built once
	# and not rebuilt, so a rewrite underneath them would be silent.
	#
	# Both flags, not one. has_keying goes true on the first add_key, which catches an
	# island that registered a key without classifying; has_classification() catches a
	# mask built by something that registered no key of its own.
	if ctx.has_keying or ctx.has_classification():
		return
	# A coherent request for nothing, and worth catching here — the kernel would
	# otherwise spend a device creation and a whole filter pass arriving at the identity.
	if settings.blend <= 0.0:
		return
	if not report_progress(0.05):
		return

	# One call, and it cannot be interrupted — see the note in the kernel. The same
	# bargain every other single-pass stage makes.
	IWStageKernels.denoise(ctx, settings.quality, settings.blend)

	# Nothing to invalidate, and that is the design rather than an oversight. Reaching
	# here means nothing above keyed, so key_dist, keys, nearest, coverage and mask are
	# all still empty, and every one of them will be built below this out of the pixels
	# just written. Which is the whole reason the guard above is a stand-down and not a
	# rebuild.
	report_progress(1.0)
