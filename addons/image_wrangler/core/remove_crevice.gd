@tool
class_name RemoveCrevice
extends IWStackOperation

## Squeezes the background into nooks whose opening is too narrow for it to have
## flooded on its own.
##
## The opening of a nook between two walls of a subject is often not background at all
## but the antialiasing of the two walls meeting over it — no pixel there is within any
## key's tolerance, so the flood stops at the mouth and the nook stays opaque. This
## crosses that neck: it is Canny's double threshold applied to region growing rather
## than to edge linking, and the rule itself lives in
## [method IWPipelineContext.flood_key_for], shared with every other flood in the run.
##
## [b]It is a pass rather than a rule inside one flood[/b], which is the second time
## this has been tried. The objection last time was that a squeeze has to be measured
## against the tolerance of whichever colour is doing the squeezing, and only the flood
## knew which one that was. It is not the flood that knows: [member
## IWPipelineContext.key_of] has recorded the claiming key per pixel since the
## classification was built, so seeding from the background as it already stands gives
## every seed the key it was claimed by and every squeeze happens on that colour's own
## terms. A pass afterwards can do exactly what the rule inside the flood did.
##
## [b]Two of these in a row on the same settings are one of them at twice the reach.[/b]
## Each pass gets a budget of [member RemoveCreviceSettings.crevice_reach] per path,
## spent and never refunded, and the next seeds from where the last one stopped — see
## [member IWPipelineContext.strayed] — so the budgets simply add up. Measured across a
## 2-pixel neck, a 3-pixel neck, and two 1-pixel necks with a pocket between them, two
## passes at a reach of one entered every one of them to exactly the pixel a single
## pass at a reach of two did.
##
## What two of them do express is [i]where[/i] and [i]on what terms[/i]: a tight pass
## before an [IslandPickerOp] and a looser one after it are two different rules at two
## different points in the stack, which one stage cannot be. Stacking two identical
## ones is a slower way of writing a larger number.
##
## [b]It declares the rule for everything below it.[/b] The reach and the tolerance go
## onto the context, so an [IslandPickerOp] under this squeezes on the same terms. That
## is deliberate: an island getting into a gap the pass beside it could not would be
## arbitrary. A stack with none of these in it has no crevice rule anywhere.
##
## [b]Everything it claims goes to the matte, not to the cut.[/b] A pixel beside
## background and inside its tolerance would have been flooded already, so anything
## this stage reaches it reached by straying, and straying is not proof of background.
## Marking it edge hands it to the usual coverage maths, which decides it by colour:
## background beyond a neck still measures as background and comes out, and subject
## this should never have got to measures as fully covered and keeps its alpha. That is
## what makes setting the reach generously cost work rather than pixels.

## The colour this operation's marks are drawn in on the preview.
##
## Written out rather than worked out, and its own rather than the stack's, so it is the
## same colour every session. A unit-length colour, so no operation's marks arrive
## brighter than another's.
const TINT := Color(0.642, 0.186, 0.744)


var settings: RemoveCreviceSettings


func _init() -> void:
    settings = RemoveCreviceSettings.new()


func get_operation_name() -> String:
    return "Remove Crevice"


func get_operation_id() -> StringName:
    return &"remove_crevice"


func get_tint() -> Color:
    return TINT


func get_settings() -> Resource:
    return settings


func set_settings(new_settings: Resource) -> void:
    var typed := new_settings as RemoveCreviceSettings
    if typed == null:
        push_error("Image Wrangler: RemoveCrevice was handed settings of the wrong type.")
        return
    settings = typed


func make_settings() -> Resource:
    return RemoveCreviceSettings.new()


func get_settings_schema() -> Array[Dictionary]:
    return [
        {
            "property": &"crevice_reach",
            "label": "Crevice Reach",
            "type": SettingType.INT,
            "min": 0,
            "max": 32,
            "step": 1,
            "tooltip": "How many near-background pixels one path may cross in total, so it needs\nto be at least as long as the constriction it has to get through.\n\nA total rather than a count that solid background resets, so the flood\ncannot stray, land on a stray highlight, and use that to buy its way\nfurther in.\n\nBudgets add up across stages: two of these in a row on the same settings\nreach exactly as far as one of them set to twice this, and cost more. Use\ntwo when you want them at different points in the stack or on different\ntolerances, not to reach further.",
        },
        {
            "property": &"crevice_tolerance",
            "label": "Crevice Tolerance",
            "type": SettingType.FLOAT,
            "min": 0.0,
            "max": 1.0,
            "step": 0.01,
            "tooltip": "How much further than its own tolerance a color may stray to get through a\nsqueeze. Added to that tolerance rather than replacing it, so a color keyed\ntightly stays keyed tightly.\n\nOne number for every color in the Remove Background above, because this is\nnot a description of a background — it is how far a flood may leave one\nbehind to get somewhere.",
        },
    ]


func stage_weight() -> float:
    return 0.35


## There has to be a background before there is anywhere to squeeze from.
func needs_keying() -> bool:
    return true


func prerequisite_note(ctx: IWPipelineContext) -> String:
    if ctx != null and ctx.has_classification():
        return ""
    return "Needs a Remove Background above it."


func process_context(ctx: IWPipelineContext) -> void:
    # Declared on the context before anything else, and assigned rather than widened:
    # this stage says what the rule is for everything below it, and a second one of
    # these further down says it again. Set even when the stage goes on to do nothing,
    # so switching the reach to zero switches the rule off for the floods below too.
    ctx.crevice_reach = settings.crevice_reach
    ctx.crevice_tolerance = settings.crevice_tolerance
    if settings.crevice_reach <= 0 or not ctx.has_classification():
        return
    if not report_progress(0.05):
        return

    # The squeeze itself is native: it is one 4-connected flood asking
    # [method IWPipelineContext.flood_key_for] about four neighbours of every pixel it
    # pops, which is the shape this whole extension exists for.
    var touched := IWStageKernels.squeeze(ctx)
    if touched.is_empty():
        report_progress(1.0)
        return
    if not report_progress(0.70):
        return

    # The regions are re-applied because this moved pixels out of subject and a drawn
    # or picked one has the last word over any flood; then the map naming the nearest
    # subject pixel is stale, and the coverage that reads it with it.
    ctx.apply_regions_to_mask()
    ctx.rebuild_nearest()
    ctx.compute_coverage(ctx.dilate(touched, ctx.search_radius))
    report_progress(1.0)
