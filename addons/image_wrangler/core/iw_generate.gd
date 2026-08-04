@tool
class_name IWGenerate
extends IWOperation

## Makes a new picture from a written description, using a ComfyUI server.
##
## The odd one out among the operations: nothing here processes pixels. The settings
## describe a job, [IWComfyGraph] turns them into a graph, and [IWComfyServer] runs it. See
## [method transforms_pixels].
##
## [member IWGenerateSettings.use_source] only records that a run should start from the
## highlighted image. Fetching and scaling it is the dock's job.
##
## The dropdowns are filled from whatever the server says it has. Until it has been asked
## they are empty, and the tab says why rather than offering a guess.

const MIN_SIZE := 64
const MAX_SIZE := 4096

const MIN_STEPS := 1
const MAX_STEPS := 150

## The largest useful guidance. ComfyUI allows a hundred; past about twenty the picture is
## burnt, and a slider that spends most of its travel in the ruined part is no use.
const MAX_CFG := 30.0

@export var settings: IWGenerateSettings

## What the server said it has, filled by the dock from [signal IWComfyServer.info_ready].
##
## Held on the operation rather than on the settings, because it describes the server
## rather than the job — it must not be saved and must not travel.
var checkpoints: Array = []
var loras: Array = []
var samplers: Array = []
var schedulers: Array = []


func _init() -> void:
    settings = IWGenerateSettings.new()


func get_operation_name() -> String:
    return "Generate"


func get_operation_id() -> StringName:
    return &"generate"


func get_settings() -> Resource:
    return settings


func set_settings(new_settings: Resource) -> void:
    var typed := new_settings as IWGenerateSettings
    if typed == null:
        push_error("Image Wrangler: IWGenerate was handed settings of the wrong type.")
        return
    settings = typed


func make_settings() -> Resource:
    return IWGenerateSettings.new()


func get_output_suffix() -> String:
    return "_generated"


## Held once for the editor, like the Export tab's: the description is not about whichever
## file happens to be highlighted, and one that changed with the selection would mean
## nothing.
func settings_are_per_image() -> bool:
    return false


## False. This makes a picture rather than changing one, so it never goes through the
## per-file write path — the dock saves what is on screen, as it does for a packed sheet.
func transforms_pixels() -> bool:
    return false


## Takes the lists the server offered.
##
## A LoRA of none is put on the front rather than left to the settings, since it is the
## one choice on that row that is not a file on the server.
func set_catalogue(lists: Dictionary) -> void:
    checkpoints = lists.get("checkpoints", [])
    loras = [IWComfyGraph.LORA_NONE]
    loras.append_array(lists.get("loras", []))
    samplers = lists.get("samplers", [])
    schedulers = lists.get("schedulers", [])


## Whether the server has told us what it has yet.
func has_catalogue() -> bool:
    return not checkpoints.is_empty()


func get_settings_schema() -> Array[Dictionary]:
    return [
        {
            "property": &"checkpoint",
            "label": "Checkpoint",
            "type": SettingType.CHOICE,
            "options": checkpoints,
            "group": "Model",
            "tooltip": "Which model makes the picture.\n\nThe list is whatever the server has. It is empty until the dock has spoken to\none, and what a model was trained on decides far more about the result than any\nother setting here.",
        },
        {
            "property": &"lora",
            "label": "LoRA",
            "type": SettingType.CHOICE,
            "options": loras,
            "group": "Model",
            "tooltip": "A small extra model that leans the checkpoint towards a subject or a style.\n\nOne at a time. Pick %s to use the checkpoint on its own." % IWComfyGraph.LORA_NONE,
        },
        {
            "property": &"lora_strength",
            "label": "LoRA Strength",
            "type": SettingType.FLOAT,
            "min": -2.0,
            "max": 2.0,
            "step": 0.05,
            "group": "Model",
            "tooltip": "How hard that LoRA leans. One is how it was trained to be used.\n\nBelow one softens it. Above one usually takes the picture apart. Negative\npushes the other way, which sometimes works and usually does not.",
        },
        {
            "property": &"positive",
            "label": "Description",
            "type": SettingType.TEXT,
            "lines": 5,
            "group": "Prompt",
            "tooltip": "What to make.\n\nWhat a model answers to depends on what it was trained on: some want a\nsentence, some want a list of words. Try both.",
        },
        {
            "property": &"negative",
            "label": "Keep Out",
            "type": SettingType.TEXT,
            "lines": 3,
            "group": "Prompt",
            "tooltip": "What to keep out of the picture.\n\nLeaving it empty is fine. It is a nudge rather than a rule, and a long list of\nthings you did not want is rarely what fixes a bad picture.",
        },
        {
            "property": &"sampler",
            "label": "Sampler",
            "type": SettingType.CHOICE,
            "options": samplers,
            "group": "Sampling",
            "tooltip": "Which method walks the noise back to a picture.\n\neuler is the plain one and a fine default. The ancestral ones add noise as they\ngo, so they keep changing right to the last step and never quite settle.",
        },
        {
            "property": &"scheduler",
            "label": "Scheduler",
            "type": SettingType.CHOICE,
            "options": schedulers,
            "group": "Sampling",
            "tooltip": "How the steps are spaced along that walk.\n\nnormal and karras are the usual two. It matters most at low step counts, where\nwhere the steps go decides what there is time to settle.",
        },
        {
            "property": &"steps",
            "label": "Steps",
            "type": SettingType.INT,
            "min": MIN_STEPS,
            "max": MAX_STEPS,
            "step": 1,
            "group": "Sampling",
            "tooltip": "How many steps that walk takes.\n\nTwenty to thirty suits most models. More is slower and, past a point, no\nbetter. Models built for few steps say so, and want far less.",
        },
        {
            "property": &"cfg",
            "label": "Guidance",
            "type": SettingType.FLOAT,
            "min": 0.0,
            "max": MAX_CFG,
            "step": 0.1,
            "group": "Sampling",
            "tooltip": "How hard the description is pushed.\n\nSeven or so is the usual place. Too low and it wanders off; too high and the\ncolours burn out and the shapes go hard.",
        },
        {
            "property": &"randomize_seed",
            "label": "New Seed Each Time",
            "type": SettingType.BOOL,
            "group": "Sampling",
            "tooltip": "Draws a fresh seed for every run.\n\nThe one that was used is written back into the box below, so a picture you\nliked can always be made again.",
        },
        {
            "property": &"seed",
            "label": "Seed",
            "type": SettingType.INT,
            "min": 0,
            "max": IWComfyGraph.MAX_SEED,
            "step": 1,
            "group": "Sampling",
            "tooltip": "The number the noise is made from.\n\nThe same seed with the same settings gives the same picture back. Change one\nword of the description and it will not.",
        },
        {
            "property": &"use_source",
            "label": "Start From Selected Image",
            "type": SettingType.BOOL,
            "group": "Picture",
            "tooltip": "Starts the run from the highlighted image instead of from nothing.\n\nIt is sent with its stack already applied, so what goes over is what the other\ntabs show. The result comes back at the size it went in at, whatever the two\nboxes below say.",
        },
        {
            "property": &"denoise",
            "label": "Change",
            "type": SettingType.FLOAT,
            "min": 0.0,
            "max": 1.0,
            "step": 0.01,
            "group": "Picture",
            "shown_when": &"use_source",
            "shown_values": [true],
            "tooltip": "How much of the original is thrown away.\n\nAround 0.4 keeps the layout and repaints the surface. Past about 0.8 there is\nlittle of the original left, and at 1 there is none.",
        },
        {
            "property": &"width",
            "label": "Width",
            "type": SettingType.INT,
            "min": MIN_SIZE,
            "max": MAX_SIZE,
            "step": IWComfyGraph.SIZE_STEP,
            "group": "Picture",
            "tooltip": "How wide the picture is, in pixels.\n\nRounded down to a multiple of %d. Models are trained at a size — around 512 for\nthe older ones, 1024 for SDXL — and asking for much more than that gives you\nthe same picture twice in one frame rather than more detail.\n\nStarting from a selected image, this is only the size the server works at: the\nsource is scaled to it on the way over and the result is put back on the way\nhome." % IWComfyGraph.SIZE_STEP,
        },
        {
            "property": &"height",
            "label": "Height",
            "type": SettingType.INT,
            "min": MIN_SIZE,
            "max": MAX_SIZE,
            "step": IWComfyGraph.SIZE_STEP,
            "group": "Picture",
            "tooltip": "How tall the picture is, in pixels.\n\nRounded down to a multiple of %d, for the reason the width is." % IWComfyGraph.SIZE_STEP,
        },
    ]


## Never called. The dock's Save writes the picture the server sent rather than running
## anything, and nothing puts this operation in a stack. It is here because [IWOperation]
## asks for it.
func process_image(source: Image) -> Image:
    return source
