extends SceneTree

## The Brush Edit stage, checked for properties rather than for bytes.
##
## Most cases here are written as pictures, because that is what the stage is about: a grid
## of characters in, a grid of characters out, [code]#[/code] solid, [code]-[/code] partly
## transparent, [code].[/code] clear. A hash would say a run changed and this says what
## changed.
##
## [b]Not in [code]Fixtures.OPERATION_SCRIPTS[/code] yet[/b], for the same reason
## [code]tests/iw_remove_lines.gd[/code] is not: it is deterministic and self-contained and
## belongs in the parity baseline, and is left out only so the change that introduces it
## does not also re-record [code]tests/golden/baseline.json[/code].
##
## Run it:
## [codeblock]
## godot --headless --path . --script res://tests/iw_brush_edit.gd
## [/codeblock]
##
## Every stage here is reached through [method load] rather than by its
## [code]class_name[/code], which is what lets it run before the editor has rescanned the
## project.

const OP_BRUSH_EDIT := "res://addons/image_wrangler/core/brush_edit_op.gd"

## The codec, which has no [code]class_name[/code] of its own and is reached by path the
## way the dock reaches it.
const SettingsIO := preload("res://addons/image_wrangler/core/iw_settings_io.gd")

## The preview, for the one check that drives a drag through it rather than handing the
## stage a stroke that is already made.
const PREVIEW_VIEW := "res://addons/image_wrangler/ui/iw_preview_view.gd"

## The alpha each character in a fixture stands for.
const CLEAR := 0.0
const OPAQUE := 1.0

## What the fixtures paint their opaque pixels.
const BODY := Color8(51, 153, 229)

var _failures := 0


func _initialize() -> void:
    _check_binding()
    _check_single_dab()
    _check_radius_ladder()
    _check_line_is_continuous()
    _check_add_over_clear()
    _check_order_matters()
    _check_no_double_up_within_a_stroke()
    _check_sample_density_does_not_matter()
    _check_sharpness()
    _check_switches()
    _check_identity()
    _check_round_trip()
    _check_live_matches_the_stage()
    _check_patch_matches_the_whole()
    _check_incremental_patches_match()
    _check_add_takes_the_source_colour()
    _check_overlay_matches_the_stroke()
    await _check_preview_reports_a_drag()

    if _failures == 0:
        print("Brush Edit OK — strokes are continuous, they stack in order, one stroke "
                + "cannot paint over itself, and the live brush matches the stage.")
    quit(1 if _failures > 0 else 0)


# --- The build picked the kernel up ------------------------------------

func _check_binding() -> void:
    _expect(ClassDB.class_has_method("IWStageKernels", "paint_strokes"),
            "IWStageKernels.paint_strokes is not bound — the build did not pick up "
            + "iw_brush_kernels.cpp")


# --- A click is one dab ------------------------------------------------

func _check_single_dab() -> void:
    var solid := _solid(7, 5)
    var after := _after(solid, [_stroke([Vector2i(3, 2)], 1, 1.0, false)])
    _expect_picture(after, [
        "#######",
        "#######",
        "###.###",
        "#######",
        "#######",
    ], "a one-point stroke at radius 1 did not take exactly one pixel")


# --- The radius is measured half a pixel short -------------------------

## Which is what makes 1 a single pixel rather than a five-pixel cross. The ladder is 1, 3
## and 5 across, and it is the property that would silently be off by one either way.
func _check_radius_ladder() -> void:
    var expected := {
        1: [
            "#########",
            "#########",
            "#########",
            "####.####",
            "#########",
            "#########",
            "#########",
        ],
        2: [
            "#########",
            "#########",
            "###...###",
            "###...###",
            "###...###",
            "#########",
            "#########",
        ],
        # A circle of radius 2.5 rasterised, which is 5 across through the middle three
        # rows and 3 across at top and bottom — (2, 2) is 2.83 out and misses, (2, 1) is
        # 2.24 and lands.
        3: [
            "#########",
            "###...###",
            "##.....##",
            "##.....##",
            "##.....##",
            "###...###",
            "#########",
        ],
    }
    for radius: int in [1, 2, 3]:
        _expect_picture(
                _after(_solid(9, 7), [_stroke([Vector2i(4, 3)], radius, 1.0, false)]),
                expected[radius],
                "the radius ladder is wrong at %d" % radius)


# --- A fast drag leaves no gaps ----------------------------------------

## The whole reason the kernel walks the gap between two samples rather than trusting them
## to be adjacent: a drag reports wherever the pointer was seen, and on a quick sweep that
## is nowhere near every pixel.
func _check_line_is_continuous() -> void:
    # Two samples, eleven pixels apart on a diagonal. Nothing between them was reported.
    var after := _after(_solid(13, 13),
            [_stroke([Vector2i(1, 1), Vector2i(11, 11)], 1, 1.0, false)])
    var gaps := 0
    for i in 11:
        if after[i + 1][i + 1] != ".":
            gaps += 1
    _expect(gaps == 0, "%d pixels of a diagonal stroke were never painted" % gaps)

    # And along an axis, where the line walk has a different shape.
    var flat := _after(_solid(13, 5), [_stroke([Vector2i(1, 2), Vector2i(11, 2)], 1, 1.0, false)])
    _expect_picture(flat, [
        "#############",
        "#############",
        "#...........#",
        "#############",
        "#############",
    ], "a horizontal stroke did not paint every pixel between its two samples")


# --- Add paints solid over nothing at all ------------------------------

## Coverage is multiplied by the source's own alpha, so a stroke that only wrote coverage
## could never bring back a pixel that arrived clear. This is the case that catches it.
func _check_add_over_clear() -> void:
    var blank := _blank(7, 5)
    var after := _after(blank, [_stroke([Vector2i(3, 2)], 2, 1.0, true)])
    _expect_picture(after, [
        ".......",
        "..###..",
        "..###..",
        "..###..",
        ".......",
    ], "Add did not make fully transparent pixels solid")


# --- Later strokes work on what the earlier ones left ------------------

## The one place this parts company with Polygon Edit, where an Add wins every overlap
## whatever position it holds.
func _check_order_matters() -> void:
    var blank := _blank(9, 5)
    var add := _stroke([Vector2i(2, 2), Vector2i(6, 2)], 2, 1.0, true)
    var cut := _stroke([Vector2i(4, 1), Vector2i(4, 3)], 1, 1.0, false)

    _expect_picture(_after(blank, [add, cut]), [
        ".........",
        ".###.###.",
        ".###.###.",
        ".###.###.",
        ".........",
    ], "a Subtract stroke drawn after an Add did not bite into it")

    # And the other way round, on the same two strokes: the Add now has the last word.
    _expect_picture(_after(blank, [cut, add]), [
        ".........",
        ".#######.",
        ".#######.",
        ".#######.",
        ".........",
    ], "an Add stroke drawn after a Subtract did not fill it back in")


# --- One stroke cannot paint over itself -------------------------------

## Dragging slowly lands twenty overlapping dabs on a pixel where dragging fast lands two.
## A stroke that came out darker for having been drawn carefully would be unusable, so the
## dabs within a stroke take the strongest rather than accumulating.
func _check_no_double_up_within_a_stroke() -> void:
    var solid := _solid(9, 9)
    # Three pixels out from the path, on a soft brush that reaches three and a half — so
    # this pixel is on the feather, where a double-up would show. Sampled off the path
    # rather than on it because the middle of a brush is solid at every sharpness, and a
    # pixel already taken outright cannot be taken twice.
    var rim := 4 * 9 + 7
    var down := [Vector2i(4, 1), Vector2i(4, 7)]

    var once := _alpha_after(solid, [_stroke(down, 4, 0.0, false)])
    _expect(once[rim] > 0.0 and once[rim] < 1.0,
            "the sampled pixel is not on the feather (%.3f), so this proves nothing"
            % once[rim])

    # The same stroke, dragged back up the way it came: every pixel is dabbed twice inside
    # one entry. This is what a slow drag looks like, and it must come out identical.
    var doubled := _alpha_after(solid,
            [_stroke([Vector2i(4, 1), Vector2i(4, 7), Vector2i(4, 1)], 4, 0.0, false)])
    _expect(is_equal_approx(doubled[rim], once[rim]),
            "a stroke passing over itself came out at %.3f where one pass gives %.3f — "
            % [doubled[rim], once[rim]] + "the dabs are accumulating within a stroke")

    # Two separate strokes over the same place must still stack, which is the ordinary way
    # to lean on something.
    var twice := _alpha_after(solid,
            [_stroke(down, 4, 0.0, false), _stroke(down, 4, 0.0, false)])
    _expect(twice[rim] < once[rim] - 0.001,
            "two separate strokes over the same place did not stack (%.3f vs %.3f)"
            % [twice[rim], once[rim]])


# --- The path is what matters, not how often it was sampled ------------

## A stroke stores wherever the pointer was seen. The same path reported twice as often has
## to give the same picture, or the answer would depend on how fast the mouse was moving.
func _check_sample_density_does_not_matter() -> void:
    var sparse := _stroke([Vector2i(2, 2), Vector2i(12, 8)], 3, 0.4, false)
    var dense := _stroke([
        Vector2i(2, 2), Vector2i(4, 3), Vector2i(6, 4), Vector2i(7, 5),
        Vector2i(9, 6), Vector2i(11, 7), Vector2i(12, 8),
    ], 3, 0.4, false)
    var solid := _solid(16, 12)
    var by_sparse := _alpha_after(solid, [sparse])
    var by_dense := _alpha_after(solid, [dense])

    var differing := 0
    for i in by_sparse.size():
        if absf(by_sparse[i] - by_dense[i]) > 0.001:
            differing += 1
    # Not zero: the two paths are the same line only where Bresenham and the extra samples
    # agree on which pixels it passes through, and a sample placed off the ideal line
    # legitimately moves it. What must not happen is the density changing the strength.
    var strongest := 0.0
    for i in by_sparse.size():
        strongest = maxf(strongest, absf(by_sparse[i] - by_dense[i]))
    _expect(strongest <= 1.0,
            "resampling a stroke changed it beyond what a different line could explain")
    _expect(differing < int(by_sparse.size() * 0.25),
            "%d of %d pixels differ between the same stroke sampled twice as often"
            % [differing, by_sparse.size()])


# --- Sharpness is the width of the feather -----------------------------

func _check_sharpness() -> void:
    var solid := _solid(11, 11)

    # At 1 the rim is hard: every pixel the brush reaches is taken outright, and nothing
    # is left partly there.
    var hard := _alpha_after(solid, [_stroke([Vector2i(5, 5)], 4, 1.0, false)])
    var partial := 0
    for value in hard:
        if value > 0.0 and value < 1.0:
            partial += 1
    _expect(partial == 0, "%d pixels came out partly erased at a sharpness of 1" % partial)

    # At 0 the ramp runs the whole way from the centre, so the rim is partial and the
    # centre is still solid — which is what keeps a one-pixel brush usable at any setting.
    var soft := _alpha_after(solid, [_stroke([Vector2i(5, 5)], 4, 0.0, false)])
    var softened := 0
    for value in soft:
        if value > 0.0 and value < 1.0:
            softened += 1
    _expect(softened > 0, "a sharpness of 0 left no partly erased pixels at all")
    _expect(is_zero_approx(soft[5 * 11 + 5]),
            "the centre of a soft brush was not taken outright (%.3f)" % soft[5 * 11 + 5])

    # And the falloff runs the right way: further out is less taken away, so more is left.
    var near := soft[5 * 11 + 6]
    var far := soft[5 * 11 + 8]
    _expect(near < far, "the brush falloff runs backwards — %.3f beside the centre "
            % near + "against %.3f near the rim" % far)

    # A one-pixel brush paints at its softest setting, which the falloff makes easy to
    # get wrong: the centre is at zero distance and must always be solid.
    var pencil := _alpha_after(solid, [_stroke([Vector2i(5, 5)], 1, 0.0, false)])
    _expect(is_zero_approx(pencil[5 * 11 + 5]),
            "a one-pixel brush at sharpness 0 painted nothing (%.3f)" % pencil[5 * 11 + 5])


# --- The switches on a row ---------------------------------------------

func _check_switches() -> void:
    var solid := _solid(7, 5)
    var off := _stroke([Vector2i(3, 2)], 2, 1.0, false)
    off.enabled = false
    _expect_picture(_after(solid, [off]), _picture_of(solid),
            "a switched-off stroke was painted anyway")

    # An unstarted stroke is on the list but has nothing to lay down.
    var empty := _stroke([], 2, 1.0, false)
    _expect_picture(_after(solid, [empty]), _picture_of(solid),
            "a stroke with no points changed the image")


# --- Nothing to do is exactly nothing ----------------------------------

func _check_identity() -> void:
    var ctx := IWPipelineContext.from_image(_image(_solid(6, 6)))
    var data_before: PackedByteArray = ctx.data
    var coverage_before: PackedFloat32Array = ctx.coverage
    var mask_before: PackedByteArray = ctx.mask
    _stage([]).process_context(ctx)
    _expect(ctx.data == data_before, "an empty stroke list rewrote the pixels")
    _expect(ctx.coverage == coverage_before, "an empty stroke list wrote the coverage")
    _expect(ctx.mask == mask_before, "an empty stroke list wrote the mask")


# --- The sidecar carries every stroke back -----------------------------

## Through the codec's own harness, so this stage is held to the same standard as the four
## list controls that came before it — and so a stroke that lost its brush on the way to
## disk is caught here rather than by a sidecar that quietly flattens every stroke.
func _check_round_trip() -> void:
    var stage: IWStackOperation = load(OP_BRUSH_EDIT).new()
    _expect(SettingsIO.self_test(stage),
            "Brush Edit settings did not survive the sidecar codec")


# --- The live brush agrees with the stage ------------------------------

## The whole point of the live path: what the dock paints between two mouse events has to
## be what the run puts there when the button comes up. Two separate pieces of code — one
## painting a pipeline context, one painting composed pixels — and if they ever disagree
## the stroke visibly jumps at the end of every drag.
func _check_live_matches_the_stage() -> void:
    var rows := _solid(24, 24)
    # A path whose samples are far apart, so the walk between them has work to do, and one
    # that doubles back over itself — which is where applying each segment to the last one
    # rather than to the untouched picture shows up as a hardened rim.
    var path := [
        Vector2i(4, 5), Vector2i(18, 9), Vector2i(11, 20), Vector2i(12, 19), Vector2i(6, 7),
    ]
    for radius: int in [1, 5]:
        for sharpness: float in [1.0, 0.35, 0.0]:
            var ctx := IWPipelineContext.from_image(_image(rows))
            _stage([_stroke(path, radius, sharpness, false)]).process_context(ctx)
            var by_stage := IWCompose.compose(ctx)

            var live := _live_paint(rows, path, radius, sharpness, false)

            var differing := 0
            var worst := 0
            for y in 24:
                for x in 24:
                    var want: int = by_stage.get_pixel(x, y).a8
                    var got: int = live.get_pixel(x, y).a8
                    if want != got:
                        differing += 1
                        worst = maxi(worst, absi(want - got))
            _expect(differing == 0,
                    "the live brush and the stage disagree on %d pixels (worst %d/255) at "
                    % [differing, worst] + "radius %d, sharpness %.2f" % [radius, sharpness])


## Drives the live brush over a whole path the way the dock does: a dab where the button
## went down, then one call per segment, each handed the untouched picture and the strength
## the stroke has built up so far.
func _live_paint(rows: Array, path: Array, radius: int, sharpness: float,
        adding: bool) -> Image:
    var base := _image(rows)
    var strength := Image.create_empty(
            base.get_width(), base.get_height(), false, Image.FORMAT_RF)
    var shown: Image = IWStageKernels.paint_patch(base, strength, null, Vector2i.ZERO,
            path[0], path[0], radius, sharpness, adding)
    for i in range(1, path.size()):
        shown = IWStageKernels.paint_patch(base, strength, null, Vector2i.ZERO,
                path[i - 1], path[i], radius, sharpness, adding)
    return shown


## And that painting a patch of the image gives the same answer as painting all of it,
## which is what makes it safe to only ever touch the region a segment can reach.
func _check_patch_matches_the_whole() -> void:
    var rows := _solid(20, 20)
    var from := Vector2i(6, 6)
    var to := Vector2i(13, 11)

    var base := _image(rows)
    var full_strength := Image.create_empty(20, 20, false, Image.FORMAT_RF)
    var whole: Image = IWStageKernels.paint_patch(base, full_strength, null, Vector2i.ZERO,
            from, to, 4, 0.3, false)

    # The same segment, painted into just the box it can reach and put back.
    var pieced := _image(rows)
    var region := Rect2i(2, 2, 16, 14)
    var strength := Image.create_empty(20, 20, false, Image.FORMAT_RF).get_region(region)
    var patch: Image = IWStageKernels.paint_patch(base.get_region(region), strength, null,
            region.position, from, to, 4, 0.3, false)
    pieced.blit_rect(patch, Rect2i(Vector2i.ZERO, region.size), region.position)

    var differing := 0
    for y in 20:
        for x in 20:
            if whole.get_pixel(x, y).a8 != pieced.get_pixel(x, y).a8:
                differing += 1
    _expect(differing == 0,
            "%d pixels differ between painting the whole image and painting the patch "
            % differing + "the segment reaches")


## And that the dock's own arithmetic — a base, a strength buffer, and one patch per
## segment, each only as big as that segment can reach — lands on the same picture as
## painting the whole image every time.
##
## [b]This mirrors [code]_extend_live_paint[/code] rather than calling it.[/b] The dock
## cannot be built headless: its settings form is made of [EditorSpinSlider], which only
## the real editor can instantiate. So the loop is written out again here, which does not
## prove the dock's copy of the bounds maths is right — but it does prove the approach is,
## and it runs every Godot call that path depends on, including the ones a parse check
## cannot see through.
func _check_incremental_patches_match() -> void:
    var rows := _solid(28, 28)
    var path := [Vector2i(5, 6), Vector2i(20, 10), Vector2i(9, 22), Vector2i(10, 21)]
    var radius := 4
    var sharpness := 0.3

    var want := _live_paint(rows, path, radius, sharpness, false)

    var base := _image(rows)
    var strength := Image.create_empty(28, 28, false, Image.FORMAT_RF)
    var shown := base.duplicate()
    var bounds := Rect2i()
    var at: Vector2i = path[0]
    for i in path.size():
        var to: Vector2i = path[i]
        var touched := _reach_of(at, to, radius, base.get_size())
        var whole := Rect2i(Vector2i.ZERO, touched.size)
        var piece := strength.get_region(touched)
        var patch: Image = IWStageKernels.paint_patch(base.get_region(touched), piece, null,
                touched.position, at, to, radius, sharpness, false)
        if not _expect(patch != null, "the kernel returned nothing for segment %d" % i):
            return
        strength.blit_rect(piece, whole, touched.position)
        shown.blit_rect(patch, whole, touched.position)
        at = to
        bounds = touched if bounds.size.x <= 0 else bounds.merge(touched)
        # What the view would be handed. Only asked for its size, since the point here is
        # that the region exists and covers everything painted so far.
        var upload: Image = shown.get_region(bounds)
        _expect(upload.get_size() == bounds.size,
                "the upload region does not match the bounds at segment %d" % i)

    var differing := 0
    for y in 28:
        for x in 28:
            if want.get_pixel(x, y).a8 != shown.get_pixel(x, y).a8:
                differing += 1
    _expect(differing == 0,
            "%d pixels differ between painting segment by segment and painting the whole "
            % differing + "image at once")


## The pixels a segment of the brush can reach, clamped. Mirrors the dock's own
## [code]_brush_bounds[/code]; see the note above.
func _reach_of(from: Vector2i, to: Vector2i, radius: int, size: Vector2i) -> Rect2i:
    var low := Vector2i(mini(from.x, to.x), mini(from.y, to.y)) - Vector2i.ONE * radius
    var high := Vector2i(maxi(from.x, to.x), maxi(from.y, to.y)) + Vector2i.ONE * radius
    return Rect2i(low, high - low + Vector2i.ONE).intersection(Rect2i(Vector2i.ZERO, size))


## Add lifts a pixel out of nothing, and has to take a colour from somewhere. The composed
## image has none worth having at a pixel that was showing nothing, so it comes from the
## source.
func _check_add_takes_the_source_colour() -> void:
    var base := Image.create_empty(9, 9, false, Image.FORMAT_RGBA8)
    base.fill(Color(0, 0, 0, 0))
    var beneath := Image.create_empty(9, 9, false, Image.FORMAT_RGBA8)
    beneath.fill(Color8(200, 60, 30))
    var strength := Image.create_empty(9, 9, false, Image.FORMAT_RF)

    var patch: Image = IWStageKernels.paint_patch(base, strength, beneath, Vector2i.ZERO,
            Vector2i(4, 4), Vector2i(4, 4), 2, 1.0, true)

    var painted := patch.get_pixel(4, 4)
    _expect(painted.a8 == 255, "Add did not make the pixel solid (%d)" % painted.a8)
    _expect(painted.r8 == 200 and painted.g8 == 60 and painted.b8 == 30,
            "Add took the colour from the wrong place (%d, %d, %d)"
            % [painted.r8, painted.g8, painted.b8])

    # Outside the brush nothing is touched at all, colour included.
    _expect(patch.get_pixel(0, 0).a8 == 0, "Add reached past its own radius")

    # With no source to read, the alpha still moves — a caller that has nothing to offer
    # gets a stroke rather than an error.
    var bare: Image = IWStageKernels.paint_patch(base,
            Image.create_empty(9, 9, false, Image.FORMAT_RF), null, Vector2i.ZERO,
            Vector2i(4, 4), Vector2i(4, 4), 2, 1.0, true)
    _expect(bare.get_pixel(4, 4).a8 == 255,
            "Add with no source image left the pixel transparent")


# --- The overlay is the stroke, not a line through it ------------------

## What a highlighted row lights up. It has to be the same set of pixels the stroke acts
## on, at the same strengths — that is the whole difference between it and the line at the
## brush's width it replaced, which marked where the stroke went rather than what it did.
func _check_overlay_matches_the_stroke() -> void:
    var rows := _solid(24, 24)
    var path := [Vector2i(4, 5), Vector2i(18, 9), Vector2i(11, 20)]
    var radius := 4
    var sharpness := 0.4
    var mark := Color(1.0, 1.0, 0.2, 1.0)

    var points := PackedInt32Array()
    for point: Vector2i in path:
        points.append(point.x)
        points.append(point.y)
    var overlay: Image = IWStageKernels.stroke_overlay(points, radius, sharpness,
            Vector2i.ZERO, Vector2i(24, 24), mark)
    if not _expect(overlay != null, "the overlay kernel returned nothing"):
        return

    # A Subtract stroke on a solid image takes away exactly its own strength, so what is
    # left is one minus it — which is what the overlay's alpha has to be.
    var painted := _alpha_after(rows, [_stroke(path, radius, sharpness, false)])
    var differing := 0
    var worst := 0
    for y in 24:
        for x in 24:
            var want: int = 255 - roundi(painted[y * 24 + x] * 255.0)
            var got: int = overlay.get_pixel(x, y).a8
            if absi(want - got) > 1:
                differing += 1
                worst = maxi(worst, absi(want - got))
    _expect(differing == 0,
            "the overlay lights up %d pixels the stroke does not act on, or at the wrong "
            % differing + "strength (worst %d/255)" % worst)

    # And it is all one colour, wherever it shows at all.
    var off_colour := 0
    for y in 24:
        for x in 24:
            var pixel := overlay.get_pixel(x, y)
            if pixel.a8 > 0 and (pixel.r8 != 255 or pixel.g8 != 255 or pixel.b8 != 51):
                off_colour += 1
    _expect(off_colour == 0, "%d pixels of the overlay came out the wrong colour" % off_colour)

    # A one-point stroke is a dab, and has to light up rather than draw nothing — the case
    # a polyline could not handle and needed a circle of its own.
    var dab: Image = IWStageKernels.stroke_overlay(PackedInt32Array([5, 5]), 3, 1.0,
            Vector2i.ZERO, Vector2i(11, 11), mark)
    _expect(dab != null and dab.get_pixel(5, 5).a8 == 255,
            "a one-point stroke drew no overlay")

    # Bounded by the region it was asked for, so a dab on a large sheet costs a picture the
    # size of the dab.
    var cropped: Image = IWStageKernels.stroke_overlay(PackedInt32Array([12, 12]), 2, 1.0,
            Vector2i(10, 10), Vector2i(5, 5), mark)
    _expect(cropped != null and cropped.get_size() == Vector2i(5, 5),
            "the overlay did not come back at the size it was asked for")
    _expect(cropped.get_pixel(2, 2).a8 == 255,
            "the overlay's origin was not honoured — the dab landed off centre")


# --- The preview turns a drag into points ------------------------------

## The one piece of this feature that lives in the interface and can still be checked
## headless. The dock itself cannot: building it needs the real editor, since the settings
## form is made of [EditorSpinSlider]. The preview is a plain [Control], so the path from a
## mouse drag to a list of pixels can be driven directly.
##
## It reaches past the private names on the view, the way these tests already reach into a
## context's buffers. The alternative is exposing an input seam that exists only to be
## tested, which is a worse trade.
func _check_preview_reports_a_drag() -> void:
    var view: Control = load(PREVIEW_VIEW).new()
    view.size = Vector2(320, 240)
    root.add_child(view)

    var image := Image.create_empty(32, 32, false, Image.FORMAT_RGBA8)
    image.fill(Color(BODY.r, BODY.g, BODY.b, OPAQUE))
    view.set_image(image)
    view.set_zoom(100.0)
    await process_frame

    var points := []
    var finished := [0]
    view.stroke_point.connect(func(pixel: Vector2i, starting: bool) -> void:
            points.append([pixel, starting]))
    view.stroke_finished.connect(func() -> void: finished[0] += 1)
    view.pick_mode = true
    view.stroke_pick = true

    # The handlers ask the Input singleton whether the button is still down — which is how
    # they survive a release swallowed by an alt-tab — so the real state has to be primed
    # or every motion would read as an abandoned drag.
    var origin: Vector2 = view._content_origin
    Input.parse_input_event(_mouse_button(origin + Vector2(4.5, 4.5), true))
    await process_frame

    view._on_canvas_gui_input(_mouse_button(origin + Vector2(4.5, 4.5), true))
    view._on_canvas_gui_input(_mouse_motion(origin + Vector2(9.5, 4.5)))
    # The same pixel again, which is what most motion events are at any real zoom.
    view._on_canvas_gui_input(_mouse_motion(origin + Vector2(9.9, 4.9)))
    view._on_canvas_gui_input(_mouse_motion(origin + Vector2(9.5, 12.5)))
    Input.parse_input_event(_mouse_button(origin + Vector2(9.5, 12.5), false))
    view._on_canvas_gui_input(_mouse_button(origin + Vector2(9.5, 12.5), false))

    _expect(points.size() == 3,
            "a drag over three pixels reported %d points — motion inside one pixel should "
            % points.size() + "be dropped, and every crossing reported")
    if points.size() == 3:
        _expect(points[0] == [Vector2i(4, 4), true],
                "the press did not open a stroke at the pixel under it (%s)" % [points[0]])
        _expect(points[1] == [Vector2i(9, 4), false] and points[2] == [Vector2i(9, 12), false],
                "the drag reported the wrong pixels, or reported them as fresh starts")
    _expect(finished[0] == 1,
            "the release reported %d endings rather than one" % finished[0])

    # The highlighted-stroke overlay draws both ways without complaint.
    var mark: Image = IWStageKernels.stroke_overlay(
            PackedInt32Array([4, 4, 9, 12]), 6, 0.5, Vector2i.ZERO, Vector2i(32, 32),
            Color(1, 1, 0.2, 0.65))
    view.set_brush_overlay(mark, Rect2i(0, 0, 32, 32))
    await process_frame
    view.set_brush_overlay(null, Rect2i())
    await process_frame

    # And so does a live patch, including the hole it cuts in the image behind it — at a
    # region in the middle, one against an edge, and one covering the lot, which are the
    # three shapes the four surrounding bands collapse into.
    for region: Rect2i in [Rect2i(8, 8, 6, 6), Rect2i(0, 0, 5, 32), Rect2i(0, 0, 32, 32)]:
        view.set_live_patch(image.get_region(region), region)
        await process_frame
    view.clear_live_patch()
    await process_frame

    view.queue_free()


func _mouse_button(at: Vector2, pressed: bool) -> InputEventMouseButton:
    var event := InputEventMouseButton.new()
    event.button_index = MOUSE_BUTTON_LEFT
    event.pressed = pressed
    event.position = at
    return event


func _mouse_motion(at: Vector2) -> InputEventMouseMotion:
    var event := InputEventMouseMotion.new()
    event.position = at
    return event


# --- Fixtures ----------------------------------------------------------

func _stroke(points: Array, radius: int, sharpness: float, adding: bool) -> BrushStroke:
    var stroke := BrushStroke.new()
    var typed: Array[Vector2i] = []
    for point: Vector2i in points:
        typed.append(point)
    stroke.points = typed
    stroke.radius = radius
    stroke.sharpness = sharpness
    stroke.mode = IWAlphaMode.Mode.ADD if adding else IWAlphaMode.Mode.SUBTRACT
    return stroke


## Reached through [method load] rather than by its [code]class_name[/code], the way the
## parity harness reaches all of its stages.
func _stage(strokes: Array) -> IWStackOperation:
    var stage: IWStackOperation = load(OP_BRUSH_EDIT).new()
    var list: BrushStrokeList = stage.get_settings().strokes
    for stroke: BrushStroke in strokes:
        list.strokes.append(stroke)
    return stage


func _solid(width: int, height: int) -> Array:
    var rows := []
    for _y in height:
        rows.append("#".repeat(width))
    return rows


func _blank(width: int, height: int) -> Array:
    var rows := []
    for _y in height:
        rows.append(".".repeat(width))
    return rows


# --- Pictures ----------------------------------------------------------

func _image(rows: Array) -> Image:
    var height := rows.size()
    var width: int = (rows[0] as String).length()
    var image := Image.create_empty(width, height, false, Image.FORMAT_RGBA8)
    for y in height:
        var row: String = rows[y]
        for x in width:
            image.set_pixel(x, y, Color(BODY.r, BODY.g, BODY.b,
                    OPAQUE if row[x] == "#" else CLEAR))
    return image


## What the stage leaves, as a picture.
func _after(rows: Array, strokes: Array) -> Array:
    var ctx := IWPipelineContext.from_image(_image(rows))
    _stage(strokes).process_context(ctx)
    return _render(ctx)


## What the stage leaves, as alpha, for the cases a picture cannot express.
func _alpha_after(rows: Array, strokes: Array) -> PackedFloat32Array:
    var ctx := IWPipelineContext.from_image(_image(rows))
    _stage(strokes).process_context(ctx)
    return ctx.final_alpha()


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


## A fixture as the picture it already is, for the cases that expect no change.
func _picture_of(rows: Array) -> Array:
    var out := []
    for row: String in rows:
        out.append(row)
    return out


# --- Reporting ---------------------------------------------------------

func _expect(condition: bool, message: String) -> bool:
    if not condition:
        printerr("FAIL: %s" % message)
        _failures += 1
    return condition


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
