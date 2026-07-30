extends SceneTree

## The Smooth Blocks stage, checked for what it promises rather than for bytes.
##
## The fixture is built the way the damage is made: a smooth image is cut into squares of
## eight and each square is nudged to a slightly different level, which is what rounding
## every block off on its own does. What the stage has to show is that the joins between
## those squares come down without the inside of them being touched.
##
## Reached through [method load] rather than by [code]class_name[/code], so this runs
## before the editor has rescanned the project.
##
## Run it:
## [codeblock]
## godot --headless --path ../.. --script res://addons/image_wrangler/tests/iw_smooth_blocks.gd
## [/codeblock]

const OP_SMOOTH_BLOCKS := "res://addons/image_wrangler/core/smooth_blocks.gd"

const W := 96
const H := 96
const BLOCK := 8

## How far each block is nudged off its true level, in eight-bit steps. Six is what a
## middling quality setting leaves on a flat area.
const NUDGE := 6

var _failures := 0


func _initialize() -> void:
    _check_binding()
    _check_flattens_seams()
    _check_keeps_the_inside()
    _check_identity()
    _check_real_edge()
    _check_detail()
    _check_alpha()

    if _failures == 0:
        print("Smooth Blocks OK — the grid goes, the blocks' own contents stay, and a "
                + "real edge on a seam survives.")
    quit(1 if _failures > 0 else 0)


func _check_binding() -> void:
    _expect(ClassDB.class_has_method("IWStageKernels", "smooth_blocks"),
            "IWStageKernels.smooth_blocks is not bound — the build did not pick up "
            + "iw_block_kernels.cpp")


# --- It does what it is for ---------------------------------------------

## The joins are the whole complaint, so they are the whole measurement.
func _check_flattens_seams() -> void:
    var ctx := IWPipelineContext.from_image(_blocked())
    var before := _seam_step(ctx.data)
    _stage(0.08, 1.0).process_context(ctx)
    var after := _seam_step(ctx.data)
    print("  step across the seams: %.4f -> %.4f" % [before, after])
    _expect(after < before * 0.6, "the seams did not measurably flatten")

    # And they have to end up close to what the image does everywhere else, or the grid
    # is still there — only fainter.
    var inside := _inside_step(ctx.data)
    print("  step inside the blocks: %.4f" % inside)
    _expect(after < inside * 2.5,
            "the seams are still %.1f times the image's own step" % (after / maxf(inside, 0.0001)))


## Only the seams. A stage that flattened the blocks themselves would be a blur.
func _check_keeps_the_inside() -> void:
    var image := _blocked()
    var ctx := IWPipelineContext.from_image(image)
    var before: PackedByteArray = ctx.data
    _stage(0.08, 1.0).process_context(ctx)

    # The middle of each block is four pixels from every seam, and the correction reaches
    # three. It must be untouched, exactly.
    var moved := 0
    for by in range(0, H / BLOCK):
        for bx in range(0, W / BLOCK):
            var at := ((by * BLOCK + 4) * W + bx * BLOCK + 4) * 4
            if before[at] != ctx.data[at]:
                moved += 1
    _expect(moved == 0, "%d block centres moved, and nothing that far in should" % moved)


func _check_identity() -> void:
    var ctx := IWPipelineContext.from_image(_blocked())
    var before: PackedByteArray = ctx.data
    _stage(0.08, 0.0).process_context(ctx)
    _expect(ctx.data == before, "an amount of 0.0 was not an exact identity")

    var none := IWPipelineContext.from_image(_blocked())
    var untouched: PackedByteArray = none.data
    _stage(0.0, 1.0).process_context(none)
    _expect(none.data == untouched, "a threshold of 0.0 was not an exact identity")


## A hard edge that happens to land on the grid is not an artifact, and flattening it
## would be the one unforgivable thing this can do.
func _check_real_edge() -> void:
    var ctx := IWPipelineContext.from_image(_edge_on_seam())
    _stage(0.08, 1.0).process_context(ctx)

    var left := int(ctx.data[(H / 2 * W + W / 2 - 1) * 4])
    var right := int(ctx.data[(H / 2 * W + W / 2) * 4])
    print("  a real edge sitting on a seam: %d | %d" % [left, right])
    _expect(right - left > 180, "a real edge on a seam was flattened to %d" % (right - left))


## Detail survives compression far better than the level a block sits at, so a busy area
## is never a seam however big the step across it happens to be.
func _check_detail() -> void:
    var image := _noisy()
    var ctx := IWPipelineContext.from_image(image)
    var before := _inside_step(ctx.data)
    _stage(0.08, 1.0).process_context(ctx)
    var after := _inside_step(ctx.data)
    print("  detail kept: %.4f -> %.4f" % [before, after])
    _expect(after > before * 0.9, "a noisy area was flattened, which is a blur")


func _check_alpha() -> void:
    var ctx := IWPipelineContext.from_image(_blocked())
    var before: PackedByteArray = ctx.data
    _stage(0.08, 1.0).process_context(ctx)
    for i in W * H:
        if before[i * 4 + 3] != ctx.data[i * 4 + 3]:
            _expect(false, "alpha was not preserved byte for byte")
            return
    _expect(IWCompose.compose(ctx) != null, "the composed image did not survive")


# --- Fixtures -----------------------------------------------------------

## A gentle gradient cut into blocks, each sitting a little off its true level.
##
## The gradient matters: a flat field would let a stage that simply averaged everything
## pass, and this has to be shown not to be one.
func _blocked() -> Image:
    var image := Image.create_empty(W, H, false, Image.FORMAT_RGBA8)
    for y in H:
        for x in W:
            var level := 90 + (x + y) / 6
            var block := (x / BLOCK) + (y / BLOCK) * 3
            # Alternates either side of the true level, so no block is ever right and the
            # error does not drift across the image.
            var nudged := level + (NUDGE if block % 2 == 0 else -NUDGE)
            image.set_pixel(x, y, Color8(nudged, nudged, nudged))
    return image


## Black against white, split exactly down a block seam.
func _edge_on_seam() -> Image:
    var image := Image.create_empty(W, H, false, Image.FORMAT_RGBA8)
    for y in H:
        for x in W:
            image.set_pixel(x, y, Color8(10, 10, 10) if x < W / 2 else Color8(245, 245, 245))
    return image


func _noisy() -> Image:
    var image := Image.create_empty(W, H, false, Image.FORMAT_RGBA8)
    var noise := _Lcg.new(20260728)
    for y in H:
        for x in W:
            var level := 100 + noise.below(60)
            image.set_pixel(x, y, Color8(level, level, level))
    return image


# --- Helpers ------------------------------------------------------------

func _stage(threshold: float, amount: float) -> IWStackOperation:
    var stage: IWStackOperation = load(OP_SMOOTH_BLOCKS).new()
    var settings := stage.get_settings()
    settings.threshold = threshold
    settings.amount = amount
    return stage


## Mean jump across the columns where two blocks meet.
func _seam_step(data: PackedByteArray) -> float:
    var total := 0.0
    var count := 0
    for y in H:
        for x in range(BLOCK, W, BLOCK):
            total += absf(_red(data, x, y) - _red(data, x - 1, y))
            count += 1
    return total / float(maxi(count, 1))


## Mean jump between neighbours that are not on a seam, which is what the image's own
## detail looks like.
func _inside_step(data: PackedByteArray) -> float:
    var total := 0.0
    var count := 0
    for y in H:
        for x in range(1, W):
            if x % BLOCK == 0:
                continue
            total += absf(_red(data, x, y) - _red(data, x - 1, y))
            count += 1
    return total / float(maxi(count, 1))


func _red(data: PackedByteArray, x: int, y: int) -> float:
    return float(data[(y * W + x) * 4]) / 255.0


func _expect(condition: bool, message: String) -> bool:
    if not condition:
        printerr("FAIL: %s" % message)
        _failures += 1
    return condition


## A small generator, so the noise is the same on every machine.
class _Lcg extends RefCounted:
    var _state: int

    func _init(seed_value: int) -> void:
        _state = seed_value & 0xFFFFFFFF

    func below(limit: int) -> int:
        _state = (_state * 1664525 + 1013904223) & 0xFFFFFFFF
        return ((_state >> 16) & 0xFFFF) % limit
