@tool
class_name IWStackOperation
extends IWOperation

## One stage in the dock's operation stack.
##
## An [IWOperation] answers "what should come out of this image". A stack
## operation answers something smaller: "what should this stage change about the
## run so far". It is handed an [IWPipelineContext] rather than an [Image], works
## on the buffers there, and leaves the writing to [IWCompose] once every stage has
## had its turn.
##
## It still inherits the settings half of the operation contract —
## [method IWOperation.get_settings_schema] and the rest — because that is what the
## dock's form builder and the sidecar codec reflect over, and a stage's settings
## are edited and saved exactly like any other operation's.
##
## [b]Stages are not independent filters.[/b] Several of them only mean anything
## downstream of something that established what the background is. Rather than
## fail, one of those stands down and says why: see [method needs_keying] and
## [method prerequisite_note]. That is what lets the stack be reordered freely
## without any order being an error.


## Whether this stage runs at all.
##
## Held here rather than as a setting, because it is a fact about the stack rather
## than about the operation — the dock draws it as a tick on the entry's header and
## saves it beside the settings rather than inside them. Switching a stage off
## keeps everything dialled into it, which deleting the entry would not.
var enabled := true

## The pipeline running this stage, or null when it is running on its own.
##
## Typed as the base rather than as [IWPipeline] deliberately: the only thing
## wanted from it is [member IWOperation.cancelled], and naming the subclass here
## would put the two scripts in a cycle.
var owner: IWOperation


## Does the stage's work, on the buffers in [param ctx].
##
## May be called on a worker thread, and for anything but a trivial image it will
## be. It must therefore touch nothing but its own settings and the context it was
## given.
##
## Returns nothing. A stage that decides it has nothing to do simply returns, and
## the run carries on with the context exactly as it found it — which is also what
## a stage does when [method report_progress] tells it to stop.
func process_context(_ctx: IWPipelineContext) -> void:
	pass


## Whether this stage needs a background to have been keyed out above it.
##
## [code]true[/code] for anything measuring against a key — which is most of them,
## since the coverage maths is a ratio of distances from the background. May be
## answered from the settings rather than from the class: a stage whose need
## depends on what has been dialled into it says so per instance.
func needs_keying() -> bool:
	return true


## Whether this stage is one that establishes the keys and the classification.
##
## Asked separately from [method needs_keying] rather than read as its opposite,
## because most stages do neither: geometry and the stroke work on their own
## without leaving a background behind for anything below to measure against.
func establishes_keying() -> bool:
	return false


## One line saying what this stage is waiting for, or empty when it is ready.
##
## Shown on the stack entry rather than pushed as a warning: a stage that cannot
## run yet is a normal state to be in halfway through building a stack, not a
## fault. [param ctx] is the run so far, or null when the dock is only asking what
## the stack looks like.
func prerequisite_note(_ctx: IWPipelineContext) -> String:
	return ""


## Roughly what share of a run this stage costs, relative to the others.
##
## Only ratios matter; the pipeline normalises them. This is what stops the overall
## progress bar crawling through the flood and then leaping through four cheap
## stages — the same reason the checkpoints inside a single stage are hand-set
## rather than evenly spaced.
func stage_weight() -> float:
	return 1.0


## Reports [param fraction] of [i]this stage[/i] complete, and returns whether to
## carry on.
##
## Overridden to also watch the pipeline's own cancel flag, since that is where a
## cancel arrives: the dock knows about the run, not about which stage happens to
## be in it.
func report_progress(fraction: float) -> bool:
	if progress_reporter.is_valid():
		progress_reporter.call(clampf(fraction, 0.0, 1.0))
	if cancelled:
		return false
	return owner == null or not owner.cancelled


## Runs this stage on its own and writes the result.
##
## The whole-operation contract, honoured for a single stage, so a stack operation
## is still usable from code that has one and just wants an image back.
func process_image(source: Image) -> Image:
	var ctx := IWPipelineContext.from_image(source)
	if ctx.pixel_count == 0:
		return source
	process_context(ctx)
	return IWCompose.compose(ctx)
