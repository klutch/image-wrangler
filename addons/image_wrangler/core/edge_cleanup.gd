@tool
class_name EdgeCleanup
extends IWStackOperation

## Two finishing jobs on the silhouette: restore the antialiasing, then outline it.
##
## [b]Restoring the antialiasing.[/b] Keying builds a matte while it decides what is
## background, which only helps where it is the one doing the cutting. An image that
## arrived aliased, or an edge a hard alpha clip flattened on the way past, has a
## solid pixel sitting straight against a clear one and nothing in between. This
## finds those and works the coverage back out of the same relation everything else
## rests on: a pixel on an antialiased edge is [code]C = a * F + (1 - a) * K[/code],
## so its distance from the background is [code]a[/code] times the subject's
## distance from the background, and dividing one by the other gives back
## [code]a[/code] with the unknown [code]F[/code] cancelled out.
##
## [b]Adjacency is the whole test[/b], and it is why this needs no settings. Only a
## pixel with the opposite extreme directly beside it is touched. A properly matted
## edge has half-covered pixels in between, so neither side can see the other and
## the edge is left exactly as it was — this cannot undo the good work of the edge
## band, so there is nothing to tune it down with. Hard by intent is left hard: a
## pixel in or against a drawn region is skipped, since a drawn cut is a straight
## line the user asked for rather than an edge that lost its antialiasing.
##
## [b]The outline.[/b] The inner stroke runs within the shape and touches only
## colour; the outer one runs outside it and has to bring alpha with it, since out
## there is nothing to colour. The outer one is composited underneath the subject,
## so the shape's own soft edge stays on top of it.
##
## The two belong together because the stroke needs the restoration: a stroke places
## its edges from the alpha's own sub-pixel contour, which a hard silhouette does
## not have — and giving a hard silhouette one is precisely what the restoration
## does.
##
## This is also the stage that settles the drawn regions into the alpha, because it
## has to: the stroke follows the silhouette that actually comes out, drawn shapes
## and all, rather than the one the keying alone would have given.

## What the restoration counts as fully solid and fully clear.
##
## Deliberately not 1.0 and 0.0 exactly: alpha arriving here has been through a
## division, possibly a guided filter and possibly a clip, and a pixel that is
## solid for every practical purpose can miss an exact comparison by a hair.
const _RESTORE_SOLID := 0.995
const _RESTORE_CLEAR := 0.005

## How many pixels the restoration steps inward looking for a subject colour. Two,
## because from a clear pixel the first step only reaches the boundary — which is
## the contaminated pixel being stepped past.
const _RESTORE_INWARD_MAX := 2

## How the automatic stroke colour is derived from what it runs alongside.
##
## A line is a darker, more saturated relative of the fill it borders — that is how
## it is picked by hand, and it is why the sampled colour cannot be used as it is:
## paint a colour over itself and there is nothing to see.
##
## Proportional rather than a fixed target, and with no threshold anywhere: a rule
## that switched from darkening to lightening below some luminance would flip the
## outline mid-stroke wherever a subject crossed it, which is worse than an outline
## that is merely subtle on something already dark.
const _AUTO_STROKE_DARKEN := 0.35
const _AUTO_STROKE_SATURATION := 1.3

## Blur radius for the sample, as a multiple of the stroke's own width and never
## below a few pixels.
##
## Wide on purpose. The question is "what colour is the subject around here", and a
## tight blur answers "what colour is this pixel" — which on any texture is noise,
## and would give a stroke that changed colour along its own length.
const _AUTO_STROKE_BLUR_SCALE := 4.0
const _AUTO_STROKE_BLUR_MIN := 6

## Feather on the stroke's inner edge at full softness, in pixels.
##
## Two, so that the middle of the slider lands on a one-pixel falloff — the width a
## real antialiased edge has, and what the stroke did before it was adjustable. That
## leaves the top half of the range for softer than natural, which is what the
## setting is mostly wanted for.
const _STROKE_MAX_FEATHER := 2.0

var settings: EdgeCleanupSettings


func _init() -> void:
    settings = EdgeCleanupSettings.new()


func get_operation_name() -> String:
    return "Edge Cleanup"


func get_operation_id() -> StringName:
    return &"edge_cleanup"


func get_settings() -> Resource:
    return settings


func set_settings(new_settings: Resource) -> void:
    var typed := new_settings as EdgeCleanupSettings
    if typed == null:
        push_error("Image Wrangler: EdgeCleanup was handed settings of the wrong type.")
        return
    settings = typed


func make_settings() -> Resource:
    return EdgeCleanupSettings.new()


func get_settings_schema() -> Array[Dictionary]:
    return [
        {
            "property": &"inner_stroke_width",
            "label": "Inner Stroke Width",
            "type": SettingType.FLOAT,
            "min": 0.0,
            "max": 5.0,
            "step": 0.25,
            "tooltip": "Width of the stroke drawn inside the silhouette, in pixels. 0 draws none.\n\nInside means it never extends the shape: it follows the holes in a subject as\nwell as its outer contour, and leaves the alpha channel exactly as it found\nit. Only color changes.\n\nAntialiased, so fractional widths are worth having — both its edges fall\nbetween pixels rather than stepping along them.",
        },
        {
            "property": &"outer_stroke_width",
            "label": "Outer Stroke Width",
            "type": SettingType.FLOAT,
            "min": 0.0,
            "max": 5.0,
            "step": 0.25,
            "tooltip": "Width of the stroke drawn outside the silhouette, in pixels. 0 draws none.\n\nUnlike the inner one this adds alpha — outside the shape there is nothing to\ncolor, so the stroke brings its own. The subject comes out this many pixels\nlarger than it went in.\n\nDrawn underneath the subject rather than over it, so the shape's own soft edge\nstays on top and the stroke shows through it. That is what an outer stroke\nlooks like, and what stops it eating the antialiasing it is there to sit\nbehind.",
        },
        {
            "property": &"stroke_softness",
            "label": "Stroke Softness",
            "type": SettingType.FLOAT,
            "min": 0.0,
            "max": 1.0,
            "step": 0.05,
            "tooltip": "How soft the stroke's inner edge is. 0 is a hard step with no antialiasing at\nall; 0.5 falls off over one pixel, which is what a real antialiased edge does;\n1 is the softest.\n\nOnly the inner edge. The outer one is the silhouette itself, and its softness\ncomes from the image's own alpha — feathering that would let the stroke bleed\npast the shape, which is the one thing an inside stroke must not do.\n\nA wide feather on a narrow stroke spreads it past its own width, since the\nfalloff is centred on the edge rather than tucked inside it.",
        },
        {
            "property": &"auto_stroke_color",
            "label": "Auto Stroke Color",
            "type": SettingType.BOOL,
            "tooltip": "Takes the stroke color from the image instead of picking one.\n\nEach stroke pixel samples a heavily blurred copy of the subject nearby and\nthen darkens it, so a green stem gets a dark green outline and a red petal a\ndeep red one — the way an illustrator picks a line color against a fill,\nrather than one flat color fighting everything it runs alongside.\n\nThe blur is weighted by alpha, so only real subject pixels count towards it.\nAn unweighted one would average in the empty space just outside the edge,\nwhich is exactly where every stroke pixel sits.\n\nDrawn at full strength. For a stroke that only tints, turn this off and pick a\ncolor with some transparency.",
        },
        {
            "property": &"stroke_color",
            "label": "Stroke Color",
            "hidden_when": &"auto_stroke_color",
            "type": SettingType.COLOR,
            "tooltip": "Color of the stroke. Its alpha is how strongly it is laid over what is already\nthere, not how transparent the result becomes — at half alpha the stroke tints\nthe art beneath it rather than covering it.",
        },
    ]


func stage_weight() -> float:
    return 0.30


## The stroke is drawn from alpha alone, and alpha exists whether or not anything
## was keyed. Only the restoration needs a key, and it stands down without one.
func needs_keying() -> bool:
    return false


func process_context(ctx: IWPipelineContext) -> void:
    ctx.stroke_color = settings.stroke_color

    # After any clip, because flattening an edge is one of the ways an edge comes to
    # need restoring, and before the regions below, which are hard on purpose.
    if ctx.has_keying and not ctx.coverage.is_empty():
        ctx.coverage = IWStageKernels.restore_edges(ctx)
    if not report_progress(0.4):
        return

    # No fold-in of the regions here. Each one landed where its own operation sits, so
    # the coverage already carries the silhouette the stroke has to follow — and doing it
    # again would put every region back over the stages between it and here.
    if not report_progress(0.5):
        return

    if not _wants_stroke():
        report_progress(1.0)
        return

    var alpha := ctx.final_alpha()
    var bands := _stroke_bands(ctx, alpha)
    var inner: PackedFloat32Array = bands[0]
    var outer: PackedFloat32Array = bands[1]
    ctx.stroke_inner = inner
    ctx.stroke_outer = outer
    if not report_progress(0.8):
        return
    ctx.stroke_colors = _auto_stroke_colors(ctx, alpha, inner, outer)
    report_progress(1.0)


## Whether either stroke would actually put paint down.
##
## Two zero widths mean no, and so does a fully transparent colour — but only when
## the colour is the one being used: an automatic stroke takes its colour from the
## image and never sees the picker, whose alpha would otherwise be a hidden switch
## for a hidden control.
func _wants_stroke() -> bool:
    if settings.inner_stroke_width <= 0.0 and settings.outer_stroke_width <= 0.0:
        return false
    return settings.auto_stroke_color or settings.stroke_color.a > 0.0


## How strongly the stroke is laid over what is under it.
##
## Full for an automatic colour, since its picker is hidden and there would be no
## way to have set anything else.
func _stroke_strength() -> float:
    return 1.0 if settings.auto_stroke_color else settings.stroke_color.a


## The two stroke bands, as [code][inner, outer][/code], each a strength per pixel
## and each empty when that stroke is not being drawn.
##
## [b]The silhouette sits between pixels, not on them.[/b] What matters is the
## contour where alpha crosses a half, and a pixel's own alpha says where that
## contour runs relative to its centre: coverage on a properly antialiased edge
## falls off over about one pixel, so a pixel of alpha [code]a[/code] is
## [code]a - 0.5[/code] from the contour, signed.
##
## Only the widths and the feather are decided here — what each band actually costs is
## a grassfire pass and a walk over the image, and both live in [IWStageKernels].
##
## [param alpha] is the alpha the image actually ends up with, 0 to 1 — not the
## coverage, which is only half of it.
func _stroke_bands(ctx: IWPipelineContext, alpha: PackedFloat32Array) -> Array:
    var none := PackedFloat32Array()
    var width := ctx.width
    var height := ctx.height
    var strength := _stroke_strength()
    var feather := clampf(settings.stroke_softness, 0.0, 1.0) * _STROKE_MAX_FEATHER

    var inner := none
    if settings.inner_stroke_width > 0.0:
        inner = IWStageKernels.inner_band(
                alpha, settings.inner_stroke_width, feather, strength, width, height)
    var outer := none
    if settings.outer_stroke_width > 0.0:
        outer = IWStageKernels.outer_band(
                alpha, settings.outer_stroke_width, feather, strength, width, height)
    return [inner, outer]


## A stroke colour per pixel, taken from the image, or an empty array when the
## colour is being picked by hand instead.
##
## The blur radius is worked out here because it is a function of the settings; the
## sampling and the darkening are in [method IWStageKernels.auto_stroke_colors].
func _auto_stroke_colors(ctx: IWPipelineContext, alpha: PackedFloat32Array, inner: PackedFloat32Array, outer: PackedFloat32Array) -> PackedFloat32Array:
    if not settings.auto_stroke_color:
        return PackedFloat32Array()
    var widest := maxf(settings.inner_stroke_width, settings.outer_stroke_width)
    var radius := maxi(ceili(widest * _AUTO_STROKE_BLUR_SCALE), _AUTO_STROKE_BLUR_MIN)
    return IWStageKernels.auto_stroke_colors(ctx, alpha, inner, outer, radius)
