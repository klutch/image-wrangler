extends SceneTree

## The Fill Pinholes stage, checked for properties rather than for bytes.
##
## Most cases here are written as pictures, because that is what the stage is about: a
## grid of characters in, a grid of characters out, [code]#[/code] solid, [code]-[/code]
## partly transparent, [code].[/code] clear. A hash would say a run changed and this says
## what changed.
##
## [b]Not in [code]Fixtures.OPERATION_SCRIPTS[/code] yet[/b], for the same reason
## [code]tests/iw_remove_lines.gd[/code] is not: it is deterministic and self-contained and
## belongs in the parity baseline, and is left out only so the change that introduces it
## does not also re-record [code]tests/golden/baseline.json[/code].
##
## Run it:
## [codeblock]
## godot --headless --path ../.. --script res://addons/image_wrangler/tests/iw_fill_pinholes.gd
## [/codeblock]
##
## Every stage here is reached through [method load] rather than by its
## [code]class_name[/code], which is what lets it run before the editor has rescanned the
## project.

const OP_FILL_PINHOLES := "res://addons/image_wrangler/core/fill_pinholes.gd"
const OP_REMOVE_BACKGROUND := "res://addons/image_wrangler/core/remove_background.gd"

## The alpha each character in a fixture stands for. The soft one is deliberately a whole
## number of 1/255 steps.
const CLEAR := 0.0
const SOFT := 102.0 / 255.0
const OPAQUE := 1.0

## What the fixtures paint their opaque pixels, unless a case says otherwise.
const BODY := Color8(51, 153, 229)

var _failures := 0


func _initialize() -> void:
    _check_binding()
    _check_enclosed_only()
    _check_area_ladder()
    _check_diagonal_seal()
    _check_colour()
    _check_semi_transparency()
    _check_faint_never_votes()
    _check_rim_counted_once()
    _check_scan_order()
    _check_idempotence()
    _check_identity()
    _check_below_keyer()
    _check_invalidation()

    if _failures == 0:
        print("Fill Pinholes OK — enclosed specks close, the outside stays open, and the "
                + "colour comes from the rim.")
    quit(1 if _failures > 0 else 0)


# --- The build picked the kernel up ------------------------------------

func _check_binding() -> void:
    _expect(ClassDB.class_has_method("IWStageKernels", "fill_pinholes"),
            "IWStageKernels.fill_pinholes is not bound — the build did not pick up "
            + "iw_hole_kernels.cpp")


# --- Only transparency the image goes all the way round ----------------

func _check_enclosed_only() -> void:
    var before := [
        "........",
        ".######.",
        ".##.###.",
        ".######.",
        "........",
    ]
    var after := [
        "........",
        ".######.",
        ".######.",
        ".######.",
        "........",
    ]
    _expect_picture(_after(before, 1), after, "an enclosed one-pixel hole was not filled")

    # The same speck, but with a channel out to the edge of the shape and on to the edge of
    # the image. It is the outside now, and the outside is never filled.
    var notched := [
        "........",
        ".######.",
        "...####.",
        ".######.",
        "........",
    ]
    _expect_picture(_after(notched, 8), notched,
            "transparency reaching the edge of the image was filled")

    # A fully transparent image is all outside.
    _expect_picture(_after(_blank(6, 4), 100), _blank(6, 4),
            "an empty image was filled in")


# --- The setting is an area, and it is a ceiling -----------------------

## Three holes of area one, two and three, each sealed inside the same block and kept a
## clear row apart so no setting can join them. At max_area k exactly the holes up to k are
## closed, which is the whole of what the setting claims.
func _check_area_ladder() -> void:
    var before := [
        "..........",
        ".########.",
        ".#.######.",
        ".########.",
        ".#..#####.",
        ".########.",
        ".#...####.",
        ".########.",
        "..........",
    ]
    var expected := {
        1: [
            "..........",
            ".########.",
            ".########.",
            ".########.",
            ".#..#####.",
            ".########.",
            ".#...####.",
            ".########.",
            "..........",
        ],
        2: [
            "..........",
            ".########.",
            ".########.",
            ".########.",
            ".########.",
            ".########.",
            ".#...####.",
            ".########.",
            "..........",
        ],
        3: [
            "..........",
            ".########.",
            ".########.",
            ".########.",
            ".########.",
            ".########.",
            ".########.",
            ".########.",
            "..........",
        ],
    }
    for area: int in [1, 2, 3]:
        _expect_picture(_after(before, area), expected[area],
                "the area ladder is wrong at max_area %d" % area)
    # And past the top of it nothing further happens, because there is nothing further.
    _expect_picture(_after(before, 100), expected[3],
            "a max_area past the largest hole changed something else")


# --- Corner to corner seals a hole -------------------------------------

## The dual of the 8-connectivity random_hsv_tiles uses on objects. Two clear pixels that
## meet only at a corner are two holes, not one, so a max_area of 1 closes both — and if
## the flood were 8-connected they would be one hole of area 2 and neither would go.
func _check_diagonal_seal() -> void:
    var before := [
        ".......",
        ".#####.",
        ".#.###.",
        ".##.##.",
        ".#####.",
        ".......",
    ]
    var after := [
        ".......",
        ".#####.",
        ".#####.",
        ".#####.",
        ".#####.",
        ".......",
    ]
    _expect_picture(_after(before, 1), after,
            "two clear pixels meeting at a corner were treated as one hole")


# --- The colour is the average of the rim ------------------------------

func _check_colour() -> void:
    # A block half red and half blue with a one-pixel hole dead centre. Eight rim pixels,
    # four of each, so the answer is the halfway colour and not either of them.
    var image := Image.create_empty(5, 5, false, Image.FORMAT_RGBA8)
    for y in 5:
        for x in 5:
            image.set_pixel(x, y, Color8(200, 0, 0) if x < 2 else Color8(0, 0, 200))
    image.set_pixel(2, 2, Color(0, 0, 0, 0))

    var ctx := IWPipelineContext.from_image(image)
    _stage(1).process_context(ctx)
    var got := IWCompose.compose(ctx).get_pixel(2, 2)
    # Three of the eight rim pixels are red, five are blue: the hole sits in the blue half.
    _expect_colour(got, Color8(75, 0, 125), "the fill is not the average of its rim")
    _expect(is_equal_approx(got.a, 1.0), "a filled hole did not come out fully opaque")


# --- Faint is hole, not rim --------------------------------------------

func _check_semi_transparency() -> void:
    # A lone partly transparent pixel with solid image all round it is a hole of its own,
    # and comes out solid.
    var lone := [
        ".......",
        ".#####.",
        ".#-###.",
        ".#####.",
        ".......",
    ]
    var closed := [
        ".......",
        ".#####.",
        ".#####.",
        ".#####.",
        ".......",
    ]
    _expect_picture(_after(lone, 1), closed,
            "a lone partly transparent pixel was not treated as a hole")

    # And it counts toward the size of the hole it is joined to. One clear pixel beside one
    # faint one is a hole of two, not of one: at a budget of 1 neither goes, and at 2 both
    # come out solid. Plugging the clear half alone would leave the faint half as a ring of
    # exactly the damage this stage is here to remove.
    var rimmed := [
        ".......",
        ".#####.",
        ".#.-##.",
        ".#####.",
        ".......",
    ]
    _expect_picture(_after(rimmed, 1), rimmed,
            "a two-pixel hole was filled at a budget of one — its faint half is not being "
            + "counted toward the area")
    _expect_picture(_after(rimmed, 2), closed,
            "a hole's faint half was left behind")


# --- Nothing short of solid gets a vote --------------------------------

func _check_faint_never_votes() -> void:
    # A white block with a clear pixel in the middle and one black pixel at a fifth alpha
    # sitting corner to corner from it. The flood is 4-connected, so the faint one is a hole
    # of its own rather than part of this one — and it is not solid, so it is no part of the
    # rim either. Seven white votes, and the fill comes out white.
    var image := Image.create_empty(5, 5, false, Image.FORMAT_RGBA8)
    image.fill(Color8(255, 255, 255))
    image.set_pixel(1, 1, Color(0.0, 0.0, 0.0, 51.0 / 255.0))
    image.set_pixel(2, 2, Color(0, 0, 0, 0))

    var ctx := IWPipelineContext.from_image(image)
    _stage(1).process_context(ctx)
    var out := IWCompose.compose(ctx)

    _expect_colour(out.get_pixel(2, 2), Color8(255, 255, 255),
            "a fifth-alpha pixel voted on the fill beside it")
    # It is a hole in its own right, so it is filled too — from its own eight solid
    # neighbours, all of them white.
    _expect_colour(out.get_pixel(1, 1), Color8(255, 255, 255),
            "the faint pixel was not filled as a hole of its own")
    _expect(out.get_pixel(1, 1).a8 == 255,
            "the faint pixel did not come out fully opaque")


# --- A rim pixel votes once --------------------------------------------

func _check_rim_counted_once() -> void:
    # An L-shaped hole of three pixels. Its inner corner pixel touches all three of them,
    # and every other rim pixel touches one or two. Counting by touches rather than by
    # pixel would weight that corner triple.
    var image := Image.create_empty(6, 6, false, Image.FORMAT_RGBA8)
    image.fill(Color8(255, 255, 255))
    image.set_pixel(3, 3, Color8(0, 0, 0))
    for hole: Vector2i in [Vector2i(2, 2), Vector2i(3, 2), Vector2i(2, 3)]:
        image.set_pixel(hole.x, hole.y, Color(0, 0, 0, 0))

    var ctx := IWPipelineContext.from_image(image)
    _stage(3).process_context(ctx)
    var got := IWCompose.compose(ctx).get_pixel(2, 2)

    # Twelve rim pixels, one of them black: 11/12 of full white. Counted by touches the
    # corner would weigh three and four other pixels two, and the answer would be 15/18.
    var by_pixel := roundi(255.0 * 11.0 / 12.0)
    _expect(absi(got.r8 - by_pixel) <= 1,
            "a rim pixel touching three of the hole's pixels voted more than once "
            + "(got %d, want about %d)" % [got.r8, by_pixel])


# --- One fill never becomes another's rim ------------------------------

func _check_scan_order() -> void:
    # Two holes a pixel apart in a block whose halves are different colours. If the first
    # fill were allowed to colour the second, the answer would depend on which one the scan
    # reached first — so the same fixture flipped left to right must give the flipped answer.
    var image := Image.create_empty(7, 5, false, Image.FORMAT_RGBA8)
    for y in 5:
        for x in 7:
            image.set_pixel(x, y, Color8(220, 40, 40) if x < 3 else Color8(40, 40, 220))
    image.set_pixel(2, 2, Color(0, 0, 0, 0))
    image.set_pixel(4, 2, Color(0, 0, 0, 0))

    var ctx := IWPipelineContext.from_image(image)
    _stage(1).process_context(ctx)
    var direct := IWCompose.compose(ctx)

    var mirrored_source := Image.create_empty(7, 5, false, Image.FORMAT_RGBA8)
    for y in 5:
        for x in 7:
            mirrored_source.set_pixel(6 - x, y, image.get_pixel(x, y))
    var mirrored_ctx := IWPipelineContext.from_image(mirrored_source)
    _stage(1).process_context(mirrored_ctx)
    var mirrored := IWCompose.compose(mirrored_ctx)

    # To a step of 1/255, not to the byte. The rim is added up in the order the scan meets
    # it, and a mirrored fixture meets it in the opposite order — so a sum landing exactly
    # on a half, which this fixture's does, can round either way. That is a rounding, not an
    # ordering: a fill feeding another's rim would move a channel by tens of steps, not one.
    var mismatched := 0
    for y in 5:
        for x in 7:
            var here := direct.get_pixel(x, y)
            var there := mirrored.get_pixel(6 - x, y)
            if absi(here.r8 - there.r8) > 1 or absi(here.g8 - there.g8) > 1 \
                    or absi(here.b8 - there.b8) > 1 or here.a8 != there.a8:
                mismatched += 1
    _expect(mismatched == 0,
            "%d pixels differ between a fixture and its mirror — one fill is feeding "
            % mismatched + "another's rim")


# --- Running it twice is running it once -------------------------------

func _check_idempotence() -> void:
    var rows := [
        "..........",
        ".########.",
        ".#.####.#.",
        ".########.",
        ".#..###.#.",
        ".########.",
        "..........",
    ]
    var ctx := IWPipelineContext.from_image(_image(rows))
    var stage := _stage(4)
    stage.process_context(ctx)
    var once: PackedFloat32Array = ctx.final_alpha()
    var colours_once: PackedByteArray = ctx.data
    stage.process_context(ctx)
    _expect(ctx.final_alpha() == once, "a second run changed the alpha")
    _expect(ctx.data == colours_once, "a second run changed the colours")


# --- Nothing to do is exactly nothing ----------------------------------

func _check_identity() -> void:
    var solid := []
    for _y in 6:
        solid.append("######")
    var ctx := IWPipelineContext.from_image(_image(solid))
    var data_before: PackedByteArray = ctx.data
    var coverage_before: PackedFloat32Array = ctx.coverage
    var mask_before: PackedByteArray = ctx.mask
    _stage(100).process_context(ctx)
    _expect(ctx.data == data_before, "an image with no holes had its pixels rewritten")
    _expect(ctx.coverage == coverage_before, "an image with no holes had its coverage written")
    _expect(ctx.mask == mask_before, "an image with no holes had its mask written")


# --- Below a keyer, which is where it belongs --------------------------

func _check_below_keyer() -> void:
    var ctx := IWPipelineContext.from_image(_speckled_image())
    _keyer().process_context(ctx)
    var alpha_before: PackedFloat32Array = ctx.final_alpha()
    var open := 0
    for y in range(6, 20):
        for x in range(6, 20):
            if alpha_before[y * 32 + x] <= 0.0:
                open += 1
    if not _expect(open > 0, "the keyer punched no holes, so this proves nothing"):
        return

    _stage(4).process_context(ctx)
    var alpha_after: PackedFloat32Array = ctx.final_alpha()
    var still_open := 0
    for y in range(6, 20):
        for x in range(6, 20):
            if alpha_after[y * 32 + x] <= 0.0:
                still_open += 1
    _expect(still_open == 0, "%d specks inside the subject were left open" % still_open)

    # And the background the keyer opened is still open, everywhere.
    var lost := 0
    for i in ctx.pixel_count:
        if alpha_before[i] <= 0.0 and alpha_after[i] > 0.0:
            var x: int = i % 32
            var y: int = i / 32
            if x < 6 or y < 6 or x >= 20 or y >= 20:
                lost += 1
    _expect(lost == 0, "%d pixels of keyed-out background were filled back in" % lost)


# --- What it owes the run afterwards -----------------------------------

func _check_invalidation() -> void:
    var ctx := IWPipelineContext.from_image(_speckled_image())
    _keyer().process_context(ctx)
    _stage(4).process_context(ctx)

    var alpha: PackedFloat32Array = ctx.final_alpha()
    var mask: PackedByteArray = ctx.mask
    var opaque_background := 0
    for i in ctx.pixel_count:
        if alpha[i] > 0.0 and mask[i] == IWPipelineContext.MASK_BACKGROUND:
            opaque_background += 1
    _expect(opaque_background == 0,
            "%d filled pixels were left classified as background — they would be reopened "
            % opaque_background + "by anything below that recomputes coverage")

    # Every pixel that arrived at a nearest-subject answer must point at something that is
    # still subject. This is what a forgotten rebuild_nearest looks like.
    var nearest: PackedInt32Array = ctx.nearest
    var stale := 0
    for i in nearest.size():
        var at: int = nearest[i]
        if at >= 0 and mask[at] != IWPipelineContext.MASK_SUBJECT:
            stale += 1
    _expect(stale == 0, "%d pixels name a nearest subject that is no longer subject" % stale)

    _expect(not ctx.key_dist.is_empty(),
            "the distance map was cleared and never rebuilt")
    _expect(IWCompose.compose(ctx) != null, "the composed image did not survive")


# --- Fixtures ----------------------------------------------------------

## White ground, a solid subject, and a scattering of white specks inside it — the shape a
## glint or a JPEG highlight actually arrives in.
func _speckled_image() -> Image:
    var image := Image.create_empty(32, 32, false, Image.FORMAT_RGBA8)
    image.fill(Color.WHITE)
    for y in range(6, 20):
        for x in range(6, 20):
            image.set_pixel(x, y, Color8(30, 60, 170))
    for speck: Vector2i in [Vector2i(9, 9), Vector2i(14, 11), Vector2i(11, 16)]:
        image.set_pixel(speck.x, speck.y, Color.WHITE)
    # One two-pixel speck as well, so the area setting has something to reach past 1 for.
    image.set_pixel(16, 15, Color.WHITE)
    image.set_pixel(16, 16, Color.WHITE)
    return image


## The same Remove Background the other stage tests use, so this file is not inventing a
## second opinion about what keying looks like. Not contiguous, which is what makes it find
## the specks inside the subject as well as the ground outside it.
func _keyer() -> IWStackOperation:
    var stage: IWStackOperation = load(OP_REMOVE_BACKGROUND).new()
    var settings := stage.get_settings()
    settings.remove_colors.clear()
    settings.remove_colors.add(Color.WHITE, 0.05)
    settings.edge_width = 0
    settings.contiguous = false
    settings.decontaminate = false
    settings.bleed_radius = 0
    return stage


## Reached through [method load] rather than by its [code]class_name[/code], the way the
## parity harness reaches all of its stages.
func _stage(max_area: int) -> IWStackOperation:
    var stage: IWStackOperation = load(OP_FILL_PINHOLES).new()
    stage.get_settings().max_area = max_area
    return stage


# --- Pictures ----------------------------------------------------------

func _image(rows: Array) -> Image:
    var height := rows.size()
    var width: int = (rows[0] as String).length()
    var image := Image.create_empty(width, height, false, Image.FORMAT_RGBA8)
    for y in height:
        var row: String = rows[y]
        for x in width:
            image.set_pixel(x, y, Color(BODY.r, BODY.g, BODY.b, _alpha_for(row[x])))
    return image


func _alpha_for(character: String) -> float:
    match character:
        "#":
            return OPAQUE
        "-":
            return SOFT
        _:
            return CLEAR


## What the stage leaves, as a picture.
func _after(rows: Array, max_area: int) -> Array:
    var ctx := IWPipelineContext.from_image(_image(rows))
    _stage(max_area).process_context(ctx)
    return _render(ctx)


func _render(ctx: IWPipelineContext) -> Array:
    var alpha: PackedFloat32Array = ctx.final_alpha()
    var out := []
    for y in ctx.height:
        var line := ""
        for x in ctx.width:
            var a: float = alpha[y * ctx.width + x]
            if a >= 0.5:
                line += "#"
            elif a > 0.0:
                line += "-"
            else:
                line += "."
        out.append(line)
    return out


func _blank(width: int, height: int) -> Array:
    var rows := []
    for _y in height:
        rows.append(".".repeat(width))
    return rows


# --- Reporting ---------------------------------------------------------

func _expect(condition: bool, message: String) -> bool:
    if not condition:
        printerr("FAIL: %s" % message)
        _failures += 1
    return condition


func _expect_colour(actual: Color, expected: Color, message: String) -> void:
    if absi(actual.r8 - expected.r8) <= 1 and absi(actual.g8 - expected.g8) <= 1 \
            and absi(actual.b8 - expected.b8) <= 1:
        return
    printerr("FAIL: %s" % message)
    printerr("  got  %d, %d, %d" % [actual.r8, actual.g8, actual.b8])
    printerr("  want %d, %d, %d" % [expected.r8, expected.g8, expected.b8])
    _failures += 1


func _expect_picture(actual: Array, expected: Array, message: String) -> void:
    if actual == expected:
        return
    printerr("FAIL: %s" % message)
    printerr("  got                 want")
    var height: int = maxi(actual.size(), expected.size())
    for y in height:
        var got: String = actual[y] if y < actual.size() else ""
        var want: String = expected[y] if y < expected.size() else ""
        var flag := "   " if got == want else " <-"
        printerr("  %s  %s%s" % [got, want, flag])
    _failures += 1
