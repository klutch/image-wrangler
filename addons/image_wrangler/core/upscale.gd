@tool
class_name Upscale
extends IWOperation

## Runs every open image through a trained network, which enlarges it by inventing the
## pixels rather than by stretching the ones already there.
##
## The third operation here that describes the batch rather than any one image, and it sits
## beside [Rename] and [IWPacking] for that reason: its settings are held once for the
## session and no sidecar is written. What it does is not like either of them, though —
## every image comes out as its own file, at its own new size.
##
## [b]It runs on results, not on sources.[/b] Each image goes through its own stack first,
## so what gets enlarged is the picture you keyed and corrected. That order is the whole
## point: a background removed at 2000 pixels wide is removed against edges the source
## actually had, where one removed after upscaling is removed against edges the network
## guessed at. The dock is what arranges this — see the Upscale tab.
##
## [b]Two networks, on the GPU, through Vulkan.[/b] The work is
## [url=https://github.com/nihui/waifu2x-ncnn-vulkan]waifu2x-ncnn-vulkan[/url]'s and
## [url=https://github.com/xinntao/Real-ESRGAN-ncnn-vulkan]Real-ESRGAN-ncnn-vulkan[/url]'s,
## wrapped by [code]IWWaifu2x[/code] and [code]IWRealESRGAN[/code]. Which of them runs is the
## Engine setting; see [constant ENGINE_LABELS]. A machine with no Vulkan driver still runs
## either, on the CPU, and will take roughly a hundred times as long — [method gpu_available]
## is how the dock knows which of those it is about to do.
##
## [b]Alpha survives.[/b] The network works on colour and the transparency is carried
## across by a bicubic resize beside it, which is upstream's own arrangement. A keyed sprite
## therefore comes out keyed, with an edge that is smooth rather than invented.

## Which network to run.
##
## [b]They are not two settings of one thing.[/b] waifu2x only ever doubles, and picks its
## model by how hard you want the noise cleaned up. Real-ESRGAN enlarges by 2, 3 or 4 in a
## single pass and does not denoise at all. So the two offer different scales, and only one
## of them has a Denoise setting — the form is rebuilt when this moves.
const ENGINE_LABELS := ["waifu2x", "Real-ESRGAN"]
const ENGINE_WAIFU2X := 0
const ENGINE_REALESRGAN := 1

## The native class doing the work, one per engine. Named rather than referenced, because
## the whole point of the tests around them is that they may not be there — see
## [method is_available].
const NATIVE_CLASSES := [&"IWWaifu2x", &"IWRealESRGAN"]

## Where each engine's trained models live. Read at runtime by absolute path, which is why
## they sit in plain folders rather than being imported as resources.
const MODEL_ROOTS := [
    "res://addons/image_wrangler/thirdparty/waifu2x-ncnn-vulkan/models",
    "res://addons/image_wrangler/thirdparty/realesrgan-ncnn-vulkan/models",
]

## The model directory each engine starts on, when it is there. Both are upstream's own
## default, and both are the one of their set that handles drawn line art best.
const DEFAULT_MODELS := ["models-cunet", "realesr-animevideov3"]

## Where each engine's models can be fetched from, and roughly what the archive weighs.
##
## Empty for waifu2x, whose models are small enough to ship with the addon. Real-ESRGAN's are
## forty-four megabytes, so they are left out of the repository and the Upscale tab offers to
## fetch them — see [method model_download_setting].
##
## [b]The archive is on the Real-ESRGAN repository, not on the ncnn port's.[/b] The port
## publishes no models at all: it expects to find them beside its own program, and this
## release is where they are actually published.
const MODEL_SOURCES := [
    "",
    "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesrgan-ncnn-vulkan-20220424-windows.zip",
]
const MODEL_SOURCE_BYTES := [0, 45474481]

## Denoise strengths, and what each is worth telling waifu2x. Real-ESRGAN has no equivalent
## — see [constant ENGINE_LABELS].
##
## [b]Off is minus one and not zero.[/b] It selects a different trained model — one that
## enlarges and leaves the grain where it found it — where zero is the weakest of the four
## that do clean it up. A slider would put the two of them a step apart and imply they are
## the same thing turned down.
const NOISE_LABELS := ["Off", "Light", "Medium", "Strong", "Strongest"]
const NOISE_LEVELS := [-1, 0, 1, 2, 3]

## What [method noise_level] answers for Off, named so the tests against it read as what
## they mean. The native side keeps the same value under the same name.
const NOISE_OFF := -1

## How much larger a waifu2x result is. Doubling, because that network only knows how to
## double — everything past 2 is that same pass run again on what came out of the last one.
##
## Real-ESRGAN's ratios are not a list in code: each of its model folders ships the networks
## it ships, and [method scale_ratios] asks the folder.
const SCALE_RATIOS := [1, 2, 4, 8, 16, 32]

## What each model is for, keyed by folder name, for the note under the dropdown.
##
## Kept here beside the operation rather than in the dock, so a model cannot be described
## in one place and offered in another. A folder with no entry gets a line saying as much,
## which is the honest answer for one somebody dropped in themselves.
const MODEL_DESCRIPTIONS := {
    "models-cunet": "Drawn art: line work, cel shading, flat colour. Slowest of the three and the one to reach for first, since it holds a hard edge where the others soften it.",
    "models-upconv_7_anime_style_art_rgb": "Drawn art again, at roughly twice the speed and a little softer. Worth having while you are still deciding, then swap back for the run that counts.",
    "models-upconv_7_photo": "Photographs and rendered images. On line art it rounds the edges off, which is the one thing drawn work cannot spare.",
    "realesr-animevideov3": "Drawn art, and the fastest thing here by a wide margin. The only Real-ESRGAN model with a 2x and a 3x of its own, so it is the one to use when 4x is more than you want.",
    "realesrgan-x4plus-anime": "Drawn art, at 4x only. Slower than animevideov3 and firmer with it — worth the wait when the line work matters more than the turnaround.",
    "realesrgan-x4plus": "Photographs and rendered images, at 4x only. Much the slowest model here. On line art it invents texture that was never drawn.",
}

var settings: UpscaleSettings

## The upscaler, held open across a batch.
##
## [b]Opening one is expensive and identical for every image in a run.[/b] It brings up a
## Vulkan device, compiles two shader modules and reads a model off disk — a second or two,
## and none of it depends on which picture comes next. So it is opened on the first image
## and kept, which is what makes a run over twenty files cost one setup rather than twenty.
##
## Typed as [Object] rather than as the class it holds, for the same reason
## [method _make_upscaler] goes through [ClassDB]: naming the class here would make this
## script fail to compile in a build that does not have it. Dropping the reference is enough
## to release the device — the native side closes itself when its last reference goes.
##
## Null until something is processed. See [method _ensure_open] for what closes it again.
var _upscaler: Object

## What [member _upscaler] was opened for, so a settings change is noticed.
var _open_for := ""

## Why the last call failed, or empty when it did not. Read by the dock, which is the only
## thing that can put it on screen.
var last_error := ""


## Which engine [member settings] was last squared up against. See [method sync_engine].
var _model_engine := ENGINE_WAIFU2X


func _init() -> void:
    settings = UpscaleSettings.new()
    var models := model_names()
    settings.model_index = maxi(models.find(DEFAULT_MODELS[engine()]), 0)
    _model_engine = engine()


func get_operation_name() -> String:
    return "Upscale"


func get_operation_id() -> StringName:
    return &"upscale"


func get_settings() -> Resource:
    return settings


func set_settings(new_settings: Resource) -> void:
    var typed := new_settings as UpscaleSettings
    if typed == null:
        push_error("Image Wrangler: Upscale was handed settings of the wrong type.")
        return
    settings = typed


func make_settings() -> Resource:
    return UpscaleSettings.new()


## Names the ratio, so a folder of results says what was done to it.
##
## The one suffix here that follows a setting rather than naming an operation. A batch run
## at 4x and a batch run at 2x are not the same output, and "_upscaled" on both of them
## would be the one thing a suffix exists to prevent.
func get_output_suffix() -> String:
    return "_x%d" % scale_ratio()


## Held once for the session: a scale ratio describes what you want out of the batch, and
## one that changed with whichever file was highlighted would mean nothing.
func settings_are_per_image() -> bool:
    return false


## True. Every image comes out as its own file, at its own new size — which is what makes
## this the one batch operation here that Save All has something to do on.
func transforms_pixels() -> bool:
    return true


## [b]Rebuilt when the engine moves, not merely refreshed.[/b] The model dropdown is filled
## from a different folder, the scales are a different list, and Denoise is not in it at all
## — none of which a form that only re-reads its values could follow. The dock notices
## through [method sync_engine].
func get_settings_schema() -> Array[Dictionary]:
    var schema: Array[Dictionary] = [
        {
            "property": &"engine_index",
            "label": "Engine",
            "type": SettingType.ENUM,
            "options": ENGINE_LABELS,
            "tooltip": "Which of the two networks to run.\n\nwaifu2x doubles, and can clean up noise on the way through. Real-ESRGAN\nenlarges by 2, 3 or 4 in one pass, invents more detail, and has no denoising\nof its own.\n\nThey do not share a model list or a set of scales, so the settings below\nchange when this does.",
        },
        {
            "property": &"model_index",
            "label": "Model",
            "type": SettingType.ENUM,
            # A plain Array rather than the PackedStringArray the scan returns: the form
            # builder types the options it reads as Array, and the two are not the same
            # thing to GDScript.
            "options": Array(model_names()),
            "tooltip": "Which trained network to run.\n\nThey differ in what they were trained on, and using the wrong one is not a\nsubtle mistake: a photo model rounds off the hard edges drawn art is made\nof. The line under the dropdown says what each is for.",
        },
        {
            "property": &"scale_index",
            "label": "Scale",
            "type": SettingType.ENUM,
            "options": scale_labels(),
            "tooltip": _scale_tooltip(),
        },
    ]

    if engine() == ENGINE_WAIFU2X:
        schema.append({
            "property": &"noise_index",
            "label": "Denoise",
            "type": SettingType.ENUM,
            "options": NOISE_LABELS,
            "tooltip": "How hard to clean the image up on the way through.\n\nOff is a different model rather than a strength of zero: it enlarges and\nleaves whatever grain it found. Reach for the stronger settings on JPEGs,\nwhere the noise is compression rather than grain, and go easy on drawn art —\nthe same pass that clears mosquito noise also flattens deliberate texture.",
        })

    schema.append({
            "property": &"sharpen",
            "label": "Sharpen",
            "type": SettingType.FLOAT,
            "min": 0.0,
            "max": 1.0,
            "step": 0.01,
            "tooltip": "Tightens the antialiasing round the edge of the object, which is\nwherever the transparency is partial.\n\nThe network carries transparency across on a plain resize rather than\nthrough itself, so what comes out is a soft ramp. At 1 that ramp is gone\nand the edge is a hard cut. The object stays exactly the same size at\nevery setting.\n\nCosts nothing to change: it is applied to the finished picture, so moving\nthis does not run the network again.",
    })
    schema.append({
            "property": &"tta",
            "label": "TTA Mode",
            "type": SettingType.BOOL,
            "tooltip": "Runs each image eight ways — every rotation and flip — and averages\nthe results.\n\nEight times the work for a difference you have to go looking for. Worth\nit on a final pass over a handful of images; not worth it while you are\nstill choosing a model.",
    })
    return schema


## The Scale tooltip, which says a different thing on each engine because the two reach a
## ratio in different ways.
func _scale_tooltip() -> String:
    if engine() == ENGINE_REALESRGAN:
        return "How much larger the result is.\n\nOne pass, whatever the ratio — the network was trained at it. Which ratios\nare offered is up to the model: only animevideov3 ships a 2x and a 3x, and\nthe x4plus models do 4x and nothing else.\n\nA 2000 x 2000 image at 4x is 8000 x 8000."
    return "How much larger the result is.\n\nThe network doubles, so 4x and above are that same pass run again on its\nown output — twice the work per step, and four times the pixels. 1x runs\nthe denoising and leaves the size alone.\n\nA 2000 x 2000 image at 8x is 16000 x 16000, which is larger than most\ngraphics cards will hold."


# --- Which engine -------------------------------------------------------

## Which network is selected, pulled into range.
func engine() -> int:
    return clampi(settings.engine_index, 0, ENGINE_LABELS.size() - 1)


## Moves the model and scale onto the engine now selected, and says whether it had to.
##
## [b]The dock rebuilds the form when this returns true.[/b] Both indices point into lists
## that the engine decides, so leaving them where they were would mean an index into the
## wrong list — a Model dropdown showing waifu2x's folders against Real-ESRGAN's, and a
## Scale of 32x on a network that only knows 4.
##
## [b]The ratio is carried across, not the index.[/b] The two lists do not line up: waifu2x's
## second entry is 2x and Real-ESRGAN's is 3x, so keeping the index would quietly change the
## size of everything in the batch. What is kept is the number of times larger you asked
## for, or the nearest the new engine can manage — 8x on waifu2x becomes 4x, which is as
## close as Real-ESRGAN gets.
func sync_engine() -> bool:
    var now := engine()
    if now == _model_engine:
        return false

    # Worked out against the engine being left, from settings that have not moved — only
    # engine_index has changed by the time this runs.
    var leaving := models_for(_model_engine)
    var old_model := "" if leaving.is_empty() \
            else leaving[clampi(settings.model_index, 0, leaving.size() - 1)]
    var old_ratios := ratios_for(_model_engine, old_model)
    var old_ratio := 0
    if not old_ratios.is_empty():
        old_ratio = int(old_ratios[clampi(settings.scale_index, 0, old_ratios.size() - 1)])

    _model_engine = now
    var models := model_names()
    settings.model_index = maxi(models.find(DEFAULT_MODELS[now]), 0)
    settings.scale_index = _nearest_ratio_index(scale_ratios(), old_ratio)
    return true


## Where in [param ratios] the entry closest to [param wanted] sits. Zero for an empty list,
## which is the only index a dropdown with nothing in it can hold.
func _nearest_ratio_index(ratios: Array, wanted: int) -> int:
    var best := 0
    var best_distance := -1
    for index in ratios.size():
        var distance: int = absi(int(ratios[index]) - wanted)
        if best_distance < 0 or distance < best_distance:
            best = index
            best_distance = distance
    return best


# --- What is installed --------------------------------------------------

## Whether the native upscalers are in the build at all.
##
## [b]They are left out of a build that has not had ncnn made for it[/b], which is the
## ordinary state of a fresh checkout — see `tools/build_ncnn.py`. So this is asked before
## the tab offers to do anything, and [method unavailable_note] is what gets shown instead.
##
## Both or neither: they are built from the same ncnn by the same rule in SConstruct, so
## there is no state where one is there and the other is not.
static func is_available() -> bool:
    return ClassDB.class_exists(NATIVE_CLASSES[ENGINE_WAIFU2X]) \
            and ClassDB.class_exists(NATIVE_CLASSES[ENGINE_REALESRGAN])


## Whether there is a Vulkan device to run on, rather than the CPU fallback.
##
## False on a machine with no Vulkan driver. Nothing refuses to run in that case; it is
## simply worth saying, because the difference is minutes against seconds.
##
## The probe is thrown away — it holds nothing until [code]open[/code] is called, and the
## Vulkan instance it brings up behind the scenes is process-wide, shared by both engines,
## and outlives it.
static func gpu_available() -> bool:
    var probe := _make_upscaler(ENGINE_WAIFU2X)
    return probe != null and bool(probe.call(&"has_gpu"))


## An upscaler for [param for_engine], or null when the classes are not in this build.
##
## [b]Reached through [ClassDB] rather than by name.[/b] Naming [code]IWWaifu2x[/code] in
## GDScript source would make this script fail to compile in a build that left the class
## out — and the build that leaves it out is the ordinary state of a fresh checkout, so the
## one thing this must not do is take the rest of the addon down with it.
static func _make_upscaler(for_engine: int) -> Object:
    if not is_available():
        return null
    return ClassDB.instantiate(NATIVE_CLASSES[for_engine])


## One line saying why the tab cannot do anything at all, or empty when it can.
##
## Only about the build. Anything that depends on which engine is selected is
## [method combination_note]'s, since a static method has no settings to read.
static func unavailable_note() -> String:
    if not is_available():
        return "Upscaling is not in this build. Run tools/build_ncnn.py in the addon folder, then build the extension again."
    return ""


# --- The models ---------------------------------------------------------

## What the last scan found, keyed by engine, and whether there has been one. See
## [method model_names].
static var _models := {}
static var _scanned := false

## What each Real-ESRGAN model folder answered about its ratios, keyed by folder name.
## Thrown away by [method refresh_models] along with the folder list.
static var _realesrgan_scales := {}


## Where this engine's models live.
func models_root() -> String:
    return MODEL_ROOTS[engine()]


## Whether this engine's models can be fetched rather than only found. See
## [constant MODEL_SOURCES].
func has_model_source() -> bool:
    return not String(MODEL_SOURCES[engine()]).is_empty()


## What the dock's model folder control needs to fetch this engine's models.
##
## Built here rather than in the dock, for the reason [constant MODEL_DESCRIPTIONS] is: the
## folder, the archive and how the two are arranged are all one fact about the engine, and a
## dock that carried half of it could offer a download that landed in the wrong place.
func model_download_setting() -> Dictionary:
    return {
        "download_url": MODEL_SOURCES[engine()],
        "download_bytes": MODEL_SOURCE_BYTES[engine()],
        # A folder per model, which is how both engines arrange theirs and what
        # refresh_models scans for.
        "models_in_folders": true,
        # The tab has a Refresh of its own, right under the preview.
        "show_refresh": false,
    }


## Every model folder this engine has, sorted.
##
## A folder counts when it holds a [code].param[/code] file, which is the network's
## description. The test keeps a half-finished download or somebody's backup folder off a
## dropdown where every entry promises to load.
func model_names() -> PackedStringArray:
    return models_for(engine())


## The same, for an engine that is not the selected one.
##
## [b]Scanned once and remembered.[/b] The dock asks this every time it works out whether
## the tab can do anything, which is often enough that a pair of directory listings per call
## is not free — and a folder of trained models does not change while anyone is looking at
## it. [method refresh_models] is what admits that it might have.
static func models_for(for_engine: int) -> PackedStringArray:
    if not _scanned:
        refresh_models()
    return _models.get(for_engine, PackedStringArray())


## Looks at the disk again. Called when the dock builds its form, so a model folder dropped
## in while the editor was open appears after a rebuild rather than after a restart.
static func refresh_models() -> void:
    _scanned = true
    _models = {}
    _realesrgan_scales = {}

    for for_engine in ENGINE_LABELS.size():
        var out := PackedStringArray()
        var root_path: String = MODEL_ROOTS[for_engine]
        var root := DirAccess.open(root_path)
        if root != null:
            for name in root.get_directories():
                var models := DirAccess.open(root_path.path_join(name))
                if models == null:
                    continue
                for file in models.get_files():
                    if file.get_extension().to_lower() == "param":
                        out.append(name)
                        break
            out.sort()
        _models[for_engine] = out


## The chosen model's folder name, or empty when there are none to choose from.
##
## Clamped rather than trusted: the index is into a list read off disk, and a folder added
## or removed since the last scan moves every entry after it.
func model_name() -> String:
    var models := model_names()
    if models.is_empty():
        return ""
    return models[clampi(settings.model_index, 0, models.size() - 1)]


## One line about an engine with nothing to run, which points at the download when there is
## one to point at.
func no_models_note() -> String:
    if has_model_source():
        return "No models found in %s. Press Download Latest Model." % models_root()
    return "No models found in %s." % models_root()


## What the chosen model is for, in a couple of sentences.
func model_description() -> String:
    var name := model_name()
    if name.is_empty():
        return "No models to choose from."
    return String(MODEL_DESCRIPTIONS.get(name,
            "Not one of the models that ship with this addon, so there is nothing here to say about it."))


# --- The scales ---------------------------------------------------------

## Every ratio the selected engine and model can do, ascending.
##
## [b]waifu2x's are a list in code and Real-ESRGAN's are not.[/b] waifu2x reaches any of its
## ratios by running one doubling network over and over, so what it offers does not depend
## on which model is loaded. Real-ESRGAN's ratio is baked into the network, so the answer is
## whichever files the folder actually holds — and the native side is what reads them, since
## it is what would have to load them.
func scale_ratios() -> Array:
    return ratios_for(engine(), model_name())


## The same, for an engine and model that are not the selected ones. See
## [method sync_engine], which is the only thing that needs to ask about the other one.
static func ratios_for(for_engine: int, model: String) -> Array:
    if for_engine != ENGINE_REALESRGAN:
        return SCALE_RATIOS
    return realesrgan_scales(model)


## The ratios [param model] ships, remembered per folder.
static func realesrgan_scales(model: String) -> Array:
    if model.is_empty():
        return []
    if _realesrgan_scales.has(model):
        return _realesrgan_scales[model]

    var out: Array = []
    var probe := _make_upscaler(ENGINE_REALESRGAN)
    if probe != null:
        var directory := ProjectSettings.globalize_path(
                String(MODEL_ROOTS[ENGINE_REALESRGAN]).path_join(model))
        for ratio in probe.call(&"supported_scales", directory):
            out.append(int(ratio))
    _realesrgan_scales[model] = out
    return out


## The Scale dropdown's entries, which are the ratios named.
func scale_labels() -> Array:
    var out: Array = []
    for ratio in scale_ratios():
        out.append("%dx" % ratio)
    return out


## How much larger the result will be, as a plain number.
##
## One when there is nothing to choose from, which is the identity and the only honest
## answer for a model folder that turned out to hold no network at all.
func scale_ratio() -> int:
    var ratios := scale_ratios()
    if ratios.is_empty():
        return 1
    return int(ratios[clampi(settings.scale_index, 0, ratios.size() - 1)])


## What to tell waifu2x about denoising. See [constant NOISE_LEVELS].
##
## Off on Real-ESRGAN, which has no denoising and no setting for it. The value still goes
## into [method network_signature] so a run made under one engine is never mistaken for a
## run made under the other.
func noise_level() -> int:
    if engine() != ENGINE_WAIFU2X:
        return NOISE_OFF
    return int(NOISE_LEVELS[clampi(settings.noise_index, 0, NOISE_LEVELS.size() - 1)])


## One line saying why the settings as they stand cannot run, or empty when they can.
##
## Two things can be wrong, and which of them applies depends on the engine.
##
## [b]An engine with no models at all.[/b] Both fold their models into their own vendored
## folder, and either can be missing from a checkout.
##
## [b]waifu2x at a ratio of 1, both ways it can go wrong.[/b] A ratio of 1 does not use the
## doubling network at all — it runs a denoise-only model instead, and that is a separate
## set of files. Only [code]models-cunet[/code] ships them; the two upconv folders are
## doubling networks and nothing else. Denoise off on top of that asks for a model that
## neither enlarges nor cleans, which is a request for the image back.
##
## Caught here rather than left to the loader, which reports the same thing as a missing
## [code].param[/code] file — true, and no use to anybody who did not already know what
## these folders contain.
func combination_note() -> String:
    var model := model_name()
    if model.is_empty():
        return no_models_note()
    if engine() == ENGINE_REALESRGAN:
        if scale_ratios().is_empty():
            return "%s holds no network this can load. A Real-ESRGAN folder names its files after itself, with the ratio on the end for a model that ships more than one." % model
        return ""

    if scale_ratio() != 1:
        return ""
    if noise_level() == NOISE_OFF:
        return "1x with Denoise off does nothing: nothing is enlarged and nothing is cleaned up."
    if not _has_denoise_only_model(model):
        return "%s has no 1x network — it only enlarges. Choose 2x or more, or switch to models-cunet, which is the one that can denoise without resizing." % model
    return ""


## Whether [param model] ships the models a ratio of 1 needs.
func _has_denoise_only_model(model: String) -> bool:
    return FileAccess.file_exists(
            models_root().path_join(model).path_join("noise%d_model.param" % noise_level()))


## The size [param source] would come out at.
##
## Worked out rather than measured, so the dock can warn about a result too large to hold
## before spending minutes arriving at it.
func output_size(source: Vector2i) -> Vector2i:
    return source * scale_ratio()


# --- Running ------------------------------------------------------------

## Everything that decides what network gets built, as one comparable string.
##
## [b]Sharpen is deliberately not in it.[/b] That is the whole point of the distinction: the
## five settings here are baked into a loaded model and a compiled pipeline, and changing any
## of them means opening a new upscaler. Sharpen is applied to the picture afterwards, so
## the dock can keep the network's answer and re-sharpen it — which is what lets a slider
## with a neural network behind it still follow the mouse.
func network_signature() -> String:
    return "%d|%s|%d|%d|%s" % [
            engine(), model_name(), noise_level(), scale_ratio(), settings.tta]


## Applies the Sharpen setting to [param image] and gives back the result.
##
## Separate from [method process_image] so the dock can re-run this on its own, against the
## picture the network already produced. Returns [param image] itself at a setting of zero,
## which is the identity and not worth a copy of a sixteen-megapixel sheet to express.
func sharpen_image(image: Image) -> Image:
    if image == null or settings.sharpen <= 0.0:
        return image
    return IWStageKernels.sharpen_alpha(image, settings.sharpen)

## Opens the upscaler, or reuses the one already open.
##
## [b]Reopened only when something it was opened for has changed.[/b] The engine, the model,
## the denoise level, the ratio and TTA all go into the network that gets built, and none of
## them can be changed on an open one — but nothing else can force a reopen either, which
## is what makes a batch cost one setup.
func _ensure_open() -> bool:
    if not is_available():
        last_error = unavailable_note()
        return false

    var model := model_name()
    if model.is_empty():
        last_error = no_models_note()
        return false

    var wanted := network_signature()
    if _upscaler != null and _open_for == wanted:
        return true

    close()
    var upscaler := _make_upscaler(engine())
    if upscaler == null:
        last_error = unavailable_note()
        return false

    # An absolute path, because ncnn reads the model with the C library rather than through
    # Godot — res:// means nothing to it.
    var directory := ProjectSettings.globalize_path(models_root().path_join(model))
    # Real-ESRGAN has no denoise level to be told about, so its `open` is one argument
    # shorter. The only place the two native classes are not interchangeable.
    var opened: int
    if engine() == ENGINE_REALESRGAN:
        opened = upscaler.call(&"open", directory, scale_ratio(), settings.tta)
    else:
        opened = upscaler.call(&"open", directory, noise_level(), scale_ratio(), settings.tta)
    if opened != OK:
        last_error = String(upscaler.call(&"get_last_error"))
        return false

    _upscaler = upscaler
    _open_for = wanted
    return true


## Drops the device, the model and the shaders. Safe to call when nothing is open.
##
## Worth calling when a run is finished rather than leaving to the garbage collector: what
## is held is a Vulkan device and a few hundred megabytes of video memory, and the editor
## goes on running afterwards.
func close() -> void:
    if _upscaler != null:
        _upscaler.call(&"close")
        _upscaler = null
    _open_for = ""


## The network's answer for [param source], before Sharpen is applied to it.
##
## Split out from [method process_image] so the dock can hold on to it: this is the
## expensive half and the only half that Sharpen does not affect. See
## [method network_signature].
##
## Returns [param source] itself when it could not run, with [member last_error] saying why.
## Handing back the image untouched is what lets a batch carry on past one failure, and the
## dock is what counts them and says so at the end.
##
## [b]Not interruptible.[/b] waifu2x tiles the image internally and reports nothing on the
## way through, so there is no checkpoint to stop at — a run is one call, and the smallest
## unit the dock can cancel between is a whole image.
func upscale_only(source: Image) -> Image:
    last_error = ""
    if source == null or source.is_empty():
        return source
    if not _ensure_open():
        return source

    var result: Image = _upscaler.call(&"process", source)
    if result == null:
        last_error = String(_upscaler.call(&"get_last_error"))
        return source
    return result


## Enlarges [param source], sharpens the edge, and gives back the result.
##
## The two steps in the order they have to go in — Sharpen works on the ramp the resize
## left, so there has to be one first. A run that failed is handed straight back rather than
## sharpened, since what it is holding is the source image and not an answer.
func process_image(source: Image) -> Image:
    var result := upscale_only(source)
    if not last_error.is_empty():
        return result
    return sharpen_image(result)
