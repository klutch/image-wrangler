extends SceneTree

## The Repack packer, and the island finder it takes its sprites from.
##
## [b]The packing is checked as a set of properties rather than against fixed layouts.[/b]
## Where a sprite lands is an implementation detail and four modes' worth of coordinates
## would be a test that had to be rewritten every time one of them improved. What must
## never change is that nothing overlaps, nothing leaves the sheet, everything is placed
## when there is room, and running out of room is reported rather than silently dropping
## sprites — so those are what is written down.
##
## Run it:
## [codeblock]
## godot --headless --path . --script res://tests/iw_repack.gd
## [/codeblock]

const OP_REPACK := "res://addons/image_wrangler/core/iw_repack.gd"
const OP_RANDOM_HSV_TILES := "res://addons/image_wrangler/core/random_hsv_tiles.gd"

## Every mode, by the index the dropdown uses.
const MODES := [0, 1, 2, 3]
const MODE_NAMES := ["Shelf", "Grid", "Tight", "Original Order"]

var _failures := 0


func _initialize() -> void:
    _check_binding()
    _check_every_mode_is_sound()
    _check_grid_is_a_grid()
    _check_original_keeps_its_order()
    _check_tight_is_at_least_as_dense()
    _check_overflow_is_reported()
    _check_expand_to_fit()
    _check_degenerate_input()
    _check_mode_descriptions()
    _check_find_islands()
    _check_cut_islands()
    _check_nothing_is_lost()

    if _failures == 0:
        print("Repack OK — nothing overlaps, nothing leaves the sheet, and a sheet too "
                + "small says so.")
    quit(1 if _failures > 0 else 0)


func _check_binding() -> void:
    _expect(ClassDB.class_has_method("IWStageKernels", "find_islands"),
            "IWStageKernels.find_islands is not bound — the build did not pick up "
            + "iw_pack_kernels.cpp")


# --- What every mode has to get right ----------------------------------

func _check_every_mode_is_sound() -> void:
    # Deliberately awkward: tall and thin, short and wide, square, and one of each at the
    # extremes of the set, so no mode can pass by handling only the uniform case.
    var sizes := [
        Vector2i(30, 8), Vector2i(7, 40), Vector2i(16, 16), Vector2i(3, 3),
        Vector2i(24, 12), Vector2i(9, 31), Vector2i(40, 5), Vector2i(12, 12),
        Vector2i(5, 5), Vector2i(21, 19), Vector2i(2, 27), Vector2i(33, 3),
    ]
    # Sized for Grid, which is the mode that decides how big "room for them all" is: its
    # cell is the largest sprite in each direction, 40 by 40 here, so twelve sprites need
    # sixteen cells' worth of sheet however little of each one they use.
    var sheet := 160
    for mode: int in MODES:
        var packer := _packer(mode, sheet, sheet)
        var plan: Dictionary = packer.plan(sizes)
        var positions: Array = plan["positions"]
        var placed: int = plan["placed"]

        if not _expect(placed == sizes.size(),
                "%s placed %d of %d sprites on a sheet with room for them all"
                % [MODE_NAMES[mode], placed, sizes.size()]):
            continue
        _expect_inside(positions, sizes, sheet, sheet, MODE_NAMES[mode])
        _expect_no_overlap(positions, sizes, MODE_NAMES[mode])


func _expect_inside(positions: Array, sizes: Array, width: int, height: int,
        what: String) -> void:
    for i in sizes.size():
        var at: Vector2i = positions[i]
        var size: Vector2i = sizes[i]
        if at.x < 0 or at.y < 0 or at.x + size.x > width or at.y + size.y > height:
            _expect(false, "%s put sprite %d at %s, which leaves a %dx%d sheet"
                    % [what, i, at, width, height])
            return


func _expect_no_overlap(positions: Array, sizes: Array, what: String) -> void:
    for i in sizes.size():
        for j in range(i + 1, sizes.size()):
            var first := Rect2i(positions[i], sizes[i])
            var second := Rect2i(positions[j], sizes[j])
            if first.intersects(second):
                _expect(false, "%s overlapped sprite %d at %s with sprite %d at %s"
                        % [what, i, first, j, second])
                return


# --- What each mode promises on top ------------------------------------

## Grid's one property that the others do not have: a fixed stride, and the nth cell is the
## nth sprite. Sorting would pack it better and destroy the only reason to choose it.
func _check_grid_is_a_grid() -> void:
    var sizes := [Vector2i(10, 6), Vector2i(4, 14), Vector2i(9, 9), Vector2i(3, 2)]
    var plan: Dictionary = _packer(1, 64, 64).plan(sizes)
    var positions: Array = plan["positions"]
    if not _expect(plan["placed"] == sizes.size(), "Grid did not place every sprite"):
        return

    # The cell is the largest sprite in both directions, so every position is a multiple
    # of it and the sprites run left to right, top to bottom.
    var cell := Vector2i(10, 14)
    for i in sizes.size():
        var at: Vector2i = positions[i]
        _expect(at.x % cell.x == 0 and at.y % cell.y == 0,
                "Grid put sprite %d at %s, which is not on a %s stride" % [i, at, cell])
    var columns: int = 64 / cell.x
    for i in sizes.size():
        @warning_ignore("integer_division")
        var want := Vector2i((i % columns) * cell.x, (i / columns) * cell.y)
        _expect(positions[i] == want,
                "Grid put sprite %d at %s rather than in cell %d, %s"
                % [i, positions[i], i, want])


## Original Order's one property: the sprites come out in the order they went in, reading
## the sheet the way you read a page.
func _check_original_keeps_its_order() -> void:
    var sizes := [
        Vector2i(20, 10), Vector2i(6, 30), Vector2i(14, 8), Vector2i(9, 22),
        Vector2i(11, 5), Vector2i(25, 16),
    ]
    var plan: Dictionary = _packer(3, 64, 128).plan(sizes)
    var positions: Array = plan["positions"]
    if not _expect(plan["placed"] == sizes.size(), "Original Order did not place every sprite"):
        return

    for i in range(1, sizes.size()):
        var previous: Vector2i = positions[i - 1]
        var here: Vector2i = positions[i]
        var forward := here.y > previous.y or (here.y == previous.y and here.x > previous.x)
        _expect(forward, "Original Order put sprite %d at %s, which is behind sprite %d "
                % [i, here, i - 1] + "at %s" % previous)


## Tight exists to pack better than Shelf. If it ever stopped doing that there would be no
## reason to offer it, so the comparison is the test.
func _check_tight_is_at_least_as_dense() -> void:
    # Heights deliberately varied, which is the case interlocking helps with and uniform
    # heights are exactly the case where it cannot.
    var sizes := []
    for i in 40:
        sizes.append(Vector2i(6 + (i * 7) % 23, 4 + (i * 13) % 29))

    var shelf: Dictionary = _packer(0, 96, 4096).plan(sizes)
    var tight: Dictionary = _packer(2, 96, 4096).plan(sizes)
    if not _expect(shelf["placed"] == sizes.size() and tight["placed"] == sizes.size(),
            "one of the two modes did not place every sprite on a tall sheet"):
        return

    var shelf_bottom := _bottom_of(shelf["positions"], sizes)
    var tight_bottom := _bottom_of(tight["positions"], sizes)
    _expect(tight_bottom <= shelf_bottom,
            "Tight used %d rows of sheet where Shelf used %d — it is meant to be the "
            % [tight_bottom, shelf_bottom] + "denser of the two")


func _bottom_of(positions: Array, sizes: Array) -> int:
    var bottom := 0
    for i in sizes.size():
        bottom = maxi(bottom, positions[i].y + sizes[i].y)
    return bottom


# --- Running out of room -----------------------------------------------

## Reported rather than worked around. A packer that skipped what did not fit would give a
## sheet missing whichever sprites happened to be awkward, with nothing on it saying which.
func _check_overflow_is_reported() -> void:
    var sizes := []
    for _i in 30:
        sizes.append(Vector2i(20, 20))

    for mode: int in MODES:
        var plan: Dictionary = _packer(mode, 64, 64).plan(sizes)
        var placed: int = plan["placed"]
        _expect(placed < sizes.size(),
                "%s claimed to fit %d sprites of 20x20 on a 64x64 sheet"
                % [MODE_NAMES[mode], placed])
        _expect(placed > 0, "%s fitted nothing at all on a sheet with room for some"
                % MODE_NAMES[mode])
        # What did go down still has to be sound, since the caller may want to say how far
        # it got.
        var positions: Array = plan["positions"]
        var kept := []
        var kept_sizes := []
        for i in sizes.size():
            if positions[i].x >= 0:
                kept.append(positions[i])
                kept_sizes.append(sizes[i])
        _expect_inside(kept, kept_sizes, 64, 64, MODE_NAMES[mode] + " (partial)")
        _expect_no_overlap(kept, kept_sizes, MODE_NAMES[mode] + " (partial)")

    # A single sprite wider than the sheet can never go anywhere, and must be a failure
    # rather than a row that is dropped and retried forever.
    for mode: int in MODES:
        var plan: Dictionary = _packer(mode, 16, 512).plan([Vector2i(40, 4)])
        _expect(plan["placed"] == 0,
                "%s claimed to place a sprite wider than the sheet" % MODE_NAMES[mode])


# --- Growing the sheet -------------------------------------------------

## The sheet may double until everything fits, in every mode. Width first, then height,
## then width again — so the sizes it walks through are a fixed sequence and the one it
## stops on is the first in that sequence with room.
func _check_expand_to_fit() -> void:
    # It ships on, which is what makes the switch-off in _packer worth explaining. Read off
    # a packer nothing has touched.
    var fresh: IWOperation = load(OP_REPACK).new()
    _expect(fresh.get_settings().expand_to_fit,
            "Expand to Fit is not on by default")

    var sizes := []
    for _i in 30:
        sizes.append(Vector2i(20, 20))

    # 64 x 64 holds nine of them; thirty need a 128 x 128, which is two doublings away —
    # width to 128, then height to 128.
    var packer := _packer(1, 64, 64)
    packer.get_settings().expand_to_fit = true
    var plan: Dictionary = packer.plan(sizes)

    _expect(plan["placed"] == sizes.size(),
            "Expand to Fit placed %d of %d sprites" % [plan["placed"], sizes.size()])
    _expect(plan["width"] == 128 and plan["height"] == 128,
            "Expand to Fit stopped at %d x %d rather than the 128 x 128 that first fits"
            % [plan["width"], plan["height"]])
    _expect_inside(plan["positions"], sizes, plan["width"], plan["height"], "Expand to Fit")
    _expect_no_overlap(plan["positions"], sizes, "Expand to Fit")

    # Width goes first, so a sheet exactly one doubling short comes back wide rather than
    # tall. A 20-pixel cell on a 32 x 32 sheet is one column by one row, which holds one
    # sprite; doubling the width to 64 gives three columns and takes both.
    var narrow := _packer(1, 32, 32)
    narrow.get_settings().expand_to_fit = true
    var wide: Dictionary = narrow.plan([Vector2i(20, 20), Vector2i(20, 20)])
    _expect(wide["placed"] == 2, "the width doubling did not fit both sprites")
    _expect(wide["width"] == 64 and wide["height"] == 32,
            "the first doubling gave %d x %d rather than taking the width"
            % [wide["width"], wide["height"]])

    # A sheet that already fits is left exactly as it was asked for.
    var roomy := _packer(1, 256, 256)
    roomy.get_settings().expand_to_fit = true
    var kept: Dictionary = roomy.plan(sizes)
    _expect(kept["width"] == 256 and kept["height"] == 256,
            "a sheet with room to spare was grown to %d x %d anyway"
            % [kept["width"], kept["height"]])

    # It stops at the ceiling rather than running forever, and reports what did not fit.
    var huge := []
    for _i in 8:
        huge.append(Vector2i(9000, 9000))
    var stuck := _packer(1, 1024, 1024)
    stuck.get_settings().expand_to_fit = true
    var gave_up: Dictionary = stuck.plan(huge)
    _expect(gave_up["width"] == 16384 and gave_up["height"] == 16384,
            "expansion stopped at %d x %d rather than the largest a texture may be"
            % [gave_up["width"], gave_up["height"]])
    _expect(gave_up["placed"] < huge.size(),
            "expansion claimed to fit eight 9000-pixel sprites")

    # Off, it does not grow at all — which is what the other three modes always get.
    var fixed := _packer(1, 64, 64)
    fixed.get_settings().expand_to_fit = false
    var unmoved: Dictionary = fixed.plan(sizes)
    _expect(unmoved["width"] == 64 and unmoved["height"] == 64,
            "Expand to Fit grew the sheet while switched off")
    _expect(unmoved["placed"] < sizes.size(), "the unexpanded sheet somehow fitted them all")

    # Every mode grows, not just Grid — and whatever each one grows to has to be a sheet
    # its own sprites actually sit on.
    for mode: int in MODES:
        var other := _packer(mode, 32, 32)
        other.get_settings().expand_to_fit = true
        var grown: Dictionary = other.plan(sizes)
        _expect(grown["placed"] == sizes.size(),
                "%s placed %d of %d with Expand to Fit on"
                % [MODE_NAMES[mode], grown["placed"], sizes.size()])
        _expect(grown["width"] > 32 or grown["height"] > 32,
                "%s did not grow a 32 x 32 sheet at all" % MODE_NAMES[mode])
        _expect_inside(grown["positions"], sizes, grown["width"], grown["height"],
                MODE_NAMES[mode] + " (expanded)")
        _expect_no_overlap(grown["positions"], sizes, MODE_NAMES[mode] + " (expanded)")

    # A sprite wider than the sheet is the case the row modes bail on outright, and
    # expansion has to reach it rather than reporting a failure it could have fixed.
    for mode: int in MODES:
        var cramped := _packer(mode, 16, 16)
        cramped.get_settings().expand_to_fit = true
        var reached: Dictionary = cramped.plan([Vector2i(40, 12)])
        _expect(reached["placed"] == 1,
                "%s could not grow a 16-wide sheet to take a 40-wide sprite"
                % MODE_NAMES[mode])
        _expect(reached["width"] >= 40,
                "%s stopped at %d wide with a 40-wide sprite to place"
                % [MODE_NAMES[mode], reached["width"]])


# --- Nothing to do -----------------------------------------------------

func _check_degenerate_input() -> void:
    for mode: int in MODES:
        var empty: Dictionary = _packer(mode, 64, 64).plan([])
        _expect(empty["placed"] == 0 and (empty["positions"] as Array).is_empty(),
                "%s did something with an empty list" % MODE_NAMES[mode])

        # A zero-sized sprite is skipped rather than placed, and must not stop the ones
        # around it going down.
        var mixed := [Vector2i(8, 8), Vector2i(0, 0), Vector2i(6, 6)]
        var plan: Dictionary = _packer(mode, 64, 64).plan(mixed)
        _expect(plan["placed"] == 2,
                "%s placed %d of the two real sprites beside an empty one"
                % [MODE_NAMES[mode], plan["placed"]])
        _expect((plan["positions"] as Array)[1] == Vector2i(-1, -1),
                "%s gave an empty sprite a place on the sheet" % MODE_NAMES[mode])


# --- What the dock says about each mode ---------------------------------

## The dropdown shows a line about whatever is selected, and it comes from the same array
## the labels do. The failure worth catching is a fifth mode added with a label and no
## description, which would read as an empty gap under the dropdown rather than as an
## oversight.
func _check_mode_descriptions() -> void:
    var packer: IWOperation = load(OP_REPACK).new()
    var labels: Array = packer.MODE_LABELS
    var notes: Array = packer.MODE_DESCRIPTIONS

    _expect(notes.size() == labels.size(),
            "%d modes carry %d descriptions between them" % [labels.size(), notes.size()])

    var seen := {}
    for mode: int in MODES:
        var note: String = packer.describe_mode(mode)
        _expect(not note.is_empty(), "%s has no description" % MODE_NAMES[mode])
        _expect(not seen.has(note),
                "%s is described in the same words as another mode" % MODE_NAMES[mode])
        seen[note] = true

    # A value from a hand-edited file falls back rather than reaching off the end.
    _expect(packer.describe_mode(-1) == packer.describe_mode(0),
            "a mode below the range did not fall back to the first")
    _expect(packer.describe_mode(99) == packer.describe_mode(0),
            "a mode above the range did not fall back to the first")


# --- The sprites themselves --------------------------------------------

## The islands Repack packs have to be the islands Random HSV Tiles colours — the two go
## through one labeller precisely so a sheet coloured by one and packed by the other agree
## about where one object ends and the next begins.
func _check_find_islands() -> void:
    var image := _three_objects()
    var ctx := IWPipelineContext.from_image(image)
    var found: PackedInt32Array = IWStageKernels.find_islands(ctx)
    _expect(found.size() == 3 * 4,
            "found %d islands in an image with three objects on it" % (found.size() / 4))

    # Against the bounds Random HSV Tiles reports for the same picture, which is the claim
    # that matters and the one that would quietly stop being true if either drifted.
    var other := IWPipelineContext.from_image(image)
    var stage: IWStackOperation = load(OP_RANDOM_HSV_TILES).new()
    var settings := stage.get_settings()
    settings.hue_amount = 1.0
    var theirs: PackedInt32Array = IWStageKernels.random_hsv_tiles(other, 1, 1.0, 0.0, 0.0)
    _expect(found == theirs,
            "the islands Repack finds are not the ones Random HSV Tiles colours\n  %s\n  %s"
            % [found, theirs])

    # And the rectangles are the objects that were drawn.
    var rects := []
    for n in found.size() / 4:
        rects.append(Rect2i(found[n * 4], found[n * 4 + 1], found[n * 4 + 2], found[n * 4 + 3]))
    _expect(rects.has(Rect2i(2, 2, 5, 4)), "the top-left object came back as %s" % [rects])
    _expect(rects.has(Rect2i(12, 3, 3, 9)), "the tall object came back as %s" % [rects])
    _expect(rects.has(Rect2i(5, 14, 8, 3)), "the wide object came back as %s" % [rects])


## A sprite is cut to its island, not cropped to its rectangle.
##
## The case that matters is two objects whose boxes overlap — here a block sitting in the
## notch of an L, well clear of it but entirely inside its bounding rectangle. Taken as a
## rectangle the L would carry the block along with it, and the block would then appear
## twice on the packed sheet: once as itself, and once as a passenger with nothing to
## explain it.
func _check_cut_islands() -> void:
    var image := _interlocked()
    var ctx := IWPipelineContext.from_image(image)
    var bounds: PackedInt32Array = IWStageKernels.find_islands(ctx)
    var sprites: Array = _cut(image)

    if not _expect(sprites.size() == 2,
            "found %d objects in the interlocked fixture" % sprites.size()):
        return
    # Scan order: the L's first solid pixel is above and left of the block's.
    var arm: Image = sprites[0]
    var block: Image = sprites[1]

    _expect(Rect2i(bounds[0], bounds[1], bounds[2], bounds[3]) == Rect2i(2, 2, 13, 11),
            "the L's rectangle came back as %s" % Rect2i(bounds[0], bounds[1], bounds[2], bounds[3]))
    _expect(arm.get_size() == Vector2i(13, 11),
            "the L's sprite is %s rather than the size of its rectangle" % arm.get_size())
    _expect(block.get_size() == Vector2i(6, 4),
            "the block's sprite is %s" % block.get_size())

    # The block sits at (7, 4) in the image, which is (5, 2) inside the L's rectangle. Not
    # one pixel of it may be in the L's sprite.
    var strays := 0
    for y in 4:
        for x in 6:
            if arm.get_pixel(5 + x, 2 + y).a8 != 0:
                strays += 1
    _expect(strays == 0,
            "%d pixels of the block came along inside the L's sprite" % strays)

    # And the block's own sprite is all there.
    var missing := 0
    for y in 4:
        for x in 6:
            if block.get_pixel(x, y).a8 != 255:
                missing += 1
    _expect(missing == 0, "%d pixels are missing from the block's own sprite" % missing)

    # Every pixel of the L is still in the L's sprite: cutting must not lose the object
    # it is cutting out.
    # The upright is 3 by 11 and the foot is 10 by 3, which do not overlap.
    _expect(_opaque_in(arm) == 3 * 11 + 10 * 3,
            "the L's sprite holds %d opaque pixels rather than %d"
            % [_opaque_in(arm), 3 * 11 + 10 * 3])


## Packing moves the sprites and loses none of them.
##
## The end-to-end claim, and the one a user would notice first: whatever was on the images
## is on the sheet, once each. Counted rather than compared pixel for pixel, since where
## each sprite lands is the packer's business.
func _check_nothing_is_lost() -> void:
    var sprites: Array = _cut(_three_objects())
    var sizes := []
    var want := 0
    for sprite: Image in sprites:
        sizes.append(sprite.get_size())
        want += _opaque_in(sprite)

    for mode: int in MODES:
        var packer := _packer(mode, 64, 64)
        var plan: Dictionary = packer.plan(sizes)
        if not _expect(plan["placed"] == sprites.size(),
                "%s did not place the three objects" % MODE_NAMES[mode]):
            continue

        var sheet := Image.create_empty(64, 64, false, Image.FORMAT_RGBA8)
        sheet.fill(Color(0, 0, 0, 0))
        var positions: Array = plan["positions"]
        for i in sprites.size():
            sheet.blit_rect(sprites[i], Rect2i(Vector2i.ZERO, sizes[i]), positions[i])

        _expect(_opaque_in(sheet) == want,
                "%s put %d opaque pixels on the sheet where the sprites hold %d"
                % [MODE_NAMES[mode], _opaque_in(sheet), want])


func _cut(image: Image) -> Array:
    var ctx := IWPipelineContext.from_image(image)
    var out := []
    for sprite: Image in IWStageKernels.cut_islands(ctx):
        out.append(sprite)
    return out


func _opaque_in(image: Image) -> int:
    var count := 0
    for y in image.get_height():
        for x in image.get_width():
            if image.get_pixel(x, y).a8 == 255:
                count += 1
    return count


# --- Fixtures ----------------------------------------------------------

## Three separate blocks on transparent ground, no two touching even at a corner.
func _three_objects() -> Image:
    var image := Image.create_empty(20, 20, false, Image.FORMAT_RGBA8)
    image.fill(Color(0, 0, 0, 0))
    for spec: Rect2i in [Rect2i(2, 2, 5, 4), Rect2i(12, 3, 3, 9), Rect2i(5, 14, 8, 3)]:
        for y in range(spec.position.y, spec.end.y):
            for x in range(spec.position.x, spec.end.x):
                image.set_pixel(x, y, Color(0.2, 0.6, 0.9, 1.0))
    return image


## An L, and a block sitting in its notch — clear of it on every side, and entirely inside
## its bounding rectangle. The one shape a packer that crops to rectangles gets wrong.
##
##     ###..........
##     ###..######..
##     ###..######..
##     ###..######..
##     ###..######..
##     ###..........
##     ###..........
##     #############
##     #############
##     #############
func _interlocked() -> Image:
    var image := Image.create_empty(20, 20, false, Image.FORMAT_RGBA8)
    image.fill(Color(0, 0, 0, 0))
    var solid := Color(0.2, 0.6, 0.9, 1.0)
    # The upright of the L, then its foot.
    for y in range(2, 13):
        for x in range(2, 5):
            image.set_pixel(x, y, solid)
    for y in range(10, 13):
        for x in range(5, 15):
            image.set_pixel(x, y, solid)
    # The block in the notch, two clear pixels off the upright and two above the foot.
    for y in range(4, 8):
        for x in range(7, 13):
            image.set_pixel(x, y, solid)
    return image


## Reached through [method load] rather than by its [code]class_name[/code], the way every
## other test here reaches its operation.
##
## [b]Expansion is switched off here and turned on where it is the subject.[/b] It ships on,
## so most of these fixtures would otherwise grow themselves a sheet that fits and every
## check about running out of room would pass for the wrong reason. The default itself is
## checked once, in [method _check_expand_to_fit], which is where it belongs.
func _packer(mode: int, width: int, height: int) -> IWOperation:
    var packer: IWOperation = load(OP_REPACK).new()
    var settings := packer.get_settings()
    settings.mode = mode
    settings.output_width = width
    settings.output_height = height
    settings.expand_to_fit = false
    return packer


# --- Reporting ---------------------------------------------------------

func _expect(condition: bool, message: String) -> bool:
    if not condition:
        printerr("FAIL: %s" % message)
        _failures += 1
    return condition
