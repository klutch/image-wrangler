@tool
class_name RemoveBackgroundSettings
extends Resource

## Every tunable of [RemoveBackground], in one object the dock can swap.
##
## Split out from the operation so that each image can hold its own. The dock
## keeps one of these per source file, loads it from that file's JSON sidecar
## when there is one, and points the operation at whichever belongs to the image
## on screen.
##
## Ranges are deliberately not declared here. [method
## RemoveBackground.get_settings_schema] is the single place min, max and step
## are written down; repeating them in [code]@export_range[/code] would give two
## sources of truth free to drift apart. Values arriving from a saved file are
## put back inside those ranges by [method IWOperation.clamp_settings_to_schema].

## Background colour keyed out from the image border inwards.
@export var key_color: Color = Color.WHITE

## How far a pixel may drift from the colour keying its region and still count as
## pure background.
@export var tolerance: float = 0.02

## Width of the antialiased band, in pixels. Pixels within this many steps of the
## background are treated as a soft edge and given partial alpha; anything
## further in is fully opaque subject.
@export var edge_width: int = 2

## Only remove background reachable from the image border, so regions enclosed by
## the subject (eyes, speech bubbles, specular highlights) stay opaque.
@export var contiguous: bool = true

## How far from the keying colour the flood may stray to squeeze through a gap
## too narrow to hold a single clean background pixel. Only has an effect while
## [member crevice_reach] is above zero. See [method RemoveBackground._flood_step].
@export var crevice_tolerance: float = 0.5

## How many near-background pixels in a row the flood may cross before it needs
## solid background again, so it must be at least as long as the constriction it
## has to squeeze through. Zero disables the whole mechanism, leaving the flood
## strictly within [member tolerance].
##
## Setting it generously is safer than it sounds. Somewhere the flood reaches
## only by straying is reclassified as edge rather than background, so it is
## matted by the usual coverage maths instead of being cut out — and genuine
## subject measures as fully covered there, so it keeps its alpha. Straying too
## far wastes work rather than eating the subject.
@export var crevice_reach: int = 0

## Extra pixels to start the background flood fill from, on top of the image
## border. Lets the user hand-pick enclosed regions that [member contiguous]
## deliberately skips.
##
## Each island keys out the colour of the pixel it lands on, sampled at process
## time rather than stored, so an island always removes exactly what was clicked
## and can never disagree with the image. Ignored when [member contiguous] is
## off, since every key-coloured pixel already qualifies then.
##
## These describe one particular image. Every other setting here is carried over
## to the next image that has no saved settings of its own; islands never are,
## because a coordinate in one image means nothing in another.
@export var islands: IslandList

## Un-blend the background out of partially transparent pixels.
@export var decontaminate: bool = true

## How far subject colour is pushed into transparent pixels, in pixels.
@export var bleed_radius: int = 16

## Run the alpha through a guided filter before compositing, snapping it to the
## edges the image itself has. See [method RemoveBackground._guided_refine].
@export var refine_edges: bool = false

## Window radius for that filter. Roughly how far a ragged patch of alpha may be
## from a real edge and still be pulled onto it.
@export var refine_radius: int = 2

## Alpha at or below this is forced clear; [member alpha_ceiling] and above is
## forced solid; the range between is stretched across the two.
##
## The last step before compositing, so it also settles whatever
## [member refine_edges] left behind. Smoothing pulls a leftover speck of
## background towards its transparent neighbours rather than removing it, which
## turns a solid speck into a faint ghost; lifting the floor above where those
## ghosts land clears them. It costs edge softness in exchange, since genuinely
## faint edge pixels go with them — the usual clip-black/clip-white trade from
## keying. At 0 and 1 the whole thing is a no-op.
@export var alpha_floor: float = 0.0

## Alpha at or above this is forced solid. See [member alpha_floor].
@export var alpha_ceiling: float = 1.0


func _init() -> void:
	islands = IslandList.new()


## A copy that belongs to another image: everything carried over except the
## islands, which start empty.
##
## [method Resource.duplicate] copies the *reference* held in [member islands],
## so without the replacement below two images would share one list and picking
## on either would silently edit both.
func duplicate_for_new_image() -> RemoveBackgroundSettings:
	var copy: RemoveBackgroundSettings = duplicate()
	copy.islands = IslandList.new()
	return copy
