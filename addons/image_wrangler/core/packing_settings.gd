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

## Which normal map is generated alongside the sheet. See [enum IWPacking.NormalMode].
##
## Disabled by default, since a normal map is worth having only when something is going to
## light the sheet. It writes a file beside the sheet rather than changing it, the way
## [member create_lookup_table] does.
@export var normals: int = 0

## How far the rounding tips the surface over, against the roll-off distance.
##
## Measured that way rather than in pixels so the slope holds when [member normal_roll_off]
## is dragged. Used by Round Edges and Color Regions.
@export var normal_strength: float = 0.5

## How far in from the outline the rounding reaches, in pixels.
##
## Past this the sprite is flat. Used by Round Edges and Color Regions.
@export var normal_roll_off: int = 8

## The shape the rounding takes. See [enum IWPacking.NormalCurve].
@export var normal_curve: int = 0

## How far apart two neighbouring colours have to be before the boundary between them is
## rounded off as well as the outline.
##
## Nothing but Color Regions reads it, and it is the whole of what separates that mode from
## Round Edges.
@export var normal_color_tolerance: float = 0.15

## How much of the sprite's overall shading becomes shape, and how far the pass looks to
## decide what counts as overall rather than as detail.
##
## Zero strength skips the pass. Used by Brightness.
##
## The strength is a plain multiplier on a gradient of brightness, and the gradient across
## even a hard painted edge is small — so the useful numbers are several, not fractions.
@export var normal_coarse: float = 4.0
@export var normal_coarse_size: int = 6

## How much of the sprite's line work and texture becomes shape.
##
## Read from the colours as they are rather than from a blur, so it picks up single pixels.
## Zero skips the pass. On the same scale as [member normal_coarse]. Used by Brightness.
@export var normal_fine: float = 3.0

## Whether green is written the way DirectX reads it rather than the way Godot does.
##
## Off is right for Godot. The one thing about a normal map that no two engines agree on,
## and the only setting here every mode reads.
@export var normal_green_down: bool = false

## The folder holding the converted model the neural mode runs, as a path.
##
## No model ships with this addon, so this is empty until you convert one and say where it
## went. The mode is not offered while it holds neither of the two files.
@export var normal_model_dir: String = ""


## A copy that belongs to no image.
##
## Nothing here is a coordinate, so the plain duplicate is the whole of it — but this is
## never actually asked for, since the packing settings describe the batch rather than any
## one image. It is here because the dock's codec walks every settings Resource alike.
func duplicate_for_new_image() -> PackingSettings:
    return duplicate()
