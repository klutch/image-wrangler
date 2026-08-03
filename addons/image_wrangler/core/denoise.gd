@tool
class_name Denoise
extends IWStackOperation

## Takes the sensor and compression noise off the source pixels, before anything reads
## them.
##
## Intel Open Image Denoise's RT filter, which is a trained model rather than a blur: it
## lifts grain and JPEG mosquito noise while leaving an edge where it found it. That
## property is the whole reason for reaching outside for this — a bilateral or a median
## smooths the same grain and takes the silhouette with it, which on a keying tool is
## the one thing that cannot be given away.
##
## [b]It is the only stage that rewrites [member IWPipelineContext.data].[/b] Every other
## stage writes coverage, a mask or a side buffer and leaves the source colours for
## [IWCompose] to read at the end. This one replaces them, and everything below it —
## every flood, every tolerance, and the un-blend at the end — then measures the pixels
## it left rather than the ones the file arrived with.
##
## [b]Where it sits decides what it affects, and both positions are useful.[/b]
##
## Above the keying, it changes the cut. A flat ground with grain on it needs a tolerance
## wide enough to swallow the grain, and that width is what eats into the subject;
## denoised first, the same ground keys at a fraction of it. The corollary is that
## tolerances dialled in with this stage on are not the same numbers with it off.
##
## Below the keying, the matte is already decided and stays exactly as it was — nothing
## re-floods and nothing re-measures. What changes is the colour that comes out: the
## pixels [IWCompose] writes, the ones it bleeds outwards into the transparent margin,
## and the ones it un-blends. Useful precisely because it leaves a cut you have already
## dialled in alone.
##
## [b]What it invalidates.[/b] Only [member IWPipelineContext.key_dist], which is a
## per-pixel distance measured off the source colours and would otherwise describe pixels
## that no longer exist — [method IWPipelineContext.ensure_key_dist] is a no-op once the
## map exists, so a stale one would never be noticed. It is rebuilt here rather than
## merely cleared, because [RefineEdges] guides off it and silently skips its filter when
## it is empty. Everything else survives: [member IWPipelineContext.mask] and [member
## IWPipelineContext.nearest] say which pixels are subject rather than what colour they
## are, and denoising moves no pixel between those categories.

## The colour this operation's marks are drawn in on the preview.
##
## Written out rather than worked out, and its own rather than the stack's, so it is the
## same colour every session. A unit-length colour, so no operation's marks arrive
## brighter than another's.
const TINT := Color(1.000, 0.000, 0.000)

## Where the Open Image Denoise runtime goes: beside the extension, which is the only place
## both Godot's loader and OIDN's own module lookup will find it.
const RUNTIME_DIR := "res://addons/image_wrangler/bin"

## Intel's prebuilt drop, and roughly what it weighs.
##
## The whole zip comes down and only [constant RUNTIME_FILES] is written out of it — the
## CUDA, HIP and SYCL device modules and the three tools are another 24 MB that nothing here
## can reach, since the kernel asks for the CPU device by name.
const RUNTIME_URL := "https://github.com/RenderKit/oidn/releases/download/v2.5.0/oidn-2.5.0.x64.windows.zip"
const RUNTIME_BYTES := 56062809

## The seven libraries the stage actually needs, and the whole test for whether it can run.
## Why each one is in thirdparty/oidn/README-vendored.md.
const RUNTIME_FILES := [
    "OpenImageDenoise.dll",
    "OpenImageDenoise_core.dll",
    "OpenImageDenoise_device_cpu.dll",
    "tbb12.dll",
    "tbbbind.dll",
    "tbbbind_2_0.dll",
    "tbbbind_2_5.dll",
]


var settings: DenoiseSettings


func _init() -> void:
    settings = DenoiseSettings.new()


func get_operation_name() -> String:
    return "Denoise"


func get_operation_id() -> StringName:
    return &"denoise"


func get_tint() -> Color:
    return TINT


func get_settings() -> Resource:
    return settings


func set_settings(new_settings: Resource) -> void:
    var typed := new_settings as DenoiseSettings
    if typed == null:
        push_error("Image Wrangler: Denoise was handed settings of the wrong type.")
        return
    settings = typed


func make_settings() -> Resource:
    return DenoiseSettings.new()


## Nothing, deliberately.
##
## [method IWPipeline.get_output_suffix] takes the first enabled stage that names one,
## and this stage is designed to sit at the top of the stack — naming a suffix here would
## rename the output of every stack that has a Denoise in it. What comes out is still
## whatever the rest of the stack made of it, and should still be called that.
func get_output_suffix() -> String:
    return ""


func get_settings_schema() -> Array[Dictionary]:
    return [
        {
            "property": &"blend",
            "label": "Amount",
            "type": SettingType.FLOAT,
            "min": 0.0,
            "max": 1.0,
            "step": 0.01,
            "tooltip": "How much of the filtered result replaces the original.\n\nAt 1 the pixels below are entirely the filter's. Bring it down when the\nfilter is taking the tooth off drawn line art along with the grain — it is\ntrained on rendered images, and a drawn edge is not one.\n\nAt 0 the stage does nothing, which is also what switching the entry off\ndoes.",
        },
        {
            "property": &"quality",
            "label": "Quality",
            "type": SettingType.ENUM,
            "options": ["Fast", "Balanced", "High"],
            "tooltip": "What the filter trades against how long it takes.\n\nHigh by default, because this stage is one you went and added rather than\none that was already there. Drop to Fast while dialling the rest of the\nstack in on a large sheet, then put it back before processing the batch —\nthe result is not the same image.",
        },
        {
            # No property: the folder is fixed in code, because the runtime has to sit
            # beside the extension and nowhere else would work. See IWModelFolder.
            "folder": RUNTIME_DIR,
            "type": SettingType.MODEL_FOLDER,
            "files": RUNTIME_FILES,
            "download_url": RUNTIME_URL,
            "download_bytes": RUNTIME_BYTES,
            "noun": "runtime",
            "download_label": "Download Runtime",
            # Nothing to do with ncnn, unlike every other folder this control serves.
            "needs_network": false,
            # No Refresh button on this card: the preview follows on its own.
            "show_refresh": false,
            "tooltip": "Fetches Intel Open Image Denoise, which is what this stage runs.\n\nIt is 50 MB and is not committed to the repository, so a fresh checkout has\nevery other stage and not this one. Everything else keeps working without it.",
        },
    ]


## Not cheap, and not the most expensive thing in a stack: one pass over the image
## against a trained model, where the classification below it is a flood plus a
## nearest-subject map.
func stage_weight() -> float:
    return 0.8


## Nothing above it, and nothing below it either — it works on the source colours, which
## exist from the moment the run starts.
func needs_keying() -> bool:
    return false


func establishes_keying() -> bool:
    return false


## Whether the runtime this stage needs is installed.
##
## Asked of the kernel rather than of the disk, because the kernel is what has to load it —
## a folder holding the right file names is not the same as a library that came up.
static func runtime_installed() -> bool:
    return ClassDB.class_exists(&"IWStageKernels") and IWStageKernels.denoise_available()


func prerequisite_note(_ctx: IWPipelineContext) -> String:
    if not runtime_installed():
        return "Open Image Denoise is not installed. Press Download Runtime."
    return ""


func process_context(ctx: IWPipelineContext) -> void:
    # Stands down rather than pushing an error, the same way a stage waiting on keying
    # does — the card already says what is missing and what to press.
    if not runtime_installed():
        return
    # A coherent request for nothing, and worth catching here — the kernel would
    # otherwise spend a device creation and a whole filter pass arriving at the identity.
    if settings.blend <= 0.0:
        return
    if not report_progress(0.05):
        return

    # One call, and it cannot be interrupted — see the note in the kernel. The same
    # bargain every other single-pass stage makes.
    if not IWStageKernels.denoise(ctx, settings.quality, settings.blend):
        return

    # The one thing that has to be redone. key_dist is a per-pixel distance from the
    # first key, measured off the colours just replaced, and ensure_key_dist is a no-op
    # once the map exists — so left alone it would go on describing pixels that are no
    # longer there, and nothing downstream could tell.
    #
    # Rebuilt rather than merely cleared, because an empty one is not neutral: RefineEdges
    # tests for it and skips the guided filter entirely when it is missing. Both calls are
    # no-ops before anything has keyed, which is the case where there is nothing to redo.
    ctx.key_dist = PackedFloat32Array()
    ctx.ensure_key_dist()

    report_progress(1.0)
