@tool
class_name Upscale
extends IWOperation

## Runs every open image through waifu2x, which enlarges it by inventing the pixels rather
## than by stretching the ones already there.
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
## [b]A trained network, on the GPU, through Vulkan.[/b] The work is
## [url=https://github.com/nihui/waifu2x-ncnn-vulkan]waifu2x-ncnn-vulkan[/url]'s, wrapped by
## [code]IWWaifu2x[/code]. A machine with no Vulkan driver still runs it, on the CPU, and
## will take roughly a hundred times as long — [method gpu_available] is how the dock knows
## which of those it is about to do.
##
## [b]Alpha survives.[/b] The network works on colour and the transparency is carried
## across by a bicubic resize beside it, which is upstream's own arrangement. A keyed sprite
## therefore comes out keyed, with an edge that is smooth rather than invented.

## The native class doing the work. Named rather than referenced, because the whole point
## of the tests around it is that it may not be there — see [method is_available].
const NATIVE_CLASS := &"IWWaifu2x"

## Where the trained models live. Read at runtime by absolute path, which is why they sit in
## a plain folder rather than being imported as resources.
const MODELS_ROOT := "res://addons/image_wrangler/thirdparty/waifu2x-ncnn-vulkan/models"

## The model directory to start on, when it is there. Upstream's own default, and the one of
## the three that handles drawn line art best.
const DEFAULT_MODEL := "models-cunet"

## Denoise strengths, and what each is worth telling waifu2x.
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

## How much larger the result is. Doubling, because the network only knows how to double —
## everything past 2 is that same pass run again on what came out of the last one.
const SCALE_LABELS := ["1x", "2x", "4x", "8x", "16x", "32x"]
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


func _init() -> void:
    settings = UpscaleSettings.new()
    var models := model_names()
    settings.model_index = maxi(models.find(DEFAULT_MODEL), 0)


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


func get_settings_schema() -> Array[Dictionary]:
    return [
        {
            "property": &"model_index",
            "label": "Model",
            "type": SettingType.ENUM,
            # A plain Array rather than the PackedStringArray the scan returns: the form
            # builder types the options it reads as Array, and the two are not the same
            # thing to GDScript.
            "options": Array(model_names()),
            "tooltip": "Which trained network to run.\n\nThe three differ in what they were trained on, and using the wrong one is\nnot a subtle mistake: the photo model rounds off the hard edges drawn art\nis made of. The line under the dropdown says what each is for.",
        },
        {
            "property": &"scale_index",
            "label": "Scale",
            "type": SettingType.ENUM,
            "options": SCALE_LABELS,
            "tooltip": "How much larger the result is.\n\nThe network doubles, so 4x and above are that same pass run again on its\nown output — twice the work per step, and four times the pixels. 1x runs\nthe denoising and leaves the size alone.\n\nA 2000 x 2000 image at 8x is 16000 x 16000, which is larger than most\ngraphics cards will hold.",
        },
        {
            "property": &"noise_index",
            "label": "Denoise",
            "type": SettingType.ENUM,
            "options": NOISE_LABELS,
            "tooltip": "How hard to clean the image up on the way through.\n\nOff is a different model rather than a strength of zero: it enlarges and\nleaves whatever grain it found. Reach for the stronger settings on JPEGs,\nwhere the noise is compression rather than grain, and go easy on drawn art —\nthe same pass that clears mosquito noise also flattens deliberate texture.",
        },
        {
            "property": &"tta",
            "label": "TTA Mode",
            "type": SettingType.BOOL,
            "tooltip": "Runs each image eight ways — every rotation and flip — and averages\nthe results.\n\nEight times the work for a difference you have to go looking for. Worth\nit on a final pass over a handful of images; not worth it while you are\nstill choosing a model.",
        },
    ]


# --- What is installed --------------------------------------------------

## Whether the native upscaler is in the build at all.
##
## [b]It is left out of a build that has not had ncnn made for it[/b], which is the ordinary
## state of a fresh checkout — see `tools/build_ncnn.py`. So this is asked before the tab
## offers to do anything, and [method unavailable_note] is what gets shown instead.
static func is_available() -> bool:
    return ClassDB.class_exists(NATIVE_CLASS)


## Whether there is a Vulkan device to run on, rather than the CPU fallback.
##
## False on a machine with no Vulkan driver. Nothing refuses to run in that case; it is
## simply worth saying, because the difference is minutes against seconds.
##
## The probe is thrown away — it holds nothing until [code]open[/code] is called, and the
## Vulkan instance it brings up behind the scenes is process-wide and outlives it.
static func gpu_available() -> bool:
    var probe := _make_upscaler()
    return probe != null and bool(probe.call(&"has_gpu"))


## An upscaler, or null when the class is not in this build.
##
## [b]Reached through [ClassDB] rather than by name.[/b] Naming [code]IWWaifu2x[/code] in
## GDScript source would make this script fail to compile in a build that left the class
## out — and the build that leaves it out is the ordinary state of a fresh checkout, so the
## one thing this must not do is take the rest of the addon down with it.
static func _make_upscaler() -> Object:
    if not is_available():
        return null
    return ClassDB.instantiate(NATIVE_CLASS)


## One line saying why the tab cannot do anything, or empty when it can.
static func unavailable_note() -> String:
    if not is_available():
        return "Upscaling is not in this build. Run tools/build_ncnn.py in the addon folder, then build the extension again."
    if model_names().is_empty():
        return "No models found in %s." % MODELS_ROOT
    return ""


# --- The models ---------------------------------------------------------

## What the last scan found, and whether there has been one. See [method model_names].
static var _models := PackedStringArray()
static var _scanned := false


## Every model folder available, sorted.
##
## A folder counts when it holds a [code].param[/code] file, which is the network's
## description. The test keeps a half-finished download or somebody's backup folder off a
## dropdown where every entry promises to load.
##
## [b]Scanned once and remembered.[/b] The dock asks this every time it works out whether
## the tab can do anything, which is often enough that a pair of directory listings per call
## is not free — and a folder of trained models does not change while anyone is looking at
## it. [method refresh_models] is what admits that it might have.
static func model_names() -> PackedStringArray:
    if not _scanned:
        refresh_models()
    return _models


## Looks at the disk again. Called when the dock builds its form, so a model folder dropped
## in while the editor was open appears after a rebuild rather than after a restart.
static func refresh_models() -> void:
    _scanned = true
    var out := PackedStringArray()
    var root := DirAccess.open(MODELS_ROOT)
    if root == null:
        _models = out
        return

    for name in root.get_directories():
        var models := DirAccess.open(MODELS_ROOT.path_join(name))
        if models == null:
            continue
        for file in models.get_files():
            if file.get_extension().to_lower() == "param":
                out.append(name)
                break

    out.sort()
    _models = out


## The chosen model's folder name, or empty when there are none to choose from.
##
## Clamped rather than trusted: the index is into a list read off disk, and a folder added
## or removed since the last scan moves every entry after it.
func model_name() -> String:
    var models := model_names()
    if models.is_empty():
        return ""
    return models[clampi(settings.model_index, 0, models.size() - 1)]


## What the chosen model is for, in a couple of sentences.
func model_description() -> String:
    var name := model_name()
    if name.is_empty():
        return "No models to choose from."
    return String(MODEL_DESCRIPTIONS.get(name,
            "Not one of the three that ship with waifu2x, so there is nothing here to say about it."))


## How much larger the result will be, as a plain number.
func scale_ratio() -> int:
    return int(SCALE_RATIOS[clampi(settings.scale_index, 0, SCALE_RATIOS.size() - 1)])


## What to tell waifu2x about denoising. See [constant NOISE_LEVELS].
func noise_level() -> int:
    return int(NOISE_LEVELS[clampi(settings.noise_index, 0, NOISE_LEVELS.size() - 1)])


## One line saying why the settings as they stand cannot run, or empty when they can.
##
## [b]Only the 1x ratio can be impossible, and both ways it can be are about the same
## thing.[/b] A ratio of 1 does not use the doubling network at all — it runs a
## denoise-only model instead, and that is a separate set of files. Only
## [code]models-cunet[/code] ships them; the two upconv folders are doubling networks and
## nothing else. Denoise off on top of that asks for a model that neither enlarges nor
## cleans, which is a request for the image back.
##
## Caught here rather than left to the loader, which reports the same thing as a missing
## [code].param[/code] file — true, and no use to anybody who did not already know what
## these folders contain.
func combination_note() -> String:
    if scale_ratio() != 1:
        return ""
    var model := model_name()
    if model.is_empty():
        return ""
    if noise_level() == NOISE_OFF:
        return "1x with Denoise off does nothing: nothing is enlarged and nothing is cleaned up."
    if not _has_denoise_only_model(model):
        return "%s has no 1x network — it only enlarges. Choose 2x or more, or switch to models-cunet, which is the one that can denoise without resizing." % model
    return ""


## Whether [param model] ships the models a ratio of 1 needs.
func _has_denoise_only_model(model: String) -> bool:
    return FileAccess.file_exists(
            MODELS_ROOT.path_join(model).path_join("noise%d_model.param" % noise_level()))


## The size [param source] would come out at.
##
## Worked out rather than measured, so the dock can warn about a result too large to hold
## before spending minutes arriving at it.
func output_size(source: Vector2i) -> Vector2i:
    return source * scale_ratio()


# --- Running ------------------------------------------------------------

## Opens the upscaler, or reuses the one already open.
##
## [b]Reopened only when something it was opened for has changed.[/b] The model, the
## denoise level, the ratio and TTA all go into the network that gets built, and none of
## them can be changed on an open one — but nothing else can force a reopen either, which
## is what makes a batch cost one setup.
func _ensure_open() -> bool:
    if not is_available():
        last_error = unavailable_note()
        return false

    var model := model_name()
    if model.is_empty():
        last_error = "No models found in %s." % MODELS_ROOT
        return false

    var wanted := "%s|%d|%d|%s" % [model, noise_level(), scale_ratio(), settings.tta]
    if _upscaler != null and _open_for == wanted:
        return true

    close()
    var upscaler := _make_upscaler()
    if upscaler == null:
        last_error = unavailable_note()
        return false

    # An absolute path, because ncnn reads the model with the C library rather than through
    # Godot — res:// means nothing to it.
    var directory := ProjectSettings.globalize_path(MODELS_ROOT.path_join(model))
    if upscaler.call(&"open", directory, noise_level(), scale_ratio(), settings.tta) != OK:
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


## Enlarges [param source] and gives back the result.
##
## Returns [param source] itself when it could not run, with [member last_error] saying why.
## Handing back the image untouched is what lets a batch carry on past one failure, and the
## dock is what counts them and says so at the end.
##
## [b]Not interruptible.[/b] waifu2x tiles the image internally and reports nothing on the
## way through, so there is no checkpoint to stop at — a run is one call, and the smallest
## unit the dock can cancel between is a whole image.
func process_image(source: Image) -> Image:
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
