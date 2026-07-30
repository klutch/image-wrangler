extends SceneTree

## Bit-exact parity harness for the GDExtension port.
##
## The pixel code is being moved from GDScript to C++ a function at a time, and the
## contract is that the bytes coming out do not change. Nothing else about the addon
## says whether that held: the settings self-test checks the codec, and the preview
## checks whether a person notices. A flood that claims one pixel differently, or a
## quantise that rounds a half the other way, is invisible in both and permanent.
##
## So the reference is recorded once, from the GDScript, and checked forever after:
## [code]--record[/code] writes [code]tests/golden/baseline.json[/code], and every run
## without it compares against that file. The GDScript implementations are deleted as
## they are ported, which is exactly why the reference has to be [i]data[/i] rather than
## a second implementation to run alongside.
##
## [b]Per stage and per buffer, not just the final image.[/b] A mismatch on the composed
## PNG says only that something, somewhere, in a stack of six operations, changed. A
## mismatch on [code]mask[/code] after Remove Background names the pass. That is the
## difference between an afternoon and a minute.
##
## Run it:
## [codeblock]
## godot --headless --path <project> --script res://addons/image_wrangler/tests/iw_parity.gd -- --record
## godot --headless --path <project> --script res://addons/image_wrangler/tests/iw_parity.gd
## [/codeblock]

const Fixtures := preload("res://addons/image_wrangler/tests/iw_fixtures.gd")
const SettingsIO := preload("res://addons/image_wrangler/core/iw_settings_io.gd")

const GOLDEN_PATH := "res://addons/image_wrangler/tests/golden/baseline.json"
const DUMP_DIR := "res://addons/image_wrangler/tests/dump"

## Every per-pixel buffer on the context, hashed after each stage.
##
## All of them, including the ones a given stack never fills. An empty buffer hashes
## differently from a filled one, so "this stage stopped writing strayed at all" is a
## failure this catches rather than one it shrugs at.
const BUFFERS := [
	&"mask", &"key_of", &"coverage", &"key_dist", &"nearest",
	&"blacked", &"protect", &"strayed", &"force_opaque",
	&"stroke_inner", &"stroke_outer", &"stroke_colors", &"key_is_island",
]

## Run parameters and flags that stages write onto the context for those below them.
## Cheap to record and they catch a whole class of mistake the buffers cannot: a stage
## that computes the right pixels but forgets to declare the search radius.
const SCALARS := [
	&"width", &"height", &"pixel_count",
	&"edge_width", &"bleed_radius", &"search_radius", &"decontaminate",
	&"crevice_reach", &"crevice_tolerance", &"has_keying",
]

## The awkward inputs for the scalar helpers, shared by the GDScript probe and the
## native one so the two are answering the same question.
##
## Every one is a real trap. The halves separate round-half-away-from-zero from
## round-half-to-even; 0.49999999999999994 is the largest double below a half, which
## rounds to 1 under a naive floor(x + 0.5); the crossed clamp bounds have no defined
## answer in std::clamp; the lerp weights of exactly 0 and 1 are where the two algebraic
## forms of an interpolation stop agreeing; and 16777217 is the first integer float32
## cannot represent.
const ROUND_INPUTS := [-2.5, -1.5, -0.5, -0.0, 0.0, 0.49999999999999994, 0.5, 1.5, 2.5, 2.675]
const CLAMP_INPUTS := [
	[0.5, 0.0, 1.0], [-1.0, 0.0, 1.0], [2.0, 0.0, 1.0], [0.5, 1.0, 0.0], [-0.0, 0.0, 1.0],
]
const LERP_INPUTS := [
	[0.1, 0.3, 0.5], [0.0, 1.0, 0.0], [0.0, 1.0, 1.0], [1e16, 1.0, 0.5], [0.1, 0.2, 0.7],
]
const NARROW_INPUTS := [0.1, 1.0 / 3.0, 0.49999999999999994, 16777217.0, 1e-45]

var _failures: Array[String] = []
var _checked := 0


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var recording := args.has("--record")

	var results := {}
	results["math"] = _probe_math()
	results["kernels"] = _probe_kernels()
	var cases := _build_cases()
	for entry: Dictionary in cases:
		results[entry["name"]] = _run_case(entry)

	if recording:
		_write_golden(results)
		print("Recorded %d cases to %s" % [cases.size(), GOLDEN_PATH])
		quit(0)
		return

	var golden := _read_golden()
	if golden.is_empty():
		printerr("No baseline at %s. Run with -- --record first." % GOLDEN_PATH)
		quit(2)
		return

	_compare(golden, results)
	_report()
	quit(1 if not _failures.is_empty() else 0)


# --- Cases --------------------------------------------------------------

func _build_cases() -> Array:
	var cases := [
		# The synthetic set. Small enough to dump whole, and each one aimed at a path
		# the others do not reach; see iw_fixtures.gd for what each is for.
		{"name": "flat_minimal", "image": Fixtures.flat(64), "stack": Fixtures.stack_minimal(), "dump": true},
		{"name": "flat_full", "image": Fixtures.flat(64), "stack": Fixtures.stack_full(64), "dump": true},
		{"name": "enclosed_full", "image": Fixtures.enclosed(64), "stack": Fixtures.stack_full(64), "dump": true},
		{"name": "speckled_full", "image": Fixtures.speckled(64), "stack": Fixtures.stack_full(64), "dump": true},
		{"name": "translucent_full", "image": Fixtures.translucent(48), "stack": Fixtures.stack_full(48), "dump": true},
		{"name": "gradient_auto_stroke", "image": Fixtures.gradient(32), "stack": Fixtures.stack_full(32, true), "dump": true},
		{"name": "tiny_minimal", "image": Fixtures.tiny(), "stack": Fixtures.stack_minimal(), "dump": true},
		{"name": "single_minimal", "image": Fixtures.single(), "stack": Fixtures.stack_minimal(), "dump": true},

		# Tight tolerances, where a flood that reaches one pixel too far shows up as a
		# flood that reaches everywhere. The set above runs at 0.05, which turned out to
		# be loose enough to hide a whole class of question.
		#
		# Each tolerance is run twice, once with the crevice rule and once without,
		# because the two answer different questions. Without it a flood may only cross
		# what its own tolerance covers; with it a colour keyed at 0.01 may stray to 0.26,
		# and a flood that looks far too eager at a tight tolerance is far more often that
		# rule working as designed than the flood being wrong.
		{"name": "tol001_speckled_crevice", "image": Fixtures.speckled(64),
			"stack": Fixtures.stack_keying(0.01, 1), "dump": true},
		{"name": "tol001_speckled_nocrevice", "image": Fixtures.speckled(64),
			"stack": Fixtures.stack_keying(0.01, 0), "dump": true},
		{"name": "tol001_gradient_crevice", "image": Fixtures.gradient(32),
			"stack": Fixtures.stack_keying(0.01, 1), "dump": true},
		{"name": "tol001_gradient_nocrevice", "image": Fixtures.gradient(32),
			"stack": Fixtures.stack_keying(0.01, 0), "dump": true},
		{"name": "tol001_enclosed_crevice", "image": Fixtures.enclosed(64),
			"stack": Fixtures.stack_keying(0.01, 1), "dump": true},
		{"name": "tol0001_speckled_nocrevice", "image": Fixtures.speckled(64),
			"stack": Fixtures.stack_keying(0.001, 0), "dump": true},
		# Tolerance zero: nothing may be crossed that is not the key exactly. Any pixel
		# claimed beyond the flat ground is a flood going somewhere it was not invited.
		{"name": "tol000_speckled_nocrevice", "image": Fixtures.speckled(64),
			"stack": Fixtures.stack_keying(0.0, 0), "dump": true},
	]

	# The real one, last, because it is the slow one. Its sidecar is a version 1 file,
	# so this case also drags the whole v1 migration through on every run — which is
	# worth having, since nothing else here does.
	var sheet := _load_png(Fixtures.SHEET_PNG)
	if sheet == null:
		push_warning("Parity: %s missing; skipping the real-image cases." % Fixtures.SHEET_PNG)
		return cases

	var sidecar := _stack_from_sidecar(Fixtures.SHEET_PNG)
	if not sidecar.is_empty():
		cases.append({"name": "sheet_sidecar", "image": sheet, "stack": sidecar, "dump": false})
	var size := maxi(sheet.get_width(), sheet.get_height())
	cases.append({"name": "sheet_full", "image": sheet, "stack": Fixtures.stack_full(size), "dump": false})
	# The tight tolerances on real artwork too. A synthetic fixture has flat grounds and
	# hard edges by construction; a drawing has neither, and the pixels where a flood
	# decides whether to keep going are exactly the ones a drawing is made of.
	cases.append({"name": "sheet_tol001_crevice", "image": sheet,
		"stack": Fixtures.stack_keying(0.01, 1), "dump": false})
	cases.append({"name": "sheet_tol001_nocrevice", "image": sheet,
		"stack": Fixtures.stack_keying(0.01, 0), "dump": false})
	return cases


## Rebuilds a saved stack the way the dock does, through the real codec.
##
## Deliberately the same route rather than a shortcut: a sidecar that stops loading is
## as much a regression as a flood that stops flooding, and this is the only place the
## harness would notice.
##
## [param path] is the [i]image[/i], not its sidecar, because that is what the codec
## takes. This used to be handed the sidecar and worked anyway, on the coincidence that
## the name was the image's with the extension swapped — so replacing an extension with
## [code].json[/code] twice landed on the same file. It is not a coincidence any more.
func _stack_from_sidecar(path: String) -> Array[IWStackOperation]:
	var stages: Array[IWStackOperation] = []
	var registry := {}
	for script_path: String in Fixtures.OPERATION_SCRIPTS:
		var script: Script = load(script_path)
		if script == null:
			continue
		var probe: IWOperation = script.new()
		registry[probe.get_operation_id()] = script

	for entry: Dictionary in SettingsIO.load_stack(path, registry):
		var script: Variant = registry.get(entry["id"])
		if not (script is Script):
			continue
		var stage: IWStackOperation = (script as Script).new()
		var settings: Resource = entry["settings"]
		stage.clamp_settings_to_schema(settings)
		stage.set_settings(settings)
		stage.enabled = bool(entry.get("enabled", true))
		stages.append(stage)
	return stages


## Runs one case and returns everything worth remembering about it.
##
## The stages are driven here rather than through [method IWPipeline.process_image]
## because the context has to be readable between them — that is where the per-buffer
## hashes come from. The pipeline is then run separately over the same input, so the
## production entry point is covered too and cannot quietly drift from this loop.
func _run_case(entry: Dictionary) -> Dictionary:
	var image: Image = entry["image"]
	var stages: Array = entry["stack"]
	var record := {}

	var ctx := IWPipelineContext.from_image(image)
	var stage_records := []
	for i in stages.size():
		var stage: IWStackOperation = stages[i]
		if not stage.enabled:
			continue
		stage.process_context(ctx)
		var snapshot := _snapshot(ctx)
		snapshot["id"] = String(stage.get_operation_id())
		stage_records.append(snapshot)
		if bool(entry.get("dump", false)):
			_dump(entry["name"], i, String(stage.get_operation_id()), ctx)
	record["stages"] = stage_records
	record["final"] = _hash_bytes(IWCompose.compose(ctx).get_data())

	# The same input through the real entry point. A different answer here means the
	# pipeline's own plumbing changed, not the pixel maths.
	var pipeline := IWPipeline.new()
	var fresh: Array[IWStackOperation] = []
	for stage: IWStackOperation in stages:
		fresh.append(stage)
	pipeline.stages = fresh
	record["pipeline"] = _hash_bytes(pipeline.process_image(image).get_data())
	return record


# --- Snapshots ----------------------------------------------------------

## Every buffer and scalar on the context, as hashes and values.
func _snapshot(ctx: IWPipelineContext) -> Dictionary:
	var out := {}
	var buffers := {}
	for name: StringName in BUFFERS:
		buffers[String(name)] = _hash_buffer(ctx.get(name))
	out["buffers"] = buffers

	var scalars := {}
	for name: StringName in SCALARS:
		scalars[String(name)] = ctx.get(name)
	scalars["stroke_color"] = _color_text(ctx.stroke_color)
	out["scalars"] = scalars

	# The key list is not a per-pixel buffer but every flood reads it, and an extra or
	# missing key changes what every other pass concludes.
	out["keys"] = _hash_buffer(_keys_bytes(ctx.keys))
	out["key_tolerances"] = _hash_buffer(PackedFloat64Array(ctx.key_tolerances))
	return out


## A Packed*Array, hashed. Anything with to_byte_array is taken byte for byte, which is
## what makes this exact rather than approximate — a float32 that differs in its last
## bit is a different hash, and that is the point.
func _hash_buffer(buffer: Variant) -> String:
	if buffer == null:
		return "null"
	var bytes: PackedByteArray
	if buffer is PackedByteArray:
		bytes = buffer
	elif buffer is PackedInt32Array or buffer is PackedFloat32Array or buffer is PackedFloat64Array:
		bytes = buffer.to_byte_array()
	else:
		return "unsupported:%s" % typeof(buffer)
	return "%d:%s" % [bytes.size(), _hash_bytes(bytes)]


static func _keys_bytes(keys: Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for key: Color in keys:
		out.append(key.r)
		out.append(key.g)
		out.append(key.b)
		out.append(key.a)
	return out


## SHA-256 of some bytes, or a marker for none.
##
## The empty case is named rather than hashed because [method HashingContext.update]
## refuses a zero-length buffer. It is a real state and a common one — most of the
## context's buffers stay empty for a stack that never needs them — so it has to hash
## to something stable rather than to whatever the last call left behind.
static func _hash_bytes(bytes: PackedByteArray) -> String:
	if bytes.is_empty():
		return "empty"
	var hasher := HashingContext.new()
	hasher.start(HashingContext.HASH_SHA256)
	hasher.update(bytes)
	return hasher.finish().hex_encode()


## Full precision, because a colour recorded to three decimals would hide exactly the
## kind of drift this harness exists to find. [method @GlobalScope.var_to_str] prints
## a float with enough digits to read back as the same float, which [code]str[/code]
## does not promise.
static func _color_text(color: Color) -> String:
	return "%s,%s,%s,%s" % [
		var_to_str(color.r), var_to_str(color.g), var_to_str(color.b), var_to_str(color.a),
	]


# --- Scalar semantics ---------------------------------------------------

## What GDScript's rounding, clamping and interpolation actually do at the awkward
## inputs.
##
## Recorded as part of the baseline so the C++ compatibility helpers have something to
## be right against. Every one of these is a real trap: roundi rounds half away from
## zero where C++'s nearbyint rounds half to even, and lerpf is defined as
## [code]a + (b - a) * w[/code], which is not the same number as [code](1 - w) * a + w * b[/code].
##
## Once IWMathCompat exists on the C++ side this also runs the native versions and
## compares, which is what turns the record from documentation into a test.
func _probe_math() -> Dictionary:
	var out := {}
	var rounded := []
	for value: float in ROUND_INPUTS:
		rounded.append(roundi(value))
	out["roundi"] = rounded

	var clamped := []
	for triple: Array in CLAMP_INPUTS:
		clamped.append(var_to_str(clampf(triple[0], triple[1], triple[2])))
	out["clampf"] = clamped

	var lerped := []
	for triple: Array in LERP_INPUTS:
		lerped.append(var_to_str(lerpf(triple[0], triple[1], triple[2])))
	out["lerpf"] = lerped

	# float32 narrowing, which every PackedFloat32Array store performs and every read
	# undoes. Anywhere the C++ keeps a value in double across a store the GDScript
	# rounded through float32, the answers part company here first.
	var narrowed := []
	for value: float in PackedFloat32Array(NARROW_INPUTS):
		narrowed.append(var_to_str(value))
	out["float32"] = narrowed

	if ClassDB.class_exists("IWMathCompat"):
		out["native"] = _probe_native_math()
	return out


## The native helpers over the same inputs.
##
## Absent from the baseline, which was recorded before any C++ existed, so these are
## checked against the GDScript answers from the same run rather than against the file.
## That is the stronger check anyway: it asks whether the two agree now, on this
## machine, with this compiler.
func _probe_native_math() -> Dictionary:
	var native: Variant = ClassDB.instantiate("IWMathCompat")
	var rounded := []
	for value: float in ROUND_INPUTS:
		rounded.append(native.roundi(value))
	var clamped := []
	for triple: Array in CLAMP_INPUTS:
		clamped.append(var_to_str(native.clampf(triple[0], triple[1], triple[2])))
	var lerped := []
	for triple: Array in LERP_INPUTS:
		lerped.append(var_to_str(native.lerpf(triple[0], triple[1], triple[2])))
	var narrowed := []
	for value: float in NARROW_INPUTS:
		narrowed.append(var_to_str(native.narrow(value)))
	return {"roundi": rounded, "clampf": clamped, "lerpf": lerped, "float32": narrowed}


# --- Shared kernels -----------------------------------------------------

## [IWPixelMath] driven directly, rather than only through the stages that use it.
##
## Both kernels are reached by the pipeline cases already, but only at the radii and
## magnitudes those stacks happen to ask for, and a failure there points at the stage
## rather than at the kernel. These call them at the edges instead: a radius of zero, a
## radius wider than the image, an empty seed list, and values large enough to matter.
func _probe_kernels() -> Dictionary:
	var out := {}
	var width := 7
	var height := 5

	var ramp := PackedFloat32Array()
	for i in width * height:
		ramp.append(float(i) * 0.37 - 3.0)
	var means := {}
	for radius: int in [0, 1, 2, 9]:
		means[str(radius)] = _hash_buffer(IWPixelMath.box_mean(ramp, width, height, radius))
	out["box_mean"] = means

	# Large enough that a float32 summed-area table stops being able to count single
	# pixels: at a running total near 3.5e8 the gap between representable float32s is
	# 32, and every value here differs from its neighbour by 1. This is the one probe
	# that fails loudly if the port "tidies" the float64 accumulator away, and the ramp
	# above would not notice.
	var large := PackedFloat32Array()
	for i in width * height:
		large.append(1.0e7 + float(i))
	out["box_mean_large"] = _hash_buffer(IWPixelMath.box_mean(large, width, height, 2))

	var seeds := PackedInt32Array([0, width * height - 1, (height / 2) * width + width / 2])
	var fires := {}
	for radius: int in [0, 1, 3, 99]:
		fires[str(radius)] = _hash_buffer(IWPixelMath.grassfire(seeds, width, height, radius))
	out["grassfire"] = fires
	# A real call rather than a contrived one: dilate makes exactly this whenever a
	# stage touched nothing.
	out["grassfire_empty"] = _hash_buffer(
			IWPixelMath.grassfire(PackedInt32Array(), width, height, 3))
	return out


# --- Golden file --------------------------------------------------------

func _write_golden(results: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(GOLDEN_PATH).get_base_dir())
	var file := FileAccess.open(GOLDEN_PATH, FileAccess.WRITE)
	if file == null:
		printerr("Cannot write %s: %s" % [GOLDEN_PATH, error_string(FileAccess.get_open_error())])
		return
	# Sorted keys and full precision: this file is read by people diffing two runs, and
	# a reordered dictionary would bury the one line that changed.
	file.store_string(JSON.stringify(results, "\t", true, true))
	file.close()


func _read_golden() -> Dictionary:
	if not FileAccess.file_exists(GOLDEN_PATH):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(GOLDEN_PATH))
	return parsed if parsed is Dictionary else {}


# --- Comparison ---------------------------------------------------------

func _compare(golden: Dictionary, results: Dictionary) -> void:
	for name: String in golden.keys():
		if not results.has(name):
			_fail("%s: case is in the baseline but was not run" % name)
	for name: String in results.keys():
		if not golden.has(name):
			_fail("%s: case ran but is not in the baseline (re-record?)" % name)
			continue
		if name == "math":
			_compare_math(golden[name], results[name])
			continue
		if name == "kernels":
			_compare_tree(name, golden[name], results[name])
			continue
		_compare_case(name, golden[name], results[name])


## Walks two nested dictionaries of the same shape, comparing the leaves.
func _compare_tree(label: String, golden: Variant, current: Variant) -> void:
	if golden is Dictionary and current is Dictionary:
		var expected: Dictionary = golden
		var actual: Dictionary = current
		for key: String in expected.keys():
			if not actual.has(key):
				_fail("%s.%s: in the baseline but not in this run" % [label, key])
				continue
			_compare_tree("%s.%s" % [label, key], expected[key], actual[key])
		for key: String in actual.keys():
			if not expected.has(key):
				_fail("%s.%s: ran but is not in the baseline (re-record?)" % [label, key])
		return
	_expect(label, golden, current)


func _compare_math(golden: Dictionary, current: Dictionary) -> void:
	for key: String in ["roundi", "clampf", "lerpf", "float32"]:
		_expect("math.%s" % key, golden.get(key), current.get(key))
	# The native helpers are checked against this run's GDScript answers rather than
	# against the file, so they are still checked on a machine whose baseline predates
	# the extension.
	if current.has("native"):
		for key: String in ["roundi", "clampf", "lerpf", "float32"]:
			_expect("math.native.%s" % key, current[key], current["native"][key])
	else:
		# Almost always one of two things: the library was never built, or .godot/ was
		# wiped and nothing has rescanned since. Godot only reads extension_list.cfg in
		# a headless run — it is the editor's filesystem scan that writes it.
		_fail("math.native: the extension is not loaded. Build it, and open the editor "
				+ "once if .godot/extension_list.cfg is missing.")


func _compare_case(name: String, golden: Dictionary, current: Dictionary) -> void:
	var golden_stages: Array = golden.get("stages", [])
	var current_stages: Array = current.get("stages", [])
	if golden_stages.size() != current_stages.size():
		_fail("%s: ran %d stages, baseline has %d" % [name, current_stages.size(), golden_stages.size()])
	else:
		for i in current_stages.size():
			_compare_stage("%s[%d:%s]" % [name, i, current_stages[i].get("id", "?")],
					golden_stages[i], current_stages[i])
	_expect("%s.final" % name, golden.get("final"), current.get("final"))
	_expect("%s.pipeline" % name, golden.get("pipeline"), current.get("pipeline"))


func _compare_stage(label: String, golden: Dictionary, current: Dictionary) -> void:
	var golden_buffers: Dictionary = golden.get("buffers", {})
	var current_buffers: Dictionary = current.get("buffers", {})
	for key: String in current_buffers.keys():
		_expect("%s.%s" % [label, key], golden_buffers.get(key), current_buffers[key])
	var golden_scalars: Dictionary = golden.get("scalars", {})
	var current_scalars: Dictionary = current.get("scalars", {})
	for key: String in current_scalars.keys():
		_expect("%s.%s" % [label, key], golden_scalars.get(key), current_scalars[key])
	_expect("%s.keys" % label, golden.get("keys"), current.get("keys"))
	_expect("%s.key_tolerances" % label, golden.get("key_tolerances"), current.get("key_tolerances"))


func _expect(label: String, expected: Variant, actual: Variant) -> void:
	_checked += 1
	if _same(expected, actual):
		return
	_fail("%s\n    baseline: %s\n    current:  %s" % [label, expected, actual])


## Whether a recorded value and a fresh one are the same value.
##
## Numbers are compared as numbers because JSON has only one numeric type: an
## [code]int[/code] of 64 is written as [code]64[/code] and read back as
## [code]64.0[/code], and comparing the text forms would call every integer on the
## context a parity failure. Exact equality rather than [method @GlobalScope.is_equal_approx],
## since the whole premise here is that nothing drifts — the float values that could
## drift are recorded as strings by [method @GlobalScope.var_to_str] and land in the
## text branch below.
static func _same(expected: Variant, actual: Variant) -> bool:
	var expected_numeric := expected is int or expected is float
	var actual_numeric := actual is int or actual is float
	if expected_numeric and actual_numeric:
		return float(expected) == float(actual)
	if expected is Array and actual is Array:
		var left: Array = expected
		var right: Array = actual
		if left.size() != right.size():
			return false
		for i in left.size():
			if not _same(left[i], right[i]):
				return false
		return true
	return str(expected) == str(actual)


func _fail(message: String) -> void:
	_failures.append(message)


func _report() -> void:
	if _failures.is_empty():
		print("Parity OK — %d values match the baseline." % _checked)
		return
	printerr("Parity FAILED — %d of %d values differ:" % [_failures.size(), _checked])
	for message: String in _failures:
		printerr("  " + message)
	printerr("")
	printerr("Buffers for the synthetic cases were written to %s/current." % DUMP_DIR)
	printerr("Diff them against %s/baseline to find the first differing pixel." % DUMP_DIR)


# --- Dumps --------------------------------------------------------------

## Writes every buffer of one stage to disk.
##
## The hashes say a buffer changed; these say where. Recorded on the baseline run —
## which is the only chance, since the GDScript that produced them is deleted as it is
## ported — and again on any run afterwards, into a separate folder to diff against.
##
## Only for the synthetic cases. The real sheet's buffers are a megabyte each and a
## parity break that cannot be reproduced on a 64 pixel fixture is rare enough to be
## worth reasoning about by hand.
func _dump(case_name: String, index: int, stage_id: String, ctx: IWPipelineContext) -> void:
	var mode := "baseline" if OS.get_cmdline_user_args().has("--record") else "current"
	var dir := "%s/%s/%s/%02d_%s" % [DUMP_DIR, mode, case_name, index, stage_id]
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	for name: StringName in BUFFERS:
		var buffer: Variant = ctx.get(name)
		var bytes: PackedByteArray
		if buffer is PackedByteArray:
			bytes = buffer
		elif buffer is PackedInt32Array or buffer is PackedFloat32Array:
			bytes = buffer.to_byte_array()
		else:
			continue
		var file := FileAccess.open("%s/%s.bin" % [dir, name], FileAccess.WRITE)
		if file != null:
			file.store_buffer(bytes)
			file.close()


# --- Loading ------------------------------------------------------------

## Reads a PNG straight off disk, bypassing the import system.
##
## [method Image.load_from_file] would work, but the fixture folder carries a
## [code].gdignore[/code] so the editor does not import a test asset into the project,
## and reading the bytes is immune to that either way.
func _load_png(path: String) -> Image:
	if not FileAccess.file_exists(path):
		return null
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():
		return null
	var image := Image.new()
	if image.load_png_from_buffer(bytes) != OK:
		return null
	return image
