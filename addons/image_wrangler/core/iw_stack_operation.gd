@tool
class_name IWStackOperation
extends IWStackItem

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


## Guards divisions where the denominator can legitimately collapse to zero.
##
## Lives here rather than on [IWPipelineContext], which is where it belongs and where it
## used to be, because that class is native now and [ClassDB] carries integer constants
## only — there is no way for a GDExtension to hand GDScript a float constant. The
## native side keeps its own [code]EPSILON[/code] with the same value, and the two are
## held in step by the parity harness rather than by the compiler.
##
## Every stage that reads this is one whose loops move to C++ in turn, at which point
## both copies collapse back into the one on the context.
const EPSILON := 0.0001

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


## Takes back whatever the run learned that the dock wants to show.
##
## [param from] is the throwaway copy of this stage that actually ran. The preview works
## on a private snapshot of the stack — see [method IWPipeline.process_image] and the
## dock's snapshot — so anything a stage observed about the image is recorded over
## there, on settings nothing is looking at. This is the one seam that brings such an
## observation home to the instance the UI is editing.
##
## [b]Observations only.[/b] A stage must not copy settings back through here. The copy
## carries the user's own values from the moment the run started, and by the time this
## is called they may be a slider-drag out of date — writing them back would undo an
## edit made while the run was going.
func absorb_run_report(_from: IWStackOperation) -> void:
    pass


## What this stage wants outlined on the preview, or nothing.
##
## For a stage that acts on regions it worked out for itself rather than on ones the user
## picked, so no control is holding them. Drawn dashed, since they are what a run found
## rather than what anyone chose.
func marked_regions() -> Array[Rect2i]:
    return []


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


## Whether running this stage on [param source] now would cost enough that the preview
## should wait for Refresh rather than follow a slider.
##
## The same question [method IWNormalLayer.is_expensive] answers on the packing side. A
## stage that holds enough to answer cheaply says false, and everything downstream of it
## goes back to being live — so expensive is a state, not a property of the class.
func is_expensive(_source: Image) -> bool:
    return false


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
