@tool
class_name RefineEdgesSettings
extends Resource

## Every tunable of [RefineEdges].
##
## Ranges live in [method RefineEdges.get_settings_schema], not here.

## Window radius for the guided filter. Roughly how far a ragged patch of alpha may
## be from a real edge and still be pulled onto it.
##
## Zero switches the filter off and leaves the clip below, which is a real request
## rather than a disabled state: an edge that only needs its extremes pushed apart
## does not want smoothing first. That is also what the stage's old on/off bool
## meant, now that the entry's own tick says whether the stage runs at all.
@export var refine_radius: int = 2

## Alpha at or below this is forced clear; [member alpha_ceiling] and above is
## forced solid; the range between is stretched across the two.
##
## After the filter, so it also settles whatever that left behind. Smoothing pulls a
## leftover speck of background towards its transparent neighbours rather than
## removing it, which turns a solid speck into a faint ghost; lifting the floor above
## where those ghosts land clears them. It costs edge softness in exchange, since
## genuinely faint edge pixels go with them — the usual clip-black/clip-white trade
## from keying. At 0 and 1 the clip is a no-op.
@export var alpha_floor: float = 0.0

## Alpha at or above this is forced solid. See [member alpha_floor].
@export var alpha_ceiling: float = 1.0


## A copy that belongs to no image. Nothing here is a coordinate and nothing is a
## nested Resource, so the plain duplicate is the whole of it.
func duplicate_for_new_image() -> RefineEdgesSettings:
	return duplicate()
