@tool
class_name DenoiseSettings
extends Resource

## Every tunable of [Denoise].
##
## Ranges live in [method Denoise.get_settings_schema], not here.

## What the filter trades against how long it takes.
##
## An ordinary zero-based enum, because Open Image Denoise's own quality constants are
## neither zero-based nor consecutive — [code]IWStageKernels.denoise[/code] maps this
## index onto them by hand, which is what keeps the two from having to agree on numbers.
enum Quality { FAST, BALANCED, HIGH }

## How much of the filtered result replaces the original, 0 to 1.
##
## Blended rather than switched, because a filter strong enough to clear compression
## noise off a flat ground is also strong enough to take the tooth off a drawn line, and
## where between those the answer sits is not something the stage can know.
##
## At 0 the stage does nothing and the pixels are handed on untouched — the same as
## switching the entry off, and kept legal so that a stack turned down to nothing keeps
## its place in the order rather than having to be deleted and re-added.
@export var blend: float = 1.0

## Which of the filter's quality levels to run.
##
## High by default: this stage is not in the default stack, so anyone who added it wants
## the result rather than the speed. Fast is for dialling the rest of the stack in on a
## large sheet, and is not the same image — put it back before processing the batch.
@export var quality: int = Quality.HIGH


## A copy that belongs to no image. Nothing here is a coordinate and nothing is a nested
## Resource, so the plain duplicate is the whole of it.
func duplicate_for_new_image() -> DenoiseSettings:
	return duplicate()
