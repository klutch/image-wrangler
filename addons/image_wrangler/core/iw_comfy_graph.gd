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


## The graph for one text to image run.
##
## [param seed_value] is passed in rather than read off [param settings], because a
## randomised run draws it at the last moment and the caller is what writes it back.
static func build(settings: IWGenerateSettings, seed_value: int) -> Dictionary:
    var with_lora := not settings.lora.is_empty() and settings.lora != LORA_NONE
    var model_from := ["10", 0] if with_lora else ["4", 0]
    var clip_from := ["10", 1] if with_lora else ["4", 1]

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
        "5": {
            "class_type": "EmptyLatentImage",
            "inputs": {
                "width": _snapped(settings.width),
                "height": _snapped(settings.height),
                "batch_size": 1,
            },
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
                "latent_image": ["5", 0],
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


## Whether [param settings] names everything the graph needs. Empty when it does.
static func trouble(settings: IWGenerateSettings) -> String:
    if settings == null:
        return "No settings."
    if settings.checkpoint.is_empty():
        return "Pick a checkpoint first."
    if settings.sampler.is_empty() or settings.scheduler.is_empty():
        return "Pick a sampler and a scheduler first."
    if settings.positive.strip_edges().is_empty():
        return "Write a description first."
    return ""


static func _snapped(size: int) -> int:
    return maxi(int(size / SIZE_STEP) * SIZE_STEP, SIZE_STEP)
