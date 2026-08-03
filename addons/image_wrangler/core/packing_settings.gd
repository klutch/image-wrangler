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

## Empty pixels kept between the sprites, and between the sprites and the sheet's edges.
##
## One is enough to stop texture filtering pulling a neighbour's colour in at the rim.
## Zero packs the sprites shoulder to shoulder.
@export var padding: int = 1

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
## It is a second file, not a change to the sheet: two pixels per sprite, holding where
## that sprite landed and its pivot. See [IWPacking]'s class note for what is in it and how
## it is read.
##
## On by default. A packed sheet is close to unusable without something naming where each
## sprite went, and the table costs a small file next to the sheet rather than anything in
## it — so having it and not needing it is the cheaper mistake of the two.
@export var create_lookup_table: bool = true

## Whether the rim of each sprite takes the shape found just inside it.
##
## On by default. The outermost pixels are where every generator is least sure — there is no
## room left to roll off in, the colours are half-covered by antialiasing, and a network is
## guessing — so a rim of noise around otherwise clean art is the usual result rather than
## the unusual one. Applied once to the finished stack, like [member normal_green_down].
@export var normal_clean_edges: bool = true

## How deep the rim is taken to be, in pixels, and so how far in the replacements come from.
##
## One is the single outermost ring of pixels, which is enough for most art. Larger numbers
## reach past a thicker band of antialiasing, at the cost of flattening detail that genuinely
## belongs near the outline.
@export var normal_inner_reach: int = 1

## Whether green is written the way DirectX reads it rather than the way Godot does.
##
## Off is right for Godot. The one thing about a normal map that no two engines agree on,
## and the only part of the normal map that is not a property of one generator: it is
## applied once to the finished stack. See [method IWPacking.build_normal_map].
@export var normal_green_down: bool = false

## Pivots set by hand on the sheet, one entry per sprite that was edited. See [PivotList].
##
## Only the lookup table reads these — a pivot changes nothing about the pixels. Sprites
## with no entry take the middle of their rectangle facing [constant
## Pivot.DEFAULT_DIRECTION].
@export var pivots: PivotList


func _init() -> void:
    pivots = PivotList.new()


## A copy that belongs to no image.
##
## The pivots are the one part that is coordinates, and they are copied rather than shared
## so the two settings cannot edit each other's. This is never actually asked for, since the
## packing settings describe the batch rather than any one image. It is here because the
## dock's codec walks every settings Resource alike.
func duplicate_for_new_image() -> PackingSettings:
    var copy: PackingSettings = duplicate()
    copy.pivots = pivots.duplicate_pivots() if pivots != null else PivotList.new()
    return copy
