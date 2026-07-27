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

## Background colours keyed out from the image border inwards, each with its own
## tolerance. See [RemoveColorEntry].
##
## From the border [i]inwards[/i], and only from there while [member contiguous]
## is set: an entry seeds the flood where its colour meets the edge of the image.
## Listing a colour is therefore not the same as removing every pixel of it —
## a region enclosed by the subject needs an entry in [member islands] instead.
##
## An empty list keys nothing out from the border. That is a real state rather
## than a broken one — an image whose only backgrounds are enclosed regions is
## described by islands alone.
@export var remove_colors: RemoveColorList

## Width of the antialiased band, in pixels. Pixels within this many steps of the
## background are treated as a soft edge and given partial alpha; anything
## further in is fully opaque subject.
@export var edge_width: int = 2

## Only remove background reachable from the image border, so regions enclosed by
## the subject (eyes, speech bubbles, specular highlights) stay opaque.
@export var contiguous: bool = true

## How far from the keying colour the flood may stray to squeeze through a gap
## too narrow to hold a single clean background pixel. Only has an effect while
## [member crevice_reach] is above zero. See [method RemoveBackground._flood_take].
##
## One number for every key, unlike [member RemoveColorEntry.color_tolerance].
## This is not a description of a background — it is how far the flood may leave
## one behind to get somewhere, and that is a property of the geometry it is
## squeezing through rather than of the colour it started from.
@export var crevice_tolerance: float = 0.5

## How many near-background pixels in a row the flood may cross before it needs
## solid background again, so it must be at least as long as the constriction it
## has to squeeze through. Zero disables the whole mechanism, leaving the flood
## strictly within each key's own tolerance.
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
## These describe one particular image harder than anything else here does: every
## other setting is a number that would at least mean something applied to a
## different image, where a coordinate simply would not.
@export var islands: IslandList

## Regions forced fully transparent whatever is in them. See [BlackoutPolygon].
##
## The one part of this operation that does not remove background by colour, and
## so the only way to describe something that has no colour in common with itself
## — a watermark, a scan edge, a stray element in a corner. Coordinates, like
## [member islands], and just as meaningless applied to another image.
@export var blackout: BlackoutList

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

## Re-matte edges that ended up hard, working the coverage back out of the
## colours either side of them. See [method RemoveBackground._restore_edges].
##
## Off by default because a correctly keyed image has nothing for it to do: the
## edge band already builds the matte. It earns its place on an edge that never
## got one — a source that was aliased before it arrived, or an edge a hard
## setting elsewhere flattened.
@export var restore_edges: bool = false

## Take the subject colour from a step further into the opaque shape rather than
## from the nearest opaque pixel.
##
## The pixel on the boundary is itself part background, which is the whole reason
## it is being restored. Measuring against it asks how much of a blend a blend is
## and answers "all of it". A step inward gets past the contamination to something
## that is only subject.
@export var sample_color_inward: bool = true


func _init() -> void:
	islands = IslandList.new()
	blackout = BlackoutList.new()
	# One white entry rather than none, so a fresh image starts where the single
	# Remove Color swatch used to: keying out white at 0.02.
	remove_colors = RemoveColorList.new()
	remove_colors.add(Color.WHITE)


## A copy that belongs to no image: every value kept except the two that are
## coordinates, which start empty.
##
## Used when the selection leaves the list and the form is left describing
## nothing. The numbers can stay on screen; the picked points and drawn polygons
## cannot, since the image they were placed in is gone.
##
## [method Resource.duplicate] copies the *references* held in [member islands],
## [member blackout] and [member remove_colors], so without the replacements
## below the copy would share all three with the original and editing either
## would silently edit both.
func duplicate_for_new_image() -> RemoveBackgroundSettings:
	var copy: RemoveBackgroundSettings = duplicate()
	copy.islands = IslandList.new()
	copy.blackout = BlackoutList.new()
	copy.remove_colors = remove_colors.duplicate_colors()
	return copy


## Called by [method IWSettingsIO.load_settings] once a sidecar has been decoded.
##
## Islands used to be bare coordinates and are now entries carrying a switch and
## a mode. A file written before that change still has the old array, and the
## codec cannot tell that the two describe the same thing — so without this every
## island anyone had picked would quietly vanish the first time they reopened an
## image.
func migrate_loaded() -> void:
	if islands != null:
		islands.migrate_legacy()
