@tool
class_name IWGenerateSettings
extends Resource

## Every tunable of [IWGenerate].
##
## Ranges live in [method IWGenerate.get_settings_schema], not here. The names of models
## and samplers are held as text rather than as a position in a list, because the list
## comes from the server and can reorder between one session and the next.

## Which checkpoint makes the picture. A name the server offered, or empty until it has
## been asked.
@export var checkpoint: String = ""

## Which LoRA rides on top of the checkpoint, or [constant IWComfyGraph.LORA_NONE] for
## none. Empty counts as none.
@export var lora: String = IWComfyGraph.LORA_NONE

## How strongly that LoRA is applied, to both the model and the text encoder.
@export var lora_strength: float = 1.0

## What to make.
@export var positive: String = ""

## What to keep out of it.
@export var negative: String = ""

## Which sampler walks the noise back to a picture, and the schedule it walks on. Both are
## names the server offered.
@export var sampler: String = "euler"
@export var scheduler: String = "normal"

## How many steps that walk takes. More is slower and, past a point, no better.
@export var steps: int = 20

## How hard the description is pushed. Too high burns the picture, too low ignores you.
@export var cfg: float = 7.0

## The number the noise is made from. The same seed and the same settings give the same
## picture back.
@export var seed: int = 0

## Whether a fresh seed is drawn for each run. The one that was used is written back into
## [member seed], so the picture on screen can always be made again.
@export var randomize_seed: bool = true

## Whether the run starts from the highlighted image, with its stack applied, rather than
## from noise. [member denoise] decides how much of it survives.
@export var use_source: bool = false

## How big the picture is, in pixels. Multiples of [constant IWComfyGraph.SIZE_STEP], and
## only the size the server works at when [member use_source] is on.
@export var width: int = 1024
@export var height: int = 1024

## How much of the noise is walked back. One is a picture from nothing, which is what text
## to image means; lower only has meaning once there is a picture to start from.
@export var denoise: float = 1.0


## A copy that belongs to no image.
##
## Nothing here is a coordinate, and this is never actually asked for — the settings
## describe the tab rather than any one picture. It is here because the dock's codec walks
## every settings Resource alike.
func duplicate_for_new_image() -> IWGenerateSettings:
    return duplicate()
