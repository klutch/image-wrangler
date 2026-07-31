@tool
class_name UpscaleSettings
extends Resource

## Every tunable of [Upscale].
##
## Held once for the session and never written to a sidecar, like [RenameSettings] and
## [PackingSettings]: a scale ratio describes what you want out of the batch rather than
## anything about one image. [method IWOperation.settings_are_per_image] is what says so.
##
## Four of these are indices into the tables in [Upscale] rather than the values
## themselves. The dock's form builder writes an index for a dropdown, and the numbers
## behind them are not a range anything could slide along — the scales double and the
## denoise levels start at minus one. [member sharpen] is the exception and is the value
## itself, because it is the one setting here that really is a dial.

## Which network to run, as an index into [constant Upscale.ENGINE_LABELS].
##
## waifu2x by default, which is what this tab did before there was a choice.
##
## [b]Two of the others are read against whichever engine this names.[/b] The model list and
## the scale list both come from the engine, so moving this makes those two indices point
## into different lists — [method Upscale.sync_engine] is what puts them back on something
## real, and the dock rebuilds the form when it does.
@export var engine_index: int = 0

## Which denoise strength to run, as an index into [constant Upscale.NOISE_LABELS].
##
## waifu2x only. Real-ESRGAN has no denoising, and the setting is left out of its form.
##
## Off is not a strength of zero — it is a different trained model, one that upscales and
## leaves whatever grain it found where it was.
@export var noise_index: int = 1

## How much larger the result is, as an index into [method Upscale.scale_labels].
##
## Two by default, which on waifu2x is the ratio it was trained for and the only one it
## does in a single pass — everything above is that pass run again on its own output. The
## list is a different one on Real-ESRGAN, and comes from the model rather than from code.
@export var scale_index: int = 1

## Which trained model to run, as an index into [method Upscale.model_names].
##
## An index rather than a name because these settings never outlive the session, so there
## is nothing for a name to stay stable across. [method Upscale.model_name] pulls it back
## into range for a folder that has been added or removed while the dock was open, and
## [method Upscale.sync_engine] moves it onto the other engine's list when that changes.
@export var model_index: int = 0

## How hard to tighten the antialiasing round the object, 0 to 1.
##
## Zero by default, which changes nothing. The network carries transparency across on a
## bicubic resize rather than through itself, and what that leaves is a soft ramp — right
## for some art and too woolly for a sprite meant to read crisply against a background.
##
## At 1 the ramp is gone entirely and the edge is a hard cut. The object does not change
## size at any setting; see [method IWStageKernels.sharpen_alpha].
@export var sharpen: float = 0.0

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
