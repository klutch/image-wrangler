@tool
class_name RemoveCreviceSettings
extends Resource

## Every tunable of [RemoveCrevice].
##
## Ranges live in [method RemoveCrevice.get_settings_schema], not here.

## How much further than its own tolerance a colour may stray to get through a
## squeeze.
##
## Added to whichever entry's tolerance the flood is carrying rather than replacing
## it, so it reads as "this much further than usual" and a tightly keyed colour stays
## tightly keyed. See [method IWPipelineContext.flood_key_for].
##
## One number for every key, unlike [member RemoveColorEntry.color_tolerance]. This is
## not a description of a background — it is how far a flood may leave one behind to
## get somewhere, and that is a property of the geometry being squeezed through rather
## than of the colour it started from.
@export var crevice_tolerance: float = 0.25

## How many near-background pixels one path may cross in total, so it must be at least
## as long as the constriction it has to get through.
##
## A total rather than a run that solid background resets, because a resetting count is
## not a limit at all: alternating between straying and landing on a pixel some key
## claims outright would buy a fresh budget every other step.
##
## One rather than zero, because a stage in the stack is there to do something. Zero
## still works and means the same as switching the entry off — kept legal so a saved
## file that turned the rule off keeps its place in the order.
@export var crevice_reach: int = 1


## A copy that belongs to no image. Nothing here is a coordinate and nothing is a
## nested Resource, so the plain duplicate is the whole of it.
func duplicate_for_new_image() -> RemoveCreviceSettings:
	return duplicate()
