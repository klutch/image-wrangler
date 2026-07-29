extends SceneTree

## The distance map, after a stage that changed colour in one part of the image.
##
## [b]The claim being checked is an equality, not a tolerance.[/b] Three stages move colour
## inside a boundary they can name — [HSVAdjust] inside rectangles, [RandomHSVTiles] inside
## island bounds, [FillPinholes] at a list of filled pixels — and each of them used to
## answer the debt by throwing the whole map away and measuring the sheet again. They now
## remeasure only what moved. That is only allowed because a pixel's distance depends on
## its own colour and the first key and on nothing else, so the two must agree exactly: run
## the stage, keep what it left, force a full rebuild, compare.
##
## A file of its own rather than three additions to three test files, because it is one
## invariant about [IWPipelineContext] that three stages happen to lean on, and the way it
## breaks is the same in all three.
##
## Run it:
## [codeblock]
## godot --headless --path . --script res://tests/iw_key_dist.gd
## [/codeblock]

const OP_REMOVE_BACKGROUND := "res://addons/image_wrangler/core/remove_background.gd"
const OP_HSV_ADJUST := "res://addons/image_wrangler/core/hsv_adjust.gd"
const OP_RANDOM_HSV_TILES := "res://addons/image_wrangler/core/random_hsv_tiles.gd"
const OP_FILL_PINHOLES := "res://addons/image_wrangler/core/fill_pinholes.gd"

var _failures := 0


func _initialize() -> void:
    _check_binding()
    _check_hsv_adjust()
    _check_random_hsv_tiles()
    _check_fill_pinholes()
    _check_first_build()
    _check_out_of_range()

    if _failures == 0:
        print("Key Dist OK — a patched map is the map a full rebuild gives.")
    quit(1 if _failures > 0 else 0)


func _check_binding() -> void:
    _expect(ClassDB.class_has_method("IWPipelineContext", "refresh_key_dist"),
            "IWPipelineContext.refresh_key_dist is not bound")
    _expect(ClassDB.class_has_method("IWPipelineContext", "refresh_key_dist_rects"),
            "IWPipelineContext.refresh_key_dist_rects is not bound")


# --- The three stages that patch rather than rebuild --------------------

func _check_hsv_adjust() -> void:
    var ctx := _keyed()
    var stage: IWStackOperation = load(OP_HSV_ADJUST).new()
    # Left untyped on purpose, the way every stage here is reached through load(): naming
    # HSVRegionList would pull that script in as a global and leave it held at exit, which
    # is the leak the other test files avoid the same way.
    var regions = stage.get_settings().regions
    # Two regions, overlapping, one of them hanging off the edge of the image — the three
    # cases the rectangle walk has to survive. Values set by hand rather than left at the
    # random hue add() gives, so a failure is reproducible.
    for spec: Array in [[Rect2i(8, 8, 10, 10), 0.3], [Rect2i(14, 14, 40, 40), -0.2]]:
        var region = regions.add(spec[0])
        region.hue = spec[1]
        region.saturation = 1.4
        region.value = 0.8
    stage.process_context(ctx)
    _expect_matches_full_rebuild(ctx, "HSV Adjust")


func _check_random_hsv_tiles() -> void:
    var ctx := _keyed()
    var stage: IWStackOperation = load(OP_RANDOM_HSV_TILES).new()
    var settings := stage.get_settings()
    settings.rng_seed = 7
    settings.hue_amount = 1.0
    settings.saturation_amount = 0.5
    settings.value_amount = 0.5
    stage.process_context(ctx)
    _expect_matches_full_rebuild(ctx, "Random HSV Tiles")


func _check_fill_pinholes() -> void:
    var ctx := _keyed()
    var stage: IWStackOperation = load(OP_FILL_PINHOLES).new()
    stage.get_settings().max_area = 4
    stage.process_context(ctx)
    _expect_matches_full_rebuild(ctx, "Fill Pinholes")


# --- The fallbacks -----------------------------------------------------

## A stage may run above everything that keys, where there is no map to patch. Asked to
## refresh one that does not exist, the context has to build the whole thing rather than
## leave the run without one — Refine Edges skips its filter entirely on an empty map.
func _check_first_build() -> void:
    for rects: bool in [true, false]:
        var ctx := _keyed()
        ctx.key_dist = PackedFloat32Array()
        if rects:
            ctx.refresh_key_dist_rects(PackedInt32Array([4, 4, 6, 6]))
        else:
            ctx.refresh_key_dist(PackedInt32Array([10, 11, 12]))
        _expect(ctx.key_dist.size() == ctx.pixel_count,
                "refreshing an empty map did not build it (rects = %s)" % rects)
        _expect_matches_full_rebuild(ctx, "the first build (rects = %s)" % rects)

    # And with no keys at all there is nothing to measure against, so there is no map and
    # asking for one is not an error.
    var bare := IWPipelineContext.from_image(_speckled_image())
    bare.refresh_key_dist(PackedInt32Array([0, 1, 2]))
    _expect(bare.key_dist.is_empty(),
            "a context with no keys came back with a distance map")


## Indices and rectangles that fall outside the image are clamped away rather than written
## past the end of the buffer.
func _check_out_of_range() -> void:
    var ctx := _keyed()
    var before: PackedFloat32Array = ctx.key_dist
    ctx.refresh_key_dist(PackedInt32Array([-1, ctx.pixel_count, ctx.pixel_count + 500]))
    _expect(ctx.key_dist == before, "an out-of-range index changed the map")

    ctx.refresh_key_dist_rects(PackedInt32Array([-20, -20, 8, 8, ctx.width + 4, 2, 9, 9]))
    _expect(ctx.key_dist == before, "an out-of-range rectangle changed the map")
    _expect(IWCompose.compose(ctx) != null, "the composed image did not survive")


# --- Fixtures ----------------------------------------------------------

## The map as it would be built from scratch, against what the stage left behind.
func _expect_matches_full_rebuild(ctx: IWPipelineContext, what: String) -> void:
    var patched: PackedFloat32Array = ctx.key_dist
    if not _expect(patched.size() == ctx.pixel_count,
            "%s left no distance map at all" % what):
        return

    ctx.key_dist = PackedFloat32Array()
    ctx.ensure_key_dist()
    var rebuilt: PackedFloat32Array = ctx.key_dist

    var differing := 0
    var worst := 0.0
    for i in rebuilt.size():
        if patched[i] != rebuilt[i]:
            differing += 1
            worst = maxf(worst, absf(patched[i] - rebuilt[i]))
    _expect(differing == 0,
            "%s left %d of %d distances different from a full rebuild (worst %.6f)"
            % [what, differing, rebuilt.size(), worst])


## White ground, a solid subject, and a scattering of white specks inside it — the same
## fixture the Fill Pinholes tests use, so all three stages here are pointed at an image
## with something for each of them to do.
func _speckled_image() -> Image:
    var image := Image.create_empty(48, 48, false, Image.FORMAT_RGBA8)
    image.fill(Color.WHITE)
    for y in range(8, 40):
        for x in range(8, 40):
            image.set_pixel(x, y, Color8(30, 60, 170))
    # A second object, so Random HSV Tiles has more than one island to recolour.
    for y in range(4, 7):
        for x in range(42, 46):
            image.set_pixel(x, y, Color8(200, 90, 40))
    for speck: Vector2i in [Vector2i(12, 12), Vector2i(20, 17), Vector2i(15, 30)]:
        image.set_pixel(speck.x, speck.y, Color.WHITE)
    image.set_pixel(26, 25, Color.WHITE)
    image.set_pixel(26, 26, Color.WHITE)
    return image


## A context that has been keyed, so there are keys to measure against and a map already
## built for the stage under test to patch.
func _keyed() -> IWPipelineContext:
    var ctx := IWPipelineContext.from_image(_speckled_image())
    var keyer: IWStackOperation = load(OP_REMOVE_BACKGROUND).new()
    var settings := keyer.get_settings()
    settings.remove_colors.clear()
    settings.remove_colors.add(Color.WHITE, 0.05)
    settings.edge_width = 1
    settings.contiguous = false
    settings.decontaminate = false
    settings.bleed_radius = 0
    keyer.process_context(ctx)
    return ctx


# --- Reporting ---------------------------------------------------------

func _expect(condition: bool, message: String) -> bool:
    if not condition:
        printerr("FAIL: %s" % message)
        _failures += 1
    return condition
