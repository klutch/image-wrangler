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

## How far the flood may stray from a keying colour to squeeze through a gap too
## narrow to hold a single clean background pixel. Only has an effect while
## [member crevice_reach] is above zero.
##
## One number for every key, unlike [member RemoveColorEntry.color_tolerance]. This is
## not a description of a background — it is how far the flood may leave one behind to
## get somewhere, and that is a property of the geometry it is squeezing through rather
## than of the colour it started from.
##
## It belongs to the flood, and so it belongs here: the rule is applied against the
## tolerance of whichever entry the flood is carrying at that moment, and every entry
## keeps its own. A gap off a tightly toleranced colour must not open up on a loosely
## toleranced one's terms.
@export var crevice_tolerance: float = 0.5

## How many near-background pixels in a row the flood may cross before it needs solid
## background again, so it must be at least as long as the constriction it has to
## squeeze through. Zero disables the mechanism, leaving the flood strictly within each
## key's own tolerance.
##
## Setting it generously is safer than it sounds. Somewhere the flood reaches only by
## straying is reclassified as edge rather than background, so it is matted by the
## usual coverage maths instead of being cut out — and genuine subject measures as
## fully covered there, so it keeps its alpha. Straying too far wastes work rather than
## eating the subject.
@export var crevice_reach: int = 0

## Un-blend the background out of partially transparent pixels.
@export var decontaminate: bool = true

## How far subject colour is pushed into transparent pixels, in pixels.
@export var bleed_radius: int = 16


func _init() -> void:
	# One white entry rather than none, so a fresh image starts where the single
	# Remove Color swatch used to: keying out white at 0.02.
	remove_colors = RemoveColorList.new()
	remove_colors.add(Color.WHITE)


## A copy that belongs to no image.
##
## Used when the selection leaves the list and the form is left describing nothing.
## Nothing here is a coordinate, so every value survives — but
## [method Resource.duplicate] copies the *reference* held in
## [member remove_colors], and without the replacement below the copy would share
## that list with the original, so editing either would silently edit both.
func duplicate_for_new_image() -> RemoveBackgroundSettings:
	var copy: RemoveBackgroundSettings = duplicate()
	copy.remove_colors = remove_colors.duplicate_colors()
	return copy
