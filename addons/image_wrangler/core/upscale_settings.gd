@tool
class_name UpscaleSettings
extends Resource

## Every tunable of [Upscale].
##
## Held once for the session and never written to a sidecar, like [RenameSettings] and
## [PackingSettings]: a scale ratio describes what you want out of the batch rather than
## anything about one image. [method IWOperation.settings_are_per_image] is what says so.
##
## All four are indices into the tables in [Upscale] rather than the values themselves. The
## dock's form builder writes an index for a dropdown, and the numbers behind three of these
## are not a range anything could slide along — the scales double and the denoise levels
## start at minus one.

## Which denoise strength to run, as an index into [constant Upscale.NOISE_LABELS].
##
## Off is not a strength of zero — it is a different trained model, one that upscales and
## leaves whatever grain it found where it was.
@export var noise_index: int = 1

## How much larger the result is, as an index into [constant Upscale.SCALE_LABELS].
##
## Two by default, which is the ratio waifu2x was trained for and the only one it does in a
## single pass. Everything above is that pass run again on its own output.
@export var scale_index: int = 1

## Which trained model to run, as an index into [method Upscale.model_names].
##
## An index rather than a name because these settings never outlive the session, so there
## is nothing for a name to stay stable across. [method Upscale.model_name] pulls it back
## into range for a folder that has been added or removed while the dock was open.
@export var model_index: int = 0

## Runs the image eight ways — every rotation and flip — and averages the results.
##
## Off by default. It costs eight times the work for a difference you have to go looking
## for, which is a bargain worth making on a final pass over a handful of images and not
## one worth making while you are still choosing a model.
@export var tta: bool = false


## A copy that belongs to no image. Nothing here is a coordinate and nothing is a nested
## Resource, so the plain duplicate is the whole of it.
func duplicate_for_new_image() -> UpscaleSettings:
    return duplicate()
