@tool
class_name IslandPickerOp
extends IWStackOperation

## Removes or protects one region at a time, picked off the preview.
##
## Everything a keying stage does works by colour, which cannot say "this patch,
## and only this patch". A region enclosed by the subject is not reached by listing
## its colour, no matter how exactly it is listed — the flood never gets to it. And
## a region a loose tolerance ate cannot be argued back by tightening the
## tolerance, because that would give the rest of the image back too.
##
## An island answers both. It floods outwards from every pixel the user picked,
## through anything within that pixel's own tolerance of the colour it landed on, and
## then either removes what it reached or forces it opaque. Subtract and Add are the
## same gesture pointed the other way, bounded by the same edges.
##
## [b]An island is a region picked, not a pixel picked.[/b] The user drags a rectangle
## and every pixel in it seeds a flood, which is what gets a patchy region out in one
## gesture — a speckled highlight is a dozen colours, and one seed only ever finds the
## one it landed on. The floods do not multiply the work: a pixel one seed claimed is
## never offered to the next, so the seeds inside a region a flood already took cost a
## test each. See [IslandEntry] for why they are grouped rather than listed flat.
##
## [b]Each pick brings its own tolerance.[/b] An island is pointed at one region
## of one image, and how clean that region is says nothing about the one beside it.
## Borrowing a number from a Remove Colors list would be worse still, since those
## entries describe colours an island by definition is not — or the flood would
## have reached it already.
##
## [b]Its keys are sampled, not stored.[/b] Each colour is read off the pixel its pick
## sits on at the moment it runs, so an island always removes exactly what was
## picked even if the stages above it changed what is there.
##
## [b]A Subtract island reaches as far as the border flood would.[/b] It spreads
## through anything the Remove Colors above it claim, not only through its own
## colour, so an island dropped on a white plate still crosses onto the green stem
## beside it. See [method IWPipelineContext.flood_key_for].

## The colour this operation's marks are drawn in on the preview.
##
## Written out rather than worked out, and its own rather than the stack's, so it is the
## same colour every session. A unit-length colour, so no operation's marks arrive
## brighter than another's.
const TINT := Color(0.000, 0.548, 0.836)


var settings: IslandPickerSettings


func _init() -> void:
    settings = IslandPickerSettings.new()


func get_operation_name() -> String:
    return "Island Picker"


func get_operation_id() -> StringName:
    return &"island_picker"


func get_tint() -> Color:
    return TINT


func get_settings() -> Resource:
    return settings


func set_settings(new_settings: Resource) -> void:
    var typed := new_settings as IslandPickerSettings
    if typed == null:
        push_error("Image Wrangler: IslandPickerOp was handed settings of the wrong type.")
        return
    settings = typed


func make_settings() -> Resource:
    return IslandPickerSettings.new()


func get_settings_schema() -> Array[Dictionary]:
    return [
        {
            "property": &"islands",
            "type": SettingType.ISLAND_PICKER,
            "tooltip": "Regions picked off the preview: drag a rectangle, or click for a single pixel.\n\nSubtract removes the region, which is how an enclosed background — an eye, a\ngap in lettering, a highlight — comes out, since no Remove Color ever reaches\nit. Add forces the region opaque, which is how a region a loose tolerance ate\ncomes back.\n\nEvery pixel you picked keys out its own color at its own tolerance, so an\nisland need not match anything in Remove Background.",
        },
    ]


## Pulls every pick's tolerance into range, on top of what the schema clamps.
##
## The schema cannot reach these: it names properties on the settings Resource, and a
## tolerance lives two levels down, on a pick inside an entry.
func clamp_settings_to_schema(target: Resource = null) -> void:
    super(target)
    if target == null:
        target = get_settings()
    var typed := target as IslandPickerSettings
    if typed == null or typed.islands == null:
        return
    for island in typed.islands.entries:
        if island == null:
            continue
        for pick in island.picks:
            if pick != null:
                pick.color_tolerance = clampf(pick.color_tolerance, 0.0, RemoveColorEntry.MAX_TOLERANCE)


func stage_weight() -> float:
    return 0.25


## An Add island needs nothing above it — it is its own flood and forces alpha
## directly. A Subtract one needs a classification to add background to, so the
## answer is about the islands picked rather than about the operation.
func needs_keying() -> bool:
    return settings.islands != null and _has(IWAlphaMode.Mode.SUBTRACT)


func prerequisite_note(ctx: IWPipelineContext) -> String:
    if settings.islands == null:
        return ""
    if not _has(IWAlphaMode.Mode.SUBTRACT):
        return ""
    if ctx != null and ctx.has_classification():
        return ""
    return "Subtract islands need a Remove Background above them."


func process_context(ctx: IWPipelineContext) -> void:
    if settings.islands == null:
        return

    var touched := PackedInt32Array()
    if ctx.has_classification():
        touched = _subtract(ctx)
    if not report_progress(0.5):
        return

    var protect_touched := _protect(ctx)
    touched.append_array(protect_touched)
    if touched.is_empty():
        report_progress(1.0)
        return
    if not report_progress(0.7):
        return

    # Both halves moved pixels out of subject, so the map naming the nearest one is
    # stale and the coverage that reads it with it.
    if ctx.has_classification():
        ctx.apply_regions_to_mask()
        ctx.rebuild_nearest()
        ctx.compute_coverage(ctx.dilate(touched, ctx.search_radius))
    # Here rather than at the end of the run. An Add used to be folded into the alpha
    # once everything had finished, which made it the last word over every stage below
    # it whatever order the user had put them in. Folded in where the operation sits, it
    # is an instruction like any other and the next stage down is free to overrule it.
    ctx.apply_regions_to_coverage()
    report_progress(1.0)


## Brings each island's flooded extent home from the copy that ran, so the preview can
## outline what the flood actually took rather than the pixel it was seeded from.
##
## Positional, and abandoned outright when the counts disagree: entry [code]i[/code]
## here is entry [code]i[/code] there only for as long as nobody adds or removes an
## island mid-run. An edit that changes the list also asks for another run, so the
## marks catch up on the next answer rather than being drawn against the wrong island
## in the meantime.
func absorb_run_report(from: IWStackOperation) -> void:
    var source := from as IslandPickerOp
    if source == null or source.settings == null:
        return
    if settings.islands == null or source.settings.islands == null:
        return
    var mine := settings.islands.entries
    var theirs := source.settings.islands.entries
    if mine.size() != theirs.size():
        return
    for i in mine.size():
        if mine[i] != null and theirs[i] != null:
            mine[i].flooded_bounds = theirs[i].flooded_bounds


func _has(mode: int) -> bool:
    for entry in settings.islands.entries:
        if entry != null and entry.enabled and entry.mode == mode:
            return true
    return false


## Floods every Subtract island into the background and mattes what it opened.
##
## Only the seed gathering happens here. The picks live on Resources — an entry, its
## mode and switch, then a list of picks with a point and a tolerance each — and reading
## one is a property lookup the flood cannot afford per pixel, so they are flattened
## into packed arrays first. That was already true when the flood was GDScript; the only
## thing that changed is where the flood is.
func _subtract(ctx: IWPipelineContext) -> PackedInt32Array:
    var width := ctx.width
    var height := ctx.height

    # Flattened out of the groups they are managed in, because the flood does not care
    # which rectangle a seed was drawn in: what matters is that a pixel one seed claimed
    # is never offered to the next, and that holds across entries exactly as it holds
    # within one. The same shape [method _protect] uses, for the same reason.
    var seeds := PackedInt32Array()
    var seed_tolerances := PackedFloat32Array()
    # Which entry each seed came from, parallel to the seeds themselves. Built here
    # because the flattening is the last place the grouping still exists, and the
    # preview wants what the flood took reported per group rather than per pixel.
    var seed_entries := PackedInt32Array()
    for e in settings.islands.entries.size():
        var entry: IslandEntry = settings.islands.entries[e]
        if entry == null or not entry.enabled or entry.mode != IWAlphaMode.Mode.SUBTRACT:
            continue
        for pick in entry.picks:
            if pick == null:
                continue
            var point := pick.point
            # Picks made on a different image, or on this one before it was cropped.
            if point.x < 0 or point.y < 0 or point.x >= width or point.y >= height:
                continue
            seeds.append(point.y * width + point.x)
            seed_tolerances.append(pick.color_tolerance)
            seed_entries.append(e)

    # Read before the flood, because what it adds from here on is exactly the keys the
    # attribution below has to account for.
    var key_base := ctx.keys.size()
    var touched := IWStageKernels.flood_islands(ctx, seeds, seed_tolerances)
    _record_subtract_bounds(ctx, touched, seeds, seed_entries, key_base)
    return touched


## Works out how much of the image each Subtract island took, and records it on the
## entry the user manages it as.
##
## Done afterwards, off what the flood wrote, rather than by flooding one entry at a
## time. The flood has to stay one call for every seed at once: a pixel one seed claimed
## is never offered to the next, and the budget deciding what merely squeezed through is
## shared across the lot — splitting it would change the result, which is the very bug
## the note on [code]weak_steps[/code] in the kernel records.
##
## What makes the attribution possible is that every seed which actually floods
## registers a key of its own, in seed order, and stamps it on each pixel it claims. A
## seed landing somewhere already taken registers nothing — which is why the keys are
## walked rather than indexed: they are consecutive, but the seeds owning them are not.
func _record_subtract_bounds(
        ctx: IWPipelineContext,
        touched: PackedInt32Array,
        seeds: PackedInt32Array,
        seed_entries: PackedInt32Array,
        key_base: int) -> void:
    if touched.is_empty():
        return
    var key_of := ctx.key_of

    # Key -> the entry that seeded it, as a flat table rather than a Dictionary: it is
    # read once per claimed pixel, and a hashed lookup there costs more than the whole
    # rest of this.
    var key_entries := PackedInt32Array()
    var next_key := key_base
    for s in seeds.size():
        # A seed whose own pixel does not carry the next key never flooded: the pixel
        # was already claimed, and what it carries is the key of whatever claimed it —
        # always one registered earlier, so it can never be mistaken for this one.
        if key_of[seeds[s]] != next_key:
            continue
        key_entries.append(seed_entries[s])
        next_key += 1
    if key_entries.is_empty():
        return

    var entry_count := settings.islands.entries.size()
    var min_x := PackedInt32Array()
    min_x.resize(entry_count)
    min_x.fill(0x7fffffff)
    var min_y := min_x.duplicate()
    var max_x := PackedInt32Array()
    max_x.resize(entry_count)
    max_x.fill(-1)
    var max_y := max_x.duplicate()

    # One pass over what the flood took. This includes the matte band grown off it,
    # whose pixels carry the claiming island's key too — deliberately kept, since the
    # band is part of what the island changed.
    var width := ctx.width
    for t in touched.size():
        var index := touched[t]
        var key := key_of[index]
        if key < key_base or key >= next_key:
            continue
        var e := key_entries[key - key_base]
        var x := index % width
        @warning_ignore("integer_division")
        var y := index / width
        if x < min_x[e]:
            min_x[e] = x
        if x > max_x[e]:
            max_x[e] = x
        if y < min_y[e]:
            min_y[e] = y
        if y > max_y[e]:
            max_y[e] = y

    for e in entry_count:
        if max_x[e] < 0:
            continue
        var entry: IslandEntry = settings.islands.entries[e]
        if entry != null:
            entry.flooded_bounds = Rect2i(
                min_x[e], min_y[e], max_x[e] - min_x[e] + 1, max_y[e] - min_y[e] + 1)


## Floods every Add island and marks what it protects.
##
## Its own flood rather than a mode inside the classification, because the two
## cannot share a queue. A background flood claims pixels once and never revisits
## them; this one has to be free to reach pixels that flood already took, since
## those are precisely the ones worth protecting.
func _protect(ctx: IWPipelineContext) -> PackedInt32Array:
    var width := ctx.width
    var height := ctx.height

    # One call per entry rather than one for the lot, which the Subtract side cannot do
    # and this side can: the only thing carried between seeds here is [code]protect[/code]
    # itself, and that lives on the context and survives the call. Entries are still
    # visited in order and seeds within them in order, so a pixel an earlier seed
    # protected is skipped exactly as it was — the flood is handed the same seeds in the
    # same sequence and finds the same buffer under it. What it buys is attribution:
    # each call comes back with that entry's own pixels rather than everyone's.
    var touched := PackedInt32Array()
    for entry: IslandEntry in settings.islands.entries:
        if entry == null or not entry.enabled or entry.mode != IWAlphaMode.Mode.ADD:
            continue

        # Float64 here where the Subtract side collects float32, because that is what each
        # side always did and the difference reaches the last bit of every tolerance
        # comparison in the flood below.
        var seeds := PackedInt32Array()
        var seed_tolerances := PackedFloat64Array()
        for pick in entry.picks:
            if pick == null:
                continue
            var point := pick.point
            if point.x < 0 or point.y < 0 or point.x >= width or point.y >= height:
                continue
            seeds.append(point.y * width + point.x)
            seed_tolerances.append(pick.color_tolerance)
        if seeds.is_empty():
            continue

        var own := IWStageKernels.flood_protect(ctx, seeds, seed_tolerances)
        _record_bounds(entry, own, width)
        touched.append_array(own)

    return touched


## Records the extent of [param indices] on [param entry].
##
## The Add side needs no attribution pass: its flood is asked for one entry at a time,
## so what comes back is already that entry's and nobody else's.
func _record_bounds(entry: IslandEntry, indices: PackedInt32Array, width: int) -> void:
    if indices.is_empty():
        return
    var min_x := 0x7fffffff
    var min_y := 0x7fffffff
    var max_x := -1
    var max_y := -1
    for i in indices.size():
        var index := indices[i]
        var x := index % width
        @warning_ignore("integer_division")
        var y := index / width
        if x < min_x:
            min_x = x
        if x > max_x:
            max_x = x
        if y < min_y:
            min_y = y
        if y > max_y:
            max_y = y
    entry.flooded_bounds = Rect2i(min_x, min_y, max_x - min_x + 1, max_y - min_y + 1)
