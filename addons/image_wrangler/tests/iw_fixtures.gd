@tool
extends RefCounted

## Fixtures for the parity harness: deterministic images, and the stacks run over them.
##
## Synthetic rather than sampled, for everything but the one real sheet. A parity test
## wants inputs it can reason about — this many pixels of exactly this colour against
## exactly that background — and it wants them small, because the gate is run after
## every ported function and a megapixel round trip through the GDScript reference is
## not something anyone will do twenty times.
##
## Every image here is built from integer arithmetic with no call to [method @GlobalScope.randf],
## so the bytes are identical on every machine and every run. That matters more than it
## looks: the golden hashes are taken once, from this code, and then checked against
## forever.

## The one real fixture, copied out of the (gitignored) sample folder so the harness
## does not depend on data that is not in the repo.
const SHEET_PNG := "res://addons/image_wrangler/tests/fixtures/sheet.png"

## Where [method IWSettingsIO.sidecar_path] resolves [constant SHEET_PNG] to. Named here
## so the file is findable by grep, and never passed to the codec — that takes the image's
## path and works the sidecar's out, and handing it this one would send it looking for
## [code]sheet_wrangler_wrangler.json[/code].
const SHEET_JSON := "res://addons/image_wrangler/tests/fixtures/sheet_wrangler.json"

const OP_REMOVE_BACKGROUND := "res://addons/image_wrangler/core/remove_background.gd"
const OP_REMOVE_CREVICE := "res://addons/image_wrangler/core/remove_crevice.gd"
const OP_REFINE_EDGES := "res://addons/image_wrangler/core/refine_edges.gd"
const OP_ISLAND_PICKER := "res://addons/image_wrangler/core/island_picker_op.gd"
const OP_POLYGON_EDIT := "res://addons/image_wrangler/core/polygon_edit_op.gd"
const OP_EDGE_CLEANUP := "res://addons/image_wrangler/core/edge_cleanup.gd"

## Every operation the sidecar codec may name, for [method IWSettingsIO.load_stack].
## The same set the dock offers; kept here rather than reached for through the dock so
## the harness never loads a single editor control.
const OPERATION_SCRIPTS := [
	OP_REMOVE_BACKGROUND,
	OP_REMOVE_CREVICE,
	OP_REFINE_EDGES,
	OP_ISLAND_PICKER,
	OP_POLYGON_EDIT,
	OP_EDGE_CLEANUP,
]


# --- Images -------------------------------------------------------------

## White ground, one solid block. The simplest thing the keyer can be asked to do:
## a border flood that reaches everywhere, one hard edge, no ambiguity anywhere.
static func flat(size := 64) -> Image:
	var image := _white(size, size)
	_fill_rect(image, Rect2i(size / 4, size / 4, size / 2, size / 2), Color8(40, 60, 180))
	return image


## A ring of subject with background trapped inside it.
##
## The case the whole Island Picker exists for: the middle is the same white as the
## outside and no border flood can ever reach it, so a run without an island must leave
## it opaque and a run with one must take it out.
static func enclosed(size := 64) -> Image:
	var image := _white(size, size)
	var margin := size / 6
	_fill_rect(image, Rect2i(margin, margin, size - margin * 2, size - margin * 2), Color8(30, 150, 60))
	var hole := size / 4
	_fill_rect(image, Rect2i(hole, hole, size - hole * 2, size - hole * 2), Color.WHITE)
	return image


## Near-white ground with per-pixel noise, and a round subject.
##
## What a re-compressed or scanned background actually looks like, and the reason
## tolerance exists. Also the fixture that exercises the crevice rule, since the noise
## puts pixels just outside the key's own tolerance all over the ground.
static func speckled(size := 64) -> Image:
	var image := Image.create_empty(size, size, false, Image.FORMAT_RGBA8)
	var noise := _Lcg.new(0x5EED)
	for y in size:
		for x in size:
			# 236..255 per channel, independently, so the noise is coloured rather
			# than a grey ramp — a grey one would be keyed out by a single tolerance
			# and prove nothing.
			var r := 236 + noise.below(20)
			var g := 236 + noise.below(20)
			var b := 236 + noise.below(20)
			image.set_pixel(x, y, Color8(r, g, b))
	var centre := size / 2
	var radius := size / 4
	for y in size:
		for x in size:
			var dx := x - centre
			var dy := y - centre
			if dx * dx + dy * dy <= radius * radius:
				image.set_pixel(x, y, Color8(20, 40, 200))
	return image


## An image that has already been through the pipeline once: transparent outside, a
## soft alpha ramp, opaque core.
##
## Every flood here has a separate answer for a pixel that arrived fully transparent —
## it is open ground, crossed freely, carrying no colour of its own — and nothing else
## in this set reaches that path.
static func translucent(size := 48) -> Image:
	var image := Image.create_empty(size, size, false, Image.FORMAT_RGBA8)
	var centre := float(size) * 0.5
	for y in size:
		for x in size:
			var dx := float(x) - centre + 0.5
			var dy := float(y) - centre + 0.5
			var distance := sqrt(dx * dx + dy * dy)
			# Quantised to whole 1/255 steps so the fixture survives a PNG round trip
			# byte for byte, which a continuous ramp would not.
			var alpha := clampf((float(size) * 0.35 - distance) / 4.0, 0.0, 1.0)
			var quantised := float(roundi(alpha * 255.0)) / 255.0
			image.set_pixel(x, y, Color(0.9, 0.3, 0.2, quantised))
	return image


## A background that is a different distance from the key at every column.
##
## Coverage is a ratio of distances, and decontamination divides by alpha; both are
## quietly correct on a flat ground and only become interesting when the ground itself
## slides away from the key.
static func gradient(size := 32) -> Image:
	var image := Image.create_empty(size, size, false, Image.FORMAT_RGBA8)
	for y in size:
		for x in size:
			var level := 255 - (x * 48) / maxi(size - 1, 1)
			image.set_pixel(x, y, Color8(level, level, level))
	_fill_rect(image, Rect2i(size / 3, 0, size / 3, size), Color8(10, 10, 10))
	return image


## Two by two: the smallest image where a pixel has neighbours on some sides and not
## others, which is what every [code]x < width - 1[/code] guard in every flood is for.
static func tiny() -> Image:
	var image := Image.create_empty(2, 2, false, Image.FORMAT_RGBA8)
	image.set_pixel(0, 0, Color.WHITE)
	image.set_pixel(1, 0, Color.WHITE)
	image.set_pixel(0, 1, Color8(0, 0, 0))
	image.set_pixel(1, 1, Color8(0, 0, 0))
	return image


## One pixel, where every neighbour guard is false at once and width - 1 is zero.
static func single() -> Image:
	var image := Image.create_empty(1, 1, false, Image.FORMAT_RGBA8)
	image.set_pixel(0, 0, Color.WHITE)
	return image


static func _white(width: int, height: int) -> Image:
	var image := Image.create_empty(width, height, false, Image.FORMAT_RGBA8)
	image.fill(Color.WHITE)
	return image


static func _fill_rect(image: Image, rect: Rect2i, color: Color) -> void:
	for y in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			if x >= 0 and y >= 0 and x < image.get_width() and y < image.get_height():
				image.set_pixel(x, y, color)


## A linear congruential generator, so the noise fixture is the same on every machine.
##
## The engine's own RNG would do, but only while nobody reseeds it and only while its
## algorithm never changes. This is four lines and it cannot drift.
class _Lcg extends RefCounted:
	var _state: int

	func _init(seed_value: int) -> void:
		_state = seed_value & 0xFFFFFFFF

	## The next value in [code][0, limit)[/code], taken from the high bits, which is
	## where an LCG's randomness actually lives.
	func below(limit: int) -> int:
		_state = (_state * 1664525 + 1013904223) & 0xFFFFFFFF
		return ((_state >> 16) & 0xFFFF) % limit


# --- Stacks -------------------------------------------------------------

## Remove Background alone, keying white.
##
## The baseline stack: whatever else breaks, this one failing means the flood itself
## has changed.
static func stack_minimal() -> Array[IWStackOperation]:
	var stages: Array[IWStackOperation] = []
	stages.append(_remove_background())
	return stages


## Every stage at once, in the order a version 1 file splits into.
##
## All six on purpose. A stack that leaves one out is a stack whose ported code is not
## being checked, and the whole point of the harness is that no pass goes unwatched.
## [param size] scales the coordinates the island and the polygon are placed at, so the
## same stack means the same thing on a 64 pixel fixture and a 512 pixel one.
static func stack_full(size: int, auto_stroke := false) -> Array[IWStackOperation]:
	var stages: Array[IWStackOperation] = []
	stages.append(_polygon_edit(size))
	stages.append(_remove_background())
	stages.append(_island_picker(size))
	stages.append(_remove_crevice())
	stages.append(_refine_edges())
	stages.append(_edge_cleanup(auto_stroke))
	return stages


## Remove Background and Remove Crevice alone, at a stated tolerance.
##
## Isolates the flood from everything downstream of it. A tolerance of 0.01 is where a
## flood that crosses a boundary it should not is most visible: at 0.05 a pixel a step
## over the line is still nearly within reach, where at 0.01 it is five times outside and
## the answer is unambiguous.
##
## [param crevice_reach] of zero switches the crevice rule off, which is the control:
## with the rule on, a colour keyed at 0.01 may still stray to 0.01 + [param crevice_tolerance],
## and telling the two apart is most of the question when a flood looks too eager.
static func stack_keying(
		tolerance: float, crevice_reach: int, crevice_tolerance := 0.25) -> Array[IWStackOperation]:
	var stages: Array[IWStackOperation] = []
	var background := _remove_background()
	background.get_settings().remove_colors.clear()
	background.get_settings().remove_colors.add(Color.WHITE, tolerance)
	stages.append(background)

	var crevice: IWStackOperation = load(OP_REMOVE_CREVICE).new()
	crevice.get_settings().crevice_reach = crevice_reach
	crevice.get_settings().crevice_tolerance = crevice_tolerance
	stages.append(crevice)
	return stages


static func _remove_background() -> IWStackOperation:
	var stage: IWStackOperation = load(OP_REMOVE_BACKGROUND).new()
	var settings := stage.get_settings()
	settings.remove_colors.clear()
	settings.remove_colors.add(Color.WHITE, 0.05)
	settings.edge_width = 2
	settings.contiguous = true
	settings.decontaminate = true
	settings.bleed_radius = 16
	return stage


static func _remove_crevice() -> IWStackOperation:
	var stage: IWStackOperation = load(OP_REMOVE_CREVICE).new()
	var settings := stage.get_settings()
	settings.crevice_reach = 1
	settings.crevice_tolerance = 0.17
	return stage


static func _refine_edges() -> IWStackOperation:
	var stage: IWStackOperation = load(OP_REFINE_EDGES).new()
	var settings := stage.get_settings()
	settings.refine_radius = 2
	settings.alpha_floor = 0.41
	settings.alpha_ceiling = 0.8
	return stage


## An island in the dead centre, which for the enclosed fixture is the trapped white,
## and a second one picked as a dragged region rather than a click so the grouped
## multi-pick path is exercised too.
static func _island_picker(size: int) -> IWStackOperation:
	var stage: IWStackOperation = load(OP_ISLAND_PICKER).new()
	var settings := stage.get_settings()
	var centre := size / 2
	settings.islands.add(Vector2i(centre, centre))
	if size >= 16:
		var span := maxi(size / 16, 2)
		settings.islands.add_region(Rect2i(centre - span, centre - span, span * 2, span * 2))
	return stage


## A triangle in the top-left corner, subtracted.
##
## Deliberately not axis-aligned: the scanline fill crosses edges at fractional x and
## sorts the crossings, and a rectangle would never exercise either.
static func _polygon_edit(size: int) -> IWStackOperation:
	var stage: IWStackOperation = load(OP_POLYGON_EDIT).new()
	var settings := stage.get_settings()
	if size >= 8:
		var region := PolygonRegion.new()
		# Built by hand rather than through PolygonRegionList.add(), which calls
		# PolygonRegion.create() and takes a random swatch colour. Nothing reads that
		# colour while processing, but a fixture with a random field in it is a fixture
		# waiting to be hashed by mistake.
		region.color = Color(0.2, 0.8, 0.9)
		region.mode = IWAlphaMode.Mode.SUBTRACT
		var reach := maxi(size / 5, 3)
		region.points = [Vector2i(0, 0), Vector2i(reach, 0), Vector2i(0, reach)]
		settings.polygons.regions.append(region)
	return stage


static func _edge_cleanup(auto_stroke: bool) -> IWStackOperation:
	var stage: IWStackOperation = load(OP_EDGE_CLEANUP).new()
	var settings := stage.get_settings()
	settings.inner_stroke_width = 0.5
	settings.outer_stroke_width = 0.5
	settings.stroke_softness = 0.75
	settings.auto_stroke_color = auto_stroke
	settings.stroke_color = Color(0.0, 0.0, 0.0, 1.0)
	return stage
