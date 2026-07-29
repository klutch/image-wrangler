@tool
class_name RepackSettings
extends Resource

## Every tunable of [IWRepack].
##
## Ranges live in [method IWRepack.get_settings_schema], not here.

## Which arrangement the sprites are laid out in. See [enum IWRepack.PackMode].
@export var mode: int = 0

## How big the sheet being packed into is, in pixels.
##
## Not derived from what the sprites need, and deliberately: a sheet is usually a size
## something else has already decided — a texture budget, a hardware limit, an atlas the
## rest of the project agrees on. Packing into a size you chose and being told when it does
## not fit is the useful answer; packing into whatever happens to fit is not.
@export var output_width: int = 1024
@export var output_height: int = 1024


## A copy that belongs to no image.
##
## Nothing here is a coordinate, so the plain duplicate is the whole of it — but this is
## never actually asked for, since the repack settings describe the batch rather than any
## one image. It is here because the dock's codec walks every settings Resource alike.
func duplicate_for_new_image() -> RepackSettings:
    return duplicate()
