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

## Whether this stage runs at all.
##
## Held here rather than as a setting, because it is a fact about the stack rather
## than about the operation — the dock draws it as a tick on the entry's header and
## saves it beside the settings rather than inside them. Switching a stage off
## keeps everything dialled into it, which deleting the entry would not.
var enabled := true

## Whether the dock draws this stage's settings folded away.
##
## Held here beside [member enabled] for the same reason: it is a fact about the entry
## rather than about the operation, and it is saved beside the settings rather than
## inside them.
var folded := false

## The colours a stage's marks are drawn in, ten hues evenly round the wheel.
##
## Written out rather than worked out, so a stage keeps the same colour from one run to the
## next: anything rolled per instance changes every time the dock builds a throwaway copy
## of the stack, which it does on every run.
##
## Each is a unit-length colour — the three channels squared add to one — so no hue arrives
## brighter than another and none of them is washed out. Ten is enough that a stack has to
## be ten deep before two share.
const TINTS: Array[Color] = [
    Color(1.000, 0.000, 0.000),
    Color(0.857, 0.514, 0.000),
    Color(0.625, 0.781, 0.000),
    Color(0.196, 0.981, 0.000),
    Color(0.000, 0.928, 0.371),
    Color(0.000, 0.707, 0.707),
    Color(0.000, 0.371, 0.928),
    Color(0.196, 0.000, 0.981),
    Color(0.625, 0.000, 0.781),
    Color(0.857, 0.000, 0.514),
]

## The colour this stage's marks are drawn in on the preview.
##
## Handed out by the stack when the entry is made, so it follows the stage as it is dragged
## up and down and stays put across a run. White until then, which is what every mark used
## to be — a stage running outside the dock has nothing to be told apart from.
var tint := Color.WHITE


## The colour belonging to the entry numbered [param uid].
static func tint_for(uid: int) -> Color:
    return TINTS[absi(uid) % TINTS.size()]

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
