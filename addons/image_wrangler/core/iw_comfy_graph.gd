@tool
class_name IWComfyGraph
extends RefCounted

## Turns the Generate tab's settings into the node graph ComfyUI runs.
##
## ComfyUI's API format: one entry per node, keyed by an id, each naming a class and its
## inputs. An input wired from another node is [code][id, slot][/code] rather than a value.
## The ids are fixed so a graph dumped while debugging reads the same every time.

## What the LoRA dropdown shows when none is wanted.
##
## Not a server value. ComfyUI checks the name against the list it offered and answers 400
## for anything else, so this means "leave the node out" rather than "send an empty name".
const LORA_NONE := "(none)"

## Where the pictures land inside ComfyUI's own output folder.
const FILENAME_PREFIX := "image_wrangler/iw"

## Sizes have to be a multiple of this. A latent is one eighth of the picture, so a width
## the sampler cannot divide comes back as a size nobody asked for.
const SIZE_STEP := 8

## The largest seed the form can hold. The spinner is float-backed, and a seed that cannot
## be typed back in exactly is worth nothing.
const MAX_SEED := 2147483647


## The graph for one run.
##
## [param seed_value] is passed in rather than read off [param settings], because a
## randomised run draws it at the last moment and the caller is what writes it back.
##
## [param source_name] is what a picture was uploaded to the server under, or empty for a
## run from noise.
static func build(settings: IWGenerateSettings, seed_value: int,
        source_name := "") -> Dictionary:
    var with_lora := not settings.lora.is_empty() and settings.lora != LORA_NONE
    var model_from := ["10", 0] if with_lora else ["4", 0]
    var clip_from := ["10", 1] if with_lora else ["4", 1]
    var from_source := settings.use_source and not source_name.is_empty()
    var latent_from := ["12", 0] if from_source else ["5", 0]

    var graph := {
        "4": {
            "class_type": "CheckpointLoaderSimple",
            "inputs": {"ckpt_name": settings.checkpoint},
        },
        "6": {
            "class_type": "CLIPTextEncode",
            "inputs": {"text": settings.positive, "clip": clip_from},
        },
        "7": {
            "class_type": "CLIPTextEncode",
            "inputs": {"text": settings.negative, "clip": clip_from},
        },
        "3": {
            "class_type": "KSampler",
            "inputs": {
                "seed": seed_value,
                "steps": settings.steps,
                "cfg": settings.cfg,
                "sampler_name": settings.sampler,
                "scheduler": settings.scheduler,
                "denoise": settings.denoise,
                "model": model_from,
                "positive": ["6", 0],
                "negative": ["7", 0],
                "latent_image": latent_from,
            },
        },
        "8": {
            "class_type": "VAEDecode",
            "inputs": {"samples": ["3", 0], "vae": ["4", 2]},
        },
        "9": {
            "class_type": "SaveImage",
            "inputs": {"filename_prefix": FILENAME_PREFIX, "images": ["8", 0]},
        },
    }

    # One or the other feeds the sampler. LoadImage names what the upload left in the
    # server's input folder.
    if from_source:
        graph["11"] = {
            "class_type": "LoadImage",
            "inputs": {"image": source_name},
        }
        graph["12"] = {
            "class_type": "VAEEncode",
            "inputs": {"pixels": ["11", 0], "vae": ["4", 2]},
        }
    else:
        var size := working_size(settings)
        graph["5"] = {
            "class_type": "EmptyLatentImage",
            "inputs": {"width": size.x, "height": size.y, "batch_size": 1},
        }

    # Left out entirely rather than sent empty, and the two prompts and the sampler read
    # from the checkpoint instead. See LORA_NONE.
    if with_lora:
        graph["10"] = {
            "class_type": "LoraLoader",
            "inputs": {
                "lora_name": settings.lora,
                "strength_model": settings.lora_strength,
                "strength_clip": settings.lora_strength,
                "model": ["4", 0],
                "clip": ["4", 1],
            },
        }
    return graph


## The size the server is asked to work at, rounded to something a sampler can divide.
##
## Public so a caller scaling a source picture uses the same number the graph would have.
static func working_size(settings: IWGenerateSettings) -> Vector2i:
    return Vector2i(_snapped(settings.width), _snapped(settings.height))


## Whether [param settings] names everything the graph needs. Empty when it does.
##
## [param has_source] only matters when the settings asked to start from a picture.
static func trouble(settings: IWGenerateSettings, has_source := true) -> String:
    if settings == null:
        return "No settings."
    if settings.checkpoint.is_empty():
        return "Pick a checkpoint first."
    if settings.sampler.is_empty() or settings.scheduler.is_empty():
        return "Pick a sampler and a scheduler first."
    if settings.positive.strip_edges().is_empty():
        return "Write a description first."
    if settings.use_source and not has_source:
        return "Pick an image in the list first, or turn off Start From Selected Image."
    return ""


static func _snapped(size: int) -> int:
    return maxi(int(size / SIZE_STEP) * SIZE_STEP, SIZE_STEP)
