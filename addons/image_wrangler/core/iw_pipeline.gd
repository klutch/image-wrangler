@tool
class_name IWPipeline
extends IWOperation

## A stack of [IWStackOperation]s, run in order, as one operation.
##
## This is what the dock actually processes with. It is an [IWOperation] so that
## everything built around one — the preview worker, the batch writer, the output
## naming, the cancel flag — carries on working without knowing a stack exists.
##
## The stages share one [IWPipelineContext] and the pixels are written once, at the
## end, by [IWCompose]. So a stage never sees a half-finished image: it sees the
## source colours plus whatever the stages above it decided about coverage, which
## is what lets the order be changed and still mean something.
##
## It holds no settings of its own. Each stage carries its own, and the sidecar
## stores them as an ordered list.

## The stages, in the order they run. The dock's stack, verbatim.
var stages: Array[IWStackOperation] = []

## Called as [code](index, count, fraction, name)[/code] each time the running
## stage reports, alongside the overall [member IWOperation.progress_reporter].
##
## Two reporters rather than one, because the two bars answer different questions:
## how far through the stack, and how far through the thing currently running. A
## single fraction cannot say both, and the second is what makes a slow stage
## identifiable rather than just slow.
var stage_progress_reporter := Callable()

## Where each stage's slice of the overall fraction starts and how wide it is,
## worked out from the stage weights once per run.
var _offsets := PackedFloat32Array()
var _spans := PackedFloat32Array()


func get_operation_name() -> String:
	return "Pipeline"


func get_operation_id() -> StringName:
	return &"pipeline"


## Takes the suffix from whichever stage most describes the result.
##
## The first stage that names one wins, so a stack led by Remove Background still
## writes [code]_nobg[/code] and the user's habit survives the restructuring.
func get_output_suffix() -> String:
	for stage in stages:
		if stage.enabled:
			var suffix := stage.get_output_suffix()
			if not suffix.is_empty():
				return suffix
	return "_out"


## The stack holds the settings, one set per stage; the pipeline holds none.
func get_settings() -> Resource:
	return null


func make_settings() -> Resource:
	return null


func get_settings_schema() -> Array[Dictionary]:
	return []


## Passed on to each stage against its own schema. Ranges are declared per
## operation, so this is the only place that can reach all of them.
func clamp_settings_to_schema(_settings: Resource = null) -> void:
	for stage in stages:
		stage.clamp_settings_to_schema()


## Whether any enabled stage established keys, once [param ctx] has been built.
## Used by the dock to decide what to tell the user about a stack that cannot key.
func has_keying_stage() -> bool:
	for stage in stages:
		if stage.enabled and stage.establishes_keying():
			return true
	return false


func process_image(source: Image) -> Image:
	var ctx := IWPipelineContext.from_image(source)
	# Nothing to process and nothing a stage could say about it. The source is the
	# honest answer, and every buffer below would need a special case for a zero
	# length otherwise.
	if ctx.pixel_count == 0:
		return source

	_plan_progress()
	if not report_progress(0.0):
		return source

	for i in stages.size():
		var stage := stages[i]
		if not stage.enabled:
			continue
		stage.owner = self
		stage.progress_reporter = _stage_reporter(i)
		stage.process_context(ctx)
		# Cleared rather than left pointing at this run, so a stage handed to
		# another pipeline cannot report into the one that finished with it.
		stage.progress_reporter = Callable()
		stage.owner = null
		if not report_progress(_offsets[i] + _spans[i]):
			return source

	report_progress(1.0)
	return IWCompose.compose(ctx)


## Splits the 0-to-1 overall fraction between the enabled stages by weight.
##
## A disabled stage takes no width at all rather than a zero-length slice it might
## still report into, so the bar covers only work that is actually going to happen.
func _plan_progress() -> void:
	var count := stages.size()
	_offsets = PackedFloat32Array()
	_offsets.resize(count)
	_spans = PackedFloat32Array()
	_spans.resize(count)

	var total := 0.0
	for stage in stages:
		if stage.enabled:
			total += maxf(stage.stage_weight(), 0.0)

	var cursor := 0.0
	for i in count:
		var stage := stages[i]
		var span := 0.0
		if stage.enabled and total > 0.0:
			span = maxf(stage.stage_weight(), 0.0) / total
		_offsets[i] = cursor
		_spans[i] = span
		cursor += span


## The reporter installed on stage [param index]: scales its own 0-to-1 into that
## stage's slice of the overall bar, and passes the unscaled value on for the
## second one.
func _stage_reporter(index: int) -> Callable:
	var offset := _offsets[index]
	var span := _spans[index]
	var count := stages.size()
	var name := stages[index].get_operation_name()
	return func(fraction: float) -> void:
		report_progress(offset + fraction * span)
		if stage_progress_reporter.is_valid():
			stage_progress_reporter.call(index, count, fraction, name)
