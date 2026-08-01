@tool
class_name TileSelector
extends IWStackOperation

## Holds back whole objects, by picking them off the preview.
##
## A packed sheet takes every object it finds. This is where you say which ones to send —
## the odd frame that came out wrong, or the six you actually wanted out of forty.
##
## [b]A tile here is a sprite there.[/b] The labelling is the one Packing lifts its sprites
## with, so anything held back is exactly one sprite that would have gone on the sheet.
##
## [b]Every tile gets an outline, not only the chosen ones.[/b] A tile this removes is no
## longer in the picture to be clicked, so the outline is what you click instead. Under
## Include Selected with nothing chosen yet the picture is empty and the outlines are all
## there is — which is the point.
##
## [b]A pick is a point, not a number.[/b] The tiles are worked out fresh on every run, and
## the labelling happens before anything is removed, so a point goes on landing on its tile
## however the stack above changes.

## What happens to the tiles that were picked.
enum TileSelection {
    ## Everything goes through. What the operation does before anything is chosen.
    ALL,
    ## The picked tiles are removed and the rest go through.
    EXCLUDE_SELECTED,
    ## Only the picked tiles go through and the rest are removed.
    INCLUDE_SELECTED,
}

const SELECTION_LABELS := ["All", "Exclude Selected", "Include Selected"]

var settings: TileSelectorSettings


func _init() -> void:
    settings = TileSelectorSettings.new()


func get_operation_name() -> String:
    return "Tile Selector"


func get_operation_id() -> StringName:
    return &"tile_selector"


func get_settings() -> Resource:
    return settings


func set_settings(new_settings: Resource) -> void:
    var typed := new_settings as TileSelectorSettings
    if typed == null:
        push_error("Image Wrangler: TileSelector was handed settings of the wrong type.")
        return
    settings = typed


func make_settings() -> Resource:
    return TileSelectorSettings.new()


## Nothing. Choosing what goes on a sheet should not be the thing naming the file.
func get_output_suffix() -> String:
    return ""


func get_settings_schema() -> Array[Dictionary]:
    return [
        {
            "property": &"mode",
            "label": "Mode",
            "type": SettingType.ENUM,
            "options": SELECTION_LABELS,
            "tooltip": "What happens to the tiles you pick.\n\nAll lets everything through, which is what this does before anything is\npicked. Exclude Selected removes the ones you picked. Include Selected keeps\nonly those and removes the rest.\n\nEvery tile is outlined whichever mode is in force, including the ones that\nhave been removed, so a tile is always there to be clicked again.",
        },
        {
            "property": &"picks",
            "type": SettingType.TILE_SELECTOR,
            "tooltip": "The tiles you picked. Press Pick, then click one on the preview or drag a\nrectangle over several.\n\nA tile is one whole object, the same one the packer would lift out as a\nsprite. Picking stores the spot you clicked rather than the tile's number, so\nit keeps hold of the same tile when something above this changes.",
        },
    ]


## One labelling pass and a walk over the image, neither depending on how many tiles there
## are.
func stage_weight() -> float:
    return 0.25


## Shape is not colour. It reads alpha and nothing else.
func needs_keying() -> bool:
    return false


func establishes_keying() -> bool:
    return false


func prerequisite_note(ctx: IWPipelineContext) -> String:
    if ctx == null or ctx.has_keying or not ctx.coverage.is_empty():
        return ""
    return "Reading the source's own transparency."


## Pulls the mode into range, which the schema cannot: it clamps numbers and this is a
## choice.
func clamp_settings_to_schema(target: Resource = null) -> void:
    super(target)
    if target == null:
        target = get_settings()
    var typed := target as TileSelectorSettings
    if typed != null:
        typed.mode = sanitise_mode(typed.mode)


static func sanitise_mode(mode: int) -> int:
    return mode if mode >= 0 and mode < SELECTION_LABELS.size() else TileSelection.ALL


## Brings home what the run found: every tile, and which one each pick landed on.
##
## Positional, and abandoned when the counts disagree, the same way the island picker's is.
func absorb_run_report(from: IWStackOperation) -> void:
    var source := from as TileSelector
    if source == null or source.settings == null or settings == null:
        return
    settings.found_bounds = source.settings.found_bounds.duplicate()
    var mine := settings.picks
    var theirs := source.settings.picks
    if mine.size() != theirs.size():
        return
    for i in mine.size():
        if mine[i] != null and theirs[i] != null:
            mine[i].tile = theirs[i].tile
            mine[i].bounds = theirs[i].bounds


## [b]No [method IWPipelineContext.compute_coverage][/b], for the reason
## [method RemoveLines.process_context] gives: every pixel whose coverage this changes it
## sets to zero itself, and re-deriving would flatten what the stages above worked out in a
## halo round everything removed.
func process_context(ctx: IWPipelineContext) -> void:
    if settings == null:
        return
    if not report_progress(0.05):
        return

    # Flattened out of the Resources they are kept in, the way every stage hands its lists
    # down: reading a TilePick per pixel is a property lookup the kernel cannot afford.
    var points := PackedInt32Array()
    for pick in settings.picks:
        if pick == null:
            continue
        points.append(pick.point.x)
        points.append(pick.point.y)

    var report := IWStageKernels.select_tiles(ctx, points, sanitise_mode(settings.mode))
    _absorb(report)
    if not report_progress(0.8):
        return

    if ctx.has_classification():
        ctx.apply_regions_to_mask()
        ctx.rebuild_nearest()
    report_progress(1.0)


## Unpacks what the kernel found onto the settings, so the dock can outline it.
func _absorb(report: Dictionary) -> void:
    var bounds: PackedInt32Array = report.get("bounds", PackedInt32Array())
    settings.found_bounds = []
    @warning_ignore("integer_division")
    var count := bounds.size() / 4
    for n in count:
        settings.found_bounds.append(Rect2i(
                bounds[n * 4], bounds[n * 4 + 1], bounds[n * 4 + 2], bounds[n * 4 + 3]))

    var picked: PackedInt32Array = report.get("picked", PackedInt32Array())
    for i in settings.picks.size():
        var pick: TilePick = settings.picks[i]
        if pick == null:
            continue
        pick.tile = picked[i] if i < picked.size() else -1
        pick.bounds = settings.found_bounds[pick.tile] if pick.tile >= 0 \
                and pick.tile < settings.found_bounds.size() else Rect2i()
