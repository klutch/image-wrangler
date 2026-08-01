@tool
class_name NormalLayerSettings
extends Resource

## What every normal map generator carries, whatever it generates.
##
## Each generator's own settings extend this, so the two values saying how a layer joins
## the one above it are written once rather than four times. Ranges live in
## [method IWNormalLayer.combine_schema], not here.

## Which way this layer's map is merged into what the layers above it produced.
## See [enum IWNormalLayer.CombineMode].
@export var combine_mode: int = 0

## How much of this layer reaches the result, from none to all of it.
##
## Applied to the slope rather than to the finished colour, so zero gives back exactly what
## the layers above produced and every number between reads as a smooth dial rather than as
## a fade between two pictures.
@export var combine_opacity: float = 1.0


## A copy that belongs to no image.
##
## Nothing in a normal map generator is a coordinate, so the plain duplicate is the whole
## of it — but this is never actually asked for, since the Export tab describes the batch
## rather than any one image. It is here because the dock's codec walks every settings
## Resource alike.
func duplicate_for_new_image() -> Resource:
    return duplicate()
