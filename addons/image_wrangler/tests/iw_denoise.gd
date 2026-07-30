extends SceneTree

## The Denoise stage, checked for properties rather than for bytes.
##
## Deliberately not part of [code]tests/iw_parity.gd[/code], and deliberately not in
## [code]Fixtures.OPERATION_SCRIPTS[/code]. That harness exists to prove the GDScript to
## C++ port produces identical bytes, and it does that by hashing recorded baselines.
## Open Image Denoise is a third-party trained model reached through a threaded runtime:
## freezing a hash of its output would be recording someone else's version number, and
## the first OIDN bump would fail the harness for no defect of ours.
##
## So this asserts what the stage promises instead — that the runtime is there, that
## alpha survives, that the filter actually removes noise, and that where the stage sits
## decides what it affects: above a keyer it changes the cut, below one the cut is
## already settled and only the colours move.
##
## [b]One asymmetry worth knowing.[/b] [code]Fixtures.OPERATION_SCRIPTS[/code] is a second
## registry, separate from the dock's, used by [code]_stack_from_sidecar[/code]. Denoise
## is not in it. A [code]denoise[/code] entry appearing in a fixture sidecar would
## therefore be dropped silently rather than failing. No committed fixture has one.
##
## Run it:
## [codeblock]
## godot --headless --path ../.. --script res://addons/image_wrangler/tests/iw_denoise.gd
## [/codeblock]
##
## [b]It exits reporting two leaked instances and one resource still in use, and that is
## not a defect here.[/b] Run with [code]--verbose[/code] and they are
## [code]denoise_settings.gd[/code] and its native class — script classes, released after
## the engine has already counted what is left rather than before. Any harness that
## instantiates a stage with a [code]class_name[/code] does it; the parity harness is
## quiet only because it reaches its stages through [method load] and never names one.
## Chasing it means contorting the test to avoid naming a type, which is a worse trade
## than a line of explanation. The exit code is what to read.

const OP_REMOVE_BACKGROUND := "res://addons/image_wrangler/core/remove_background.gd"

const W := 128
const H := 128

## Where the noise sits, so the numbers below mean the same thing on every run.
const NOISE_SEED := 20260728
const NOISE_RANGE := 0.08

var _failures := 0


func _initialize() -> void:
	var clean := _reference_image()
	var noisy := _add_noise(_reference_image())

	_check_binding()
	_check_kernel(clean, noisy)
	_check_stage(noisy)
	_check_below_keyer(noisy)
	_check_placement(noisy)

	if _failures == 0:
		print("Denoise OK — the runtime resolves, alpha survives, and position decides "
				+ "whether the cut moves.")
	quit(1 if _failures > 0 else 0)


# --- The runtime is present ---------------------------------------------

## The one failure no amount of GDScript can work around: the OIDN DLLs not sitting
## beside the extension where both Godot's loader and OIDN's own module lookup expect
## them.
func _check_binding() -> void:
	_expect(ClassDB.class_has_method("IWStageKernels", "denoise"),
			"IWStageKernels.denoise is not bound — the build did not pick up "
			+ "iw_denoise_kernels.cpp")


# --- The kernel does what it says ---------------------------------------

func _check_kernel(clean: Image, noisy: Image) -> void:
	var ctx := IWPipelineContext.from_image(noisy)
	var before: PackedByteArray = ctx.data
	var ran: bool = IWStageKernels.denoise(ctx, DenoiseSettings.Quality.HIGH, 1.0)
	if not _expect(ran, "denoise() returned false — Open Image Denoise could not be "
			+ "brought up; check the DLLs in addons/image_wrangler/bin/"):
		return
	var after: PackedByteArray = ctx.data

	_expect(after.size() == before.size(), "the buffer changed size")
	_expect(ctx.width == W and ctx.height == H and ctx.pixel_count == W * H,
			"the context's dimensions changed")
	_expect(_alpha_matches(before, after), "alpha was not preserved byte for byte")
	_expect(after != before, "at an amount of 1.0 nothing changed")

	# Closer to the image the noise was added to than the noisy version was. A property,
	# not a hash: it stays true across an OIDN version bump, where a hash would not.
	var reference := clean.get_data()
	var was := _mean_error(before, reference)
	var now := _mean_error(after, reference)
	print("  mean abs error vs the clean reference: %.3f noisy -> %.3f denoised" % [was, now])
	_expect(now < was * 0.8, "the filter did not meaningfully reduce the noise")

	# Two identical runs, two identical answers. OIDN gives no cross-machine
	# reproducibility guarantee, which is exactly why this is here and not in the parity
	# baseline — but within one machine it should not wander.
	var a := IWPipelineContext.from_image(noisy)
	var b := IWPipelineContext.from_image(noisy)
	IWStageKernels.denoise(a, DenoiseSettings.Quality.HIGH, 1.0)
	IWStageKernels.denoise(b, DenoiseSettings.Quality.HIGH, 1.0)
	_expect(a.data == b.data, "two identical runs produced different bytes")


# --- The stage's own decisions ------------------------------------------

func _check_stage(noisy: Image) -> void:
	var stage := Denoise.new()

	# An amount of zero is a request for nothing, and has to be the identity to the last
	# bit rather than a round trip that happens to land back where it started.
	var ctx := IWPipelineContext.from_image(noisy)
	var before: PackedByteArray = ctx.data
	stage.settings.blend = 0.0
	stage.process_context(ctx)
	_expect(ctx.data == before, "an amount of 0.0 was not an exact identity")

	stage.settings.blend = 1.0
	stage.process_context(ctx)
	_expect(ctx.data != before, "the stage did nothing at an amount of 1.0")

	# Naming a suffix here would rename the output of every stack holding a Denoise,
	# since the pipeline takes the first enabled stage that names one.
	_expect(stage.get_output_suffix() == "", "Denoise named an output suffix")
	var pipeline := IWPipeline.new()
	pipeline.stages.append(Denoise.new())
	pipeline.stages.append(_keyer())
	_expect(pipeline.get_output_suffix() == "_nobg",
			"a stack led by Denoise no longer writes _nobg, it writes "
			+ pipeline.get_output_suffix())


# --- Below a keyer it still runs, and disturbs only what it should ------

## The matte is already decided by the time it gets there, so it must not move — but the
## pixels must, and the one map derived from them has to be rebuilt rather than left
## describing colours that are gone.
func _check_below_keyer(noisy: Image) -> void:
	var ctx := IWPipelineContext.from_image(noisy)
	_keyer().process_context(ctx)
	if not _expect(ctx.has_keying, "the fixture's Remove Background did not key anything, "
			+ "so this check would prove nothing"):
		return

	var data_before: PackedByteArray = ctx.data
	var key_dist_before: PackedFloat32Array = ctx.key_dist
	var mask_before: PackedByteArray = ctx.mask
	var coverage_before: PackedFloat32Array = ctx.coverage
	var nearest_before: PackedInt32Array = ctx.nearest

	var stage := Denoise.new()
	stage.settings.blend = 1.0
	stage.process_context(ctx)

	# It ran.
	_expect(ctx.data != data_before, "Denoise did nothing below a keyer")

	# The cut is settled and stays settled: these say which pixels are subject, which is
	# not a question about colour.
	_expect(ctx.mask == mask_before, "the mask moved below a keyer")
	_expect(ctx.coverage == coverage_before, "the alpha moved below a keyer")
	_expect(ctx.nearest == nearest_before, "the nearest-subject map moved below a keyer")

	# And the one thing that is about colour was redone rather than left stale or empty.
	_expect(not ctx.key_dist.is_empty(),
			"key_dist was cleared and not rebuilt — RefineEdges below would silently "
			+ "skip its guided filter")
	_expect(ctx.key_dist != key_dist_before,
			"key_dist still describes the pixels that were replaced")

	_expect(IWCompose.compose(ctx) != null, "the composed image did not survive")


# --- Placement changes the answer ---------------------------------------

## The whole point of the stage being reorderable: above the keyer it changes the cut,
## below it the cut is already made and only the colours change.
func _check_placement(noisy: Image) -> void:
	var above := IWPipelineContext.from_image(noisy)
	var denoise := Denoise.new()
	denoise.settings.blend = 1.0
	denoise.process_context(above)
	_keyer().process_context(above)

	var below := IWPipelineContext.from_image(noisy)
	_keyer().process_context(below)
	Denoise.new().process_context(below)

	var neither := IWPipelineContext.from_image(noisy)
	_keyer().process_context(neither)

	# Above: a different matte, because the keyer measured different pixels.
	_expect(above.coverage != neither.coverage,
			"denoising above the keyer did not change the cut, which is the reason to "
			+ "put it there")

	# Below: the same matte as no denoise at all, and different pixels.
	_expect(below.coverage == neither.coverage,
			"denoising below the keyer changed the cut, which it must not")
	_expect(below.data != neither.data, "denoising below the keyer changed no pixels")

	var composed := IWCompose.compose(above)
	_expect(composed != null and composed.get_width() == W and composed.get_height() == H,
			"the composed image did not survive the rewrite")


# --- Helpers ------------------------------------------------------------

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


func _expect(condition: bool, message: String) -> bool:
	if not condition:
		printerr("FAIL: %s" % message)
		_failures += 1
	return condition


func _alpha_matches(a: PackedByteArray, b: PackedByteArray) -> bool:
	for i in W * H:
		if a[i * 4 + 3] != b[i * 4 + 3]:
			return false
	return true


## Mean absolute per-channel difference over RGB, in 0-255 units.
func _mean_error(a: PackedByteArray, b: PackedByteArray) -> float:
	var total := 0.0
	for i in W * H:
		for c in 3:
			total += absf(float(a[i * 4 + c]) - float(b[i * 4 + c]))
	return total / float(W * H * 3)


## White ground so the keyer above has something to key, one solid block, and a ramp —
## a flat field, a hard edge and a gradient, which is enough for "did it blur the edge"
## to be a fair question.
func _reference_image() -> Image:
	var image := Image.create_empty(W, H, false, Image.FORMAT_RGBA8)
	image.fill(Color.WHITE)
	for y in H:
		for x in W:
			if x > 30 and x < 90 and y > 30 and y < 90:
				image.set_pixel(x, y, Color(0.2, 0.5, 0.8))
			elif y > 100:
				image.set_pixel(x, y, Color(0.3 + 0.4 * float(x) / float(W), 0.3, 0.3))
	return image


func _add_noise(image: Image) -> Image:
	var rng := RandomNumberGenerator.new()
	rng.seed = NOISE_SEED
	for y in H:
		for x in W:
			var c := image.get_pixel(x, y)
			c.r = clampf(c.r + rng.randf_range(-NOISE_RANGE, NOISE_RANGE), 0.0, 1.0)
			c.g = clampf(c.g + rng.randf_range(-NOISE_RANGE, NOISE_RANGE), 0.0, 1.0)
			c.b = clampf(c.b + rng.randf_range(-NOISE_RANGE, NOISE_RANGE), 0.0, 1.0)
			image.set_pixel(x, y, c)
	return image
