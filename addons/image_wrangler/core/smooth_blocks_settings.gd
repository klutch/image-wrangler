@tool
class_name SmoothBlocksSettings
extends Resource

## Every tunable of [SmoothBlocks].
##
## Ranges live in [method SmoothBlocks.get_settings_schema], not here.

## How big a step across a block seam still counts as an artifact rather than a real
## edge. Roughly how badly the image was compressed.
@export var threshold: float = 0.06

## How much of each seam is flattened. Zero changes nothing.
@export var amount: float = 1.0


## A copy that belongs to no image. Nothing here is a coordinate and nothing is a
## nested Resource, so the plain duplicate is the whole of it.
func duplicate_for_new_image() -> SmoothBlocksSettings:
    return duplicate()
