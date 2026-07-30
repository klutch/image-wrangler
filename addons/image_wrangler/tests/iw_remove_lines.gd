extends SceneTree

## The Remove Lines stage, checked for properties rather than for bytes.
##
## Most cases here are written as pictures, because that is what the stage is about: a
## grid of characters in, a grid of characters out, [code]#[/code] solid, [code]-[/code]
## partly transparent, [code].[/code] clear. A hash would say a run changed and this says
## what changed.
##
## [b]Not in [code]Fixtures.OPERATION_SCRIPTS[/code] yet, and for a different reason than
## [Denoise].[/b] Denoise is excluded permanently — hashing a third-party model's output
## would be recording someone else's version number. This one is deterministic and
## self-contained, so it belongs in the parity baseline; it is left out only so the change
## that introduces it does not also re-record [code]tests/golden/baseline.json[/code]. Add
## it and re-record once the behaviour has settled. Do not read the exclusion as a rule.
##
## Run it:
## [codeblock]
## godot --headless --path ../.. --script res://addons/image_wrangler/tests/iw_remove_lines.gd
## [/codeblock]
##
## Unlike [code]tests/iw_denoise.gd[/code] it exits clean, with no leaked instances
## reported. That is not luck: every stage here is reached through [method load] rather
## than by its [code]class_name[/code], which is also what lets it run before the editor
## has rescanned the project. Naming a type would cost both.

const OP_REMOVE_LINES := "res://addons/image_wrangler/core/remove_lines.gd"
const OP_REMOVE_BACKGROUND := "res://addons/image_wrangler/core/remove_background.gd"
const OP_REFINE_EDGES := "res://addons/image_wrangler/core/refine_edges.gd"

## The alpha each character in a fixture stands for. The soft one is deliberately a whole
## number of 1/255 steps, and deliberately under the half the kernel measures against.
const CLEAR := 0.0
const SOFT := 102.0 / 255.0
const OPAQUE := 1.0

var _failures := 0


func _initialize() -> void:
	_check_binding()
	_check_shapes()
	_check_thickness_ladder()
	_check_detached_only()
	_check_reconstruction()
	_check_antialiasing()
	_check_border()
	_check_transpose()
	_check_idempotence()
	_check_identity()
	_check_regions()
	_check_below_refine_edges()
	_check_invalidation()

	if _failures == 0:
		print("Remove Lines OK — thin goes, thick stays, soft edges survive, and the "
				+ "stages above it are left alone.")
	quit(1 if _failures > 0 else 0)


# --- The build picked the kernel up ------------------------------------

func _check_binding() -> void:
	_expect(ClassDB.class_has_method("IWStageKernels", "remove_lines"),
			"IWStageKernels.remove_lines is not bound — the build did not pick up "
			+ "iw_line_kernels.cpp")


# --- Any orientation, and a speck counts -------------------------------

## Nothing here is attached to anything, so both modes must answer the same.
func _check_shapes() -> void:
	var before := [
		"................",
		".####...........",
		"................",
		".#..............",
		".#.....#####....",
		".#.....#####....",
		".#.....#####....",
		".......#####....",
		".......#####....",
		"............#...",
		"................",
	]
	var after := [
		"................",
		"................",
		"................",
		"................",
		".......#####....",
		".......#####....",
		".......#####....",
		".......#####....",
		".......#####....",
		"................",
		"................",
	]
	for detached: bool in [true, false]:
		_expect_picture(_after(before, 1, detached), after,
				"a hairline, a column, or a speck survived at thickness 1 "
				+ "(detached_only = %s)" % detached)

	# A diagonal is a line too, and it is the case a row-and-column scan would miss.
	var diagonal := [
		"........",
		".#......",
		"..#.....",
		"...#....",
		"....#...",
		".....#..",
		"........",
	]
	_expect_picture(_after(diagonal, 1, true), _blank(8, 7),
			"a one-pixel diagonal survived at thickness 1")


# --- The setting means a width -----------------------------------------

## Bars one, two, three and four wide. At thickness k exactly the bars up to k are gone,
## which is the claim an erosion can make and a distance threshold cannot: the largest
## distance to background across a bar of width w is ceil(w / 2), so one and two give the
## same number and no threshold separates them.
func _check_thickness_ladder() -> void:
	var bar := ".#.##.###.####.."
	var rows := []
	for _y in 8:
		rows.append(bar)

	var expected := {
		1: "...##.###.####..",
		2: "......###.####..",
		3: "..........####..",
		4: "................",
	}
	for thickness: int in [1, 2, 3, 4]:
		var want := []
		for _y in 8:
			want.append(expected[thickness])
		_expect_picture(_after(rows, thickness, true), want,
				"the thickness ladder is wrong at %d" % thickness)


# --- Detached Only does what it says -----------------------------------

func _check_detached_only() -> void:
	var before := [
		"...........",
		"..#####....",
		"..#####....",
		"..#####....",
		"..#####....",
		"..#####....",
		"....#......",
		"....#......",
		"...........",
	]
	_expect_picture(_after(before, 1, true), before,
			"Detached Only shaved a whisker off something thick enough")

	var shaved := [
		"...........",
		"..#####....",
		"..#####....",
		"..#####....",
		"..#####....",
		"..#####....",
		"...........",
		"...........",
		"...........",
	]
	_expect_picture(_after(before, 1, false), shaved,
			"with Detached Only off the whisker survived, or the block did not")


# --- Reconstruction is all or nothing ----------------------------------

## A one-pixel line with one three-by-three bulge on it. Either the bulge is thick enough
## and the whole line comes with it, or it is not and the bulge goes too. There is no
## in-between, which is the property that separates reconstruction from a plain opening.
func _check_reconstruction() -> void:
	var before := [
		".............",
		".###########.",
		".....###.....",
		".....###.....",
		".............",
	]
	_expect_picture(_after(before, 2, true), before,
			"one thick spot did not carry the rest of its shape")
	_expect_picture(_after(before, 3, true), _blank(13, 5),
			"a shape with nothing thick enough anywhere survived")

	# The same fixture, same thickness, opening rather than reconstruction: only the part
	# that was thick enough stays.
	_expect_picture(_after(before, 2, false), [
		".............",
		".....###.....",
		".....###.....",
		".....###.....",
		".............",
	], "with Detached Only off the plain opening did not fall back to the thick spot")


# --- Antialiasing, in both directions ----------------------------------

func _check_antialiasing() -> void:
	# A one-pixel line with a soft shoulder either side. Its solid part is one pixel, so it
	# goes — and its shoulders must go with it. Leaving them is the faint ghost the Alpha
	# Floor in Refine Edges produces and this stage exists to avoid.
	var ghosted := [
		"-----------",
		"###########",
		"-----------",
	]
	for detached: bool in [true, false]:
		_expect_picture(_after(_pad(ghosted), 1, detached), _blank(11, 5),
				"an erased line left its antialiasing behind (detached_only = %s)" % detached)

	# And the other way: something thick enough comes out with its soft edge exactly as it
	# went in, however wide that edge is. A fixed reclaim of a pixel or two would fail this
	# on any source with a real ramp on it.
	var image := _ramped_block()
	var ctx := IWPipelineContext.from_image(image)
	var alpha_before: PackedFloat32Array = ctx.final_alpha()
	var touched: PackedInt32Array = IWStageKernels.remove_lines(ctx, 1, true)
	_expect(touched.is_empty(),
			"a soft-edged block lost %d pixels it should have kept" % touched.size())
	_expect(ctx.final_alpha() == alpha_before,
			"the soft edge of a kept block was not preserved exactly")


# --- The image edge is background, and that costs nothing --------------

func _check_border() -> void:
	# A block hard against the top and left edges, and a hairline along the bottom one.
	# The block keeps every pixel — the square that measures it may sit inward — and the
	# hairline goes, because out there really is nothing propping it up.
	var before := [
		"####....",
		"####....",
		"####....",
		"####....",
		"........",
		"########",
	]
	var after := [
		"####....",
		"####....",
		"####....",
		"####....",
		"........",
		"........",
	]
	for detached: bool in [true, false]:
		_expect_picture(_after(before, 1, detached), after,
				"the image edge was handled wrongly (detached_only = %s)" % detached)

	# A fully opaque image is not thin at any setting it has room for.
	var solid := []
	for _y in 8:
		solid.append("########")
	for thickness: int in [1, 2, 3, 4]:
		_expect_picture(_after(solid, thickness, true), solid,
				"a fully opaque image lost pixels at thickness %d" % thickness)


# --- The two axes are treated alike ------------------------------------

## The erosion and the dilation use mirrored windows, which only matters when the square
## has an even side — thickness 1, the default. Get the mirror wrong and the result shifts
## by a pixel along each axis, which nothing else here would notice.
func _check_transpose() -> void:
	var before := [
		"..........",
		".##.......",
		".##..#....",
		".##..#....",
		"....##....",
		"..........",
	]
	for thickness: int in [1, 2]:
		for detached: bool in [true, false]:
			var direct := _after(before, thickness, detached)
			var swapped := _transpose(_after(_transpose(before), thickness, detached))
			_expect_picture(direct, swapped,
					"the answer differs along the two axes at thickness %d "
					% thickness + "(detached_only = %s) — check the window mirroring"
					% detached)


# --- Running it twice is running it once -------------------------------

func _check_idempotence() -> void:
	var rows := [
		"..............",
		".#####........",
		"......###.....",
		"..-...###.....",
		"......###.....",
		".#............",
		"..............",
	]
	for detached: bool in [true, false]:
		var ctx := IWPipelineContext.from_image(_image(rows))
		var stage := _stage(1, detached)
		stage.process_context(ctx)
		var once: PackedFloat32Array = ctx.final_alpha()
		stage.process_context(ctx)
		_expect(ctx.final_alpha() == once,
				"a second run changed the answer (detached_only = %s) — the most likely "
				% detached + "cause is the erosion and dilation windows not being mirrored")


# --- Zero is the identity, exactly -------------------------------------

func _check_identity() -> void:
	var ctx := IWPipelineContext.from_image(_image([".#.", "###", ".#."]))
	var coverage_before: PackedFloat32Array = ctx.coverage
	var mask_before: PackedByteArray = ctx.mask
	var stage := _stage(0, true)
	stage.process_context(ctx)
	_expect(ctx.coverage == coverage_before, "a thickness of 0 wrote coverage")
	_expect(ctx.mask == mask_before, "a thickness of 0 wrote the mask")


# --- An Add always wins ------------------------------------------------

func _check_regions() -> void:
	var rows := [
		"........",
		".######.",
		"........",
	]
	var middle := 1 * 8 + 4

	# Protected: one pixel of the hairline is claimed by an Add island. In Detached Only
	# the rest of its shape comes with it, because keeping the painted pixel and erasing
	# what it is part of would look arbitrary.
	var ctx := IWPipelineContext.from_image(_image(rows))
	var protect := PackedByteArray()
	protect.resize(ctx.pixel_count)
	protect[middle] = 1
	ctx.protect = protect
	IWStageKernels.remove_lines(ctx, 1, true)
	_expect_picture(_render(ctx), rows,
			"a protected pixel did not carry the shape it belongs to")

	# A drawn Add region says the same thing by a different route.
	var drawn := IWPipelineContext.from_image(_image(rows))
	var blacked := PackedByteArray()
	blacked.resize(drawn.pixel_count)
	blacked[middle] = IWPipelineContext.REGION_KEEP
	drawn.blacked = blacked
	IWStageKernels.remove_lines(drawn, 1, true)
	_expect_picture(_render(drawn), rows,
			"a drawn Add region did not carry the shape it belongs to")

	# With Detached Only off there is no shape to carry, but the pixel itself still has to
	# survive: it is an instruction, not a measurement.
	var opened := IWPipelineContext.from_image(_image(rows))
	opened.protect = protect
	IWStageKernels.remove_lines(opened, 1, false)
	_expect(opened.final_alpha()[middle] > 0.0,
			"a protected pixel was erased by the plain opening")

	# And a drawn Cut is measured as already gone. It is not folded into the coverage
	# until IWCompose runs, so with no keyer above to have settled it a cut pixel still
	# reads opaque — and a block counted through a cut that halves it would pass as thick
	# enough and leave the sliver behind.
	var block := [
		"........",
		".####...",
		".####...",
		".####...",
		".####...",
		"........",
	]
	var halved := IWPipelineContext.from_image(_image(block))
	var cut := PackedByteArray()
	cut.resize(halved.pixel_count)
	for y in range(1, 5):
		for x in range(3, 5):
			cut[y * 8 + x] = IWPipelineContext.REGION_CUT
	halved.blacked = cut
	IWStageKernels.remove_lines(halved, 2, true)
	# The cut itself only reaches the coverage in IWCompose, so this stands in for it —
	# without it the picture would still show the pixels the cut is about to take.
	halved.apply_regions_to_coverage()
	_expect_picture(_render(halved), _blank(8, 6),
			"a two-pixel column left by a drawn Cut was measured as though the cut "
			+ "half were still there")


# --- It does not undo the stages above it ------------------------------

## The reason [method RemoveLines.process_context] does not end with a
## [method IWPipelineContext.compute_coverage] the way [RemoveCrevice] does. That call
## forces every subject pixel it visits to a coverage of one, which would flatten the
## guided filter's work in a ring around everything erased.
func _check_below_refine_edges() -> void:
	var ctx := IWPipelineContext.from_image(_debris_image())
	_keyer().process_context(ctx)
	_refiner().process_context(ctx)
	if not _expect(ctx.has_classification(), "the fixture did not key, so this proves nothing"):
		return

	var coverage_before: PackedFloat32Array = ctx.coverage
	var touched: PackedInt32Array = IWStageKernels.remove_lines(ctx, 1, true)
	if not _expect(not touched.is_empty(),
			"nothing was erased, so this check would pass for the wrong reason"):
		return

	var erased := {}
	for index: int in touched:
		erased[index] = true
	var moved := 0
	for i in ctx.pixel_count:
		if erased.has(i):
			continue
		if ctx.coverage[i] != coverage_before[i]:
			moved += 1
	_expect(moved == 0,
			"%d pixels that were not erased had their coverage rewritten — " % moved
			+ "something is recomputing coverage from the mask")


# --- What it owes the run afterwards -----------------------------------

func _check_invalidation() -> void:
	var ctx := IWPipelineContext.from_image(_debris_image())
	_keyer().process_context(ctx)
	var stage := _stage(1, true)
	stage.process_context(ctx)

	var erased: PackedInt32Array = PackedInt32Array()
	for i in ctx.pixel_count:
		if ctx.coverage[i] == 0.0 and ctx.mask[i] != IWPipelineContext.MASK_BACKGROUND:
			erased.append(i)
	_expect(erased.is_empty(),
			"%d pixels were erased in coverage but left classified as subject" % erased.size())

	# Every pixel that arrived at a nearest-subject answer must be pointing at something
	# that is still subject. This is what a forgotten rebuild_nearest looks like.
	var stale := 0
	for i in ctx.pixel_count:
		var at: int = ctx.nearest[i]
		if at >= 0 and ctx.mask[at] != IWPipelineContext.MASK_SUBJECT:
			stale += 1
	_expect(stale == 0,
			"%d pixels still name a nearest subject that has been erased" % stale)

	_expect(IWCompose.compose(ctx) != null, "the composed image did not survive")


# --- Fixtures ----------------------------------------------------------

## A block with a three-pixel alpha ramp around it, and nothing thin anywhere.
func _ramped_block() -> Image:
	var size := 16
	var image := Image.create_empty(size, size, false, Image.FORMAT_RGBA8)
	# Whole 1/255 steps, so the comparison afterwards is against bytes rather than against
	# a rounding.
	var ramp := [255, 180, 110, 40]
	for y in size:
		for x in size:
			var reach: int = maxi(maxi(5 - x, x - 10), maxi(5 - y, y - 10))
			var level: int = ramp[reach] if reach >= 0 and reach < ramp.size() else 0
			image.set_pixel(x, y, Color(0.2, 0.6, 0.9, float(level) / 255.0))
	return image


## White ground, a solid subject, and a one-pixel rule across the bottom of it — the shape
## a scan border or a leftover grid line actually arrives in.
func _debris_image() -> Image:
	var image := Image.create_empty(32, 32, false, Image.FORMAT_RGBA8)
	image.fill(Color.WHITE)
	for y in range(6, 20):
		for x in range(6, 20):
			image.set_pixel(x, y, Color8(30, 60, 170))
	for x in 32:
		image.set_pixel(x, 26, Color8(40, 40, 40))
	return image


## The same Remove Background the parity fixtures use, so this file is not inventing a
## second opinion about what keying looks like.
func _keyer() -> IWStackOperation:
	var stage: IWStackOperation = load(OP_REMOVE_BACKGROUND).new()
	var settings := stage.get_settings()
	settings.remove_colors.clear()
	settings.remove_colors.add(Color.WHITE, 0.05)
	settings.edge_width = 2
	settings.contiguous = true
	settings.decontaminate = true
	settings.bleed_radius = 16
	return stage


func _refiner() -> IWStackOperation:
	var stage: IWStackOperation = load(OP_REFINE_EDGES).new()
	var settings := stage.get_settings()
	settings.refine_radius = 2
	settings.alpha_floor = 0.0
	settings.alpha_ceiling = 1.0
	return stage


## Reached through [method load] rather than by its [code]class_name[/code], the way the
## parity harness reaches all of its stages. Naming the type would tie this file to the
## editor having rescanned the project, which a headless run has not done.
func _stage(thickness: int, detached_only: bool) -> IWStackOperation:
	var stage: IWStackOperation = load(OP_REMOVE_LINES).new()
	var settings := stage.get_settings()
	settings.thickness = thickness
	settings.detached_only = detached_only
	return stage


# --- Pictures ----------------------------------------------------------

func _image(rows: Array) -> Image:
	var height := rows.size()
	var width: int = (rows[0] as String).length()
	var image := Image.create_empty(width, height, false, Image.FORMAT_RGBA8)
	for y in height:
		var row: String = rows[y]
		for x in width:
			image.set_pixel(x, y, Color(0.2, 0.6, 0.9, _alpha_for(row[x])))
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
func _after(rows: Array, thickness: int, detached_only: bool) -> Array:
	var ctx := IWPipelineContext.from_image(_image(rows))
	_stage(thickness, detached_only).process_context(ctx)
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


## A clear row above and below, so a fixture about what happens beside a shape is not
## also a fixture about what happens at the image edge.
func _pad(rows: Array) -> Array:
	var width: int = (rows[0] as String).length()
	var out := [".".repeat(width)]
	out.append_array(rows)
	out.append(".".repeat(width))
	return out


func _transpose(rows: Array) -> Array:
	var height := rows.size()
	var width: int = (rows[0] as String).length()
	var out := []
	for x in width:
		var line := ""
		for y in height:
			line += (rows[y] as String)[x]
		out.append(line)
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
