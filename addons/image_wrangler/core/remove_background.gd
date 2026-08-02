@tool
class_name RemoveBackground
extends IWStackOperation

## Removes a flat background colour while preserving the antialiased silhouette.
##
## The stage the rest of the stack is measured against: it establishes the keys,
## decides what is background, and produces the alpha every stage below it refines.
##
## Naively deleting every background-coloured pixel fails in one of two ways: a
## tight threshold keeps the half-blended edge pixels and leaves a fringe, a loose
## one eats the soft edge and leaves a jagged cutout. Neither is fixable by tuning
## the threshold, because the edge is not a mask — it is a matte.
##
## An antialiased pixel is a blend of the subject and the background:
## [codeblock]
##     C = a * F + (1 - a) * K
## [/codeblock]
## [code]C[/code] is the pixel we can see, [code]K[/code] the background colour,
## [code]F[/code] the subject colour hiding underneath, and [code]a[/code] the pixel
## coverage we want back as alpha.
##
## [b]Recovering coverage.[/b] Every channel is blended with the same [code]a[/code],
## so a pixel's largest per-channel distance from [code]K[/code] is exactly
## [code]a[/code] times the subject's own distance from [code]K[/code]. Divide one by
## the other and the unknown [code]F[/code] cancels out. The divisor comes from the
## nearest fully opaque pixel, so the estimate stays local and works whether the
## subject there is far from the key colour or barely off it. See
## [method IWPipelineContext.compute_coverage].
##
## [b]Finding the edge.[/b] Coverage alone cannot say whether a half-key-coloured
## pixel is a half-covered distant subject or a fully covered near-key one — the two
## are numerically identical. Colour thresholds cannot break that tie, so geometry
## does: antialiasing lives in a thin band hugging the background, so pixels are
## classified by their distance from the flood-filled background rather than by how
## close to the key they are. See [method _classify].
##
## [b]More than one background colour.[/b] Every entry in
## [member RemoveBackgroundSettings.remove_colors] is offered to the image border, so
## a frame with different backgrounds down opposite edges floods from both — but only
## where they meet the border, since that is the only place the flood may start while
## [member RemoveBackgroundSettings.contiguous] is set. A region enclosed by the
## subject is not reached by listing its colour, no matter how exactly it is listed;
## that is what [IslandPickerOp] is for.
##
## Each carries its own tolerance rather than sharing a global one, because the number
## that swallows a speckled JPEG background would eat into the subject beside a clean
## flat one. Every pixel therefore remembers which key claimed it, and its distance,
## its coverage and its decontamination are all measured against that key and that
## key's tolerance.
##
## [b]Killing the fringe.[/b] Correct alpha is only half the job. The RGB of a
## half-covered pixel is still half background, and that residue is what shows up as
## an outline once the image is composited. So the background is un-blended back out:
## [codeblock]
##     F = (C - (1 - a) * K) / a
## [/codeblock]
## Finally the subject colour is bled outwards into the fully transparent pixels.
## Their alpha is zero, but bilinear filtering and mipmaps still sample their RGB,
## which is how the background creeps back into an edge that looked clean in the
## file. Both are settings here and both are applied by [IWCompose], which is the
## only pass that writes colour [i]out[/i]. [Denoise] rewrites the colour going
## [i]in[/i]: above this stage it changes what gets keyed, and below it changes only
## what comes out, since the matte is settled by then.
##
## [b]Running it twice.[/b] A source pixel that arrives fully transparent is treated
## as open ground: it is already removed, so every flood crosses it, it grows no edge
## band, and it stays transparent whether or not the flood reached it. Without that, a
## second pass over this stack's own output would be fenced in by the first — the
## bleed above leaves subject colour in the RGB of every transparent pixel, so the
## border of a processed image reads as plant green or skin tone rather than as
## background, and the flood dies at the frame. Crossing a hole also re-offers the far
## side to the whole Remove Colors list, since transparency carries no key to inherit.
##
## [b]Getting into a nook too narrow to flood[/b] is [RemoveCrevice], which is a stage
## of its own below this one. The rule still runs inside this flood — a squeeze is
## measured against the tolerance of whichever entry the flood is carrying at that
## moment — but the terms come off the context rather than out of these settings, so
## whichever [RemoveCrevice] is above says what they are and every flood below obeys
## the same ones. A stack with none of them keys strictly within each colour's own
## tolerance.
##
## [b]What the other stages do.[/b] Tidying the alpha afterwards is [RefineEdges];
## picking a region by hand is [IslandPickerOp] or [PolygonEditOp]; restoring a hard
## edge and outlining the result is [EdgeCleanup]. Placing a second one of these below
## another adds its colours to the keys already registered rather than starting again.

## The colour this operation's marks are drawn in on the preview.
##
## Written out rather than worked out, and its own rather than the stack's, so it is the
## same colour every session. A unit-length colour, so no operation's marks arrive
## brighter than another's.
const TINT := Color(0.175, 0.707, 0.685)


## This operation's tunables. Swapped by the dock for the image on screen; see
## [RemoveBackgroundSettings].
var settings: RemoveBackgroundSettings


func _init() -> void:
    settings = RemoveBackgroundSettings.new()


func get_operation_name() -> String:
    return "Remove Background"


func get_operation_id() -> StringName:
    return &"remove_background"


func get_tint() -> Color:
    return TINT


func get_settings() -> Resource:
    return settings


func set_settings(new_settings: Resource) -> void:
    var typed := new_settings as RemoveBackgroundSettings
    if typed == null:
        push_error("Image Wrangler: RemoveBackground was handed settings of the wrong type.")
        return
    settings = typed


func make_settings() -> Resource:
    return RemoveBackgroundSettings.new()


func get_output_suffix() -> String:
    return "_nobg"


## The stage that establishes the keys, so nothing has to be keyed above it.
func needs_keying() -> bool:
    return false


## And the only one that does: the mask everything else builds on is made here.
func establishes_keying() -> bool:
    return true


## Most of a run by a distance: the flood and the nearest-subject map between them
## are the bulk of the work whatever else is in the stack.
func stage_weight() -> float:
    return 1.0


## Convenience entry point for code that just wants the default behaviour.
static func remove_background(source: Image, key := Color.WHITE) -> Image:
    var operation := RemoveBackground.new()
    operation.settings.remove_colors.set_only(key)
    return operation.process_image(source)


func process_context(ctx: IWPipelineContext) -> void:
    # What the final write needs to know. Owned here because the fringe removal and
    # the bleed are both about the background this stage identified.
    ctx.edge_width = maxi(ctx.edge_width, settings.edge_width)
    ctx.bleed_radius = maxi(ctx.bleed_radius, settings.bleed_radius)
    ctx.decontaminate = ctx.decontaminate or settings.decontaminate
    ctx.search_radius = maxi(
            maxi(ctx.bleed_radius, ctx.edge_width), IWPipelineContext.MIN_SEARCH_RADIUS)

    # Fractions along the way, for whatever is drawing the progress bar. Hand-set
    # rather than evenly spaced, because the passes are nothing like equal: the flood
    # and the nearest-subject map between them are most of the work, and a bar that
    # pretended otherwise would crawl and then leap.
    #
    # Each is also where the run gives up if it has been asked to. Between them it
    # cannot: a pass runs to its end once started, so how quickly a cancel takes hold
    # is however long the longest pass has left.
    if not report_progress(0.02):
        return

    var first_key := _build_keys(ctx)
    # No colours at all is a coherent request for no keying here — the stack may key
    # elsewhere, or not at all, and the regions and the stroke owe this stage nothing.
    if first_key < 0 and not ctx.has_keying:
        return
    if not report_progress(0.10):
        return

    # The classification is native. It is the single most expensive thing in the stack —
    # a border flood asking [method IWPipelineContext.flood_key_for] about four
    # neighbours of every background pixel, then a band grown from all of it.
    IWStageKernels.classify(ctx, settings.contiguous, settings.edge_width)
    if not report_progress(0.48):
        return

    # Folded into the mask rather than into the alpha at the end, so that everything
    # downstream treats these pixels correctly without being told about regions at
    # all: coverage reads them off the mask, the nearest-subject map picks its bleed
    # sources from it, and the final write follows.
    #
    # Applied after the classification for the same reason a cut is left hard — a band
    # already grown into the region is overwritten rather than left as a soft rim
    # inside a hard edge.
    ctx.apply_regions_to_mask()
    if not report_progress(0.62):
        return

    ctx.rebuild_nearest()
    if not report_progress(0.75):
        return

    # Alpha is settled for the whole image here, because the refinement below is a
    # neighbourhood operation and cannot run a pixel at a time.
    ctx.compute_coverage(ctx.all_indices())
    report_progress(1.0)


## Registers every colour of every enabled Remove Color as a key, and returns the index
## of the first one — or -1 when the list is empty or entirely switched off.
##
## An entry contributes as many keys as it holds colours, in its own order, which is
## what makes a group of colours picked in one sweep behave as the several rules it
## actually is. Grouping is how they are managed, not how they are matched.
##
## Appended to whatever is already registered, so a second one of these adds its
## colours instead of replacing the first's. The returned index is where this stage's
## own colours begin, which is what the border flood needs to know.
func _build_keys(ctx: IWPipelineContext) -> int:
    var first := -1
    if settings.remove_colors == null:
        return first
    for entry in settings.remove_colors.entries:
        if entry == null or not entry.enabled:
            continue
        for sample in entry.samples:
            if sample == null:
                continue
            var index := ctx.add_key(sample.color, sample.color_tolerance, false)
            if first < 0:
                first = index
    return first


func get_settings_schema() -> Array[Dictionary]:
    return [
        {
            "property": &"remove_colors",
            "type": SettingType.COLOR_LIST,
            "tooltip": "The background colors to key out, each with its own tolerance.
Drag a region over the preview to take every color in it, click for a
single pixel, or add one and set it by hand. An image with two flat
backgrounds needs two entries: one tolerance loose enough for a speckled
one would eat into the subject beside the clean one.

The flood spreads through every listed color, so entries work together —
a white plate around a green stem needs both listed, and taking white out
stops green working too, because nothing reaches it from the border.

Background walled off by opaque subject is never reached, whatever you
list. Add a Remove Colors stage for that instead.

Where two entries could both claim a pixel, the higher one wins.",
        },
        {
            "property": &"edge_width",
            "label": "Edge Width",
            "type": SettingType.INT,
            "min": 0,
            "max": 16,
            "step": 1,
            "tooltip": "How many pixels of antialiasing to rebuild around the subject.
2 suits ordinary antialiasing. Raise it for soft edges, glows or
drop shadows; set it to 0 for a hard-edged cutout.

Remove Crevice takes its width from here too. Remove Colors has its own —
whichever asks for more is what every edge in the image gets.",
        },
        {
            "property": &"contiguous",
            "label": "Only Outer Background",
            "type": SettingType.BOOL,
            "tooltip": "Flood fill inwards from the image border, so regions enclosed by the
subject (eyes, highlights, gaps in lettering) stay opaque.

This is also what makes Remove Colors border-only: an entry seeds the flood
where its color meets the border, and nowhere else. Turn it off and every
listed color is removed wherever it appears — enclosed regions included.",
        },
        {
            "property": &"decontaminate",
            "label": "Remove Color Fringe",
            "type": SettingType.BOOL,
            "tooltip": "Un-blends the background color out of partially transparent pixels.
This is what stops an outline appearing once the image is composited.",
        },
        {
            "property": &"bleed_radius",
            "label": "Color Bleed",
            "type": SettingType.INT,
            "min": 0,
            "max": 64,
            "step": 1,
            "tooltip": "Pushes subject color into fully transparent pixels, in pixels.
Texture filtering and mipmaps sample RGB even where alpha is zero, so
without this the background can bleed back into the edge on screen.",
        },
    ]


## Pulls every Remove Color tolerance into range, on top of what the schema clamps.
##
## The schema cannot reach these: it names properties on the settings Resource, and a
## tolerance lives two levels down, on a sample inside an entry. Without this a
## hand-edited file could
## carry 50 while the slider clamps its display to
## [constant RemoveColorEntry.MAX_TOLERANCE] — the form and the processing silently
## disagreeing, which is the exact failure the base method exists to prevent.
func clamp_settings_to_schema(target: Resource = null) -> void:
    super(target)
    if target == null:
        target = get_settings()
    var typed := target as RemoveBackgroundSettings
    if typed == null:
        return
    if typed.remove_colors != null:
        for entry in typed.remove_colors.entries:
            if entry == null:
                continue
            for sample in entry.samples:
                if sample != null:
                    sample.color_tolerance = clampf(sample.color_tolerance, 0.0, RemoveColorEntry.MAX_TOLERANCE)
