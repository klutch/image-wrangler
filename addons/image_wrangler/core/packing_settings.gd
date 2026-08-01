@tool
class_name PackingSettings
extends Resource

## Every tunable of [IWPacking].
##
## Ranges live in [method IWPacking.get_settings_schema], not here.

## Which arrangement the sprites are laid out in. See [enum IWPacking.PackMode].
@export var mode: int = 0

## How big the sheet being packed into starts, in pixels.
##
## Where it ends up is [member expand_to_fit]'s business: on, this is a starting point and
## the sheet doubles from it; off, it is exactly the size used. Either way it is a size
## chosen rather than derived, because a sheet is usually one something else has already
## decided — a texture budget, a hardware limit, an atlas the rest of the project agrees on.
@export var output_width: int = 1024
@export var output_height: int = 1024

## Whether the sheet may double until everything fits.
##
## On by default, and for every mode: a packing that comes back with the sprites on it is
## almost always what was wanted, and the size is easier to argue with once you can see
## what went on it. Switch it off to hold the sheet at exactly the size asked for and be
## told when that is not enough — which is the right way round when the size is one
## something else has already decided.
@export var expand_to_fit: bool = true

## Whether a lookup table is written beside the sheet when it is saved.
##
## It is a second file, not a change to the sheet: one pixel per sprite, holding where that
## sprite landed. See [IWPacking]'s class note for what is in it and how it is read.
##
## On by default. A packed sheet is close to unusable without something naming where each
## sprite went, and the table costs a small file next to the sheet rather than anything in
## it — so having it and not needing it is the cheaper mistake of the two.
@export var create_lookup_table: bool = true


## A copy that belongs to no image.
##
## Nothing here is a coordinate, so the plain duplicate is the whole of it — but this is
## never actually asked for, since the packing settings describe the batch rather than any
## one image. It is here because the dock's codec walks every settings Resource alike.
func duplicate_for_new_image() -> PackingSettings:
    return duplicate()
