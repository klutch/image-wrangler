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

## How much further than its own tolerance the flood may stray from a keying colour
## to squeeze through a gap too narrow to hold a single clean background pixel. Only
## has an effect while [member crevice_reach] is above zero.
##
## Added to whichever entry's tolerance the flood is carrying rather than replacing
## it, so it reads as "this much further than usual" and a tightly keyed colour stays
## tightly keyed. Replacing it — which is what taking the larger of the two amounts to
## — meant a colour keyed at a tolerance of nothing still strayed the whole of this,
## and the tolerance the user had set said nothing about where the flood went.
##
## One number for every key, unlike [member RemoveColorEntry.color_tolerance]. This is
## not a description of a background — it is how far the flood may leave one behind to
## get somewhere, and that is a property of the geometry it is squeezing through rather
## than of the colour it started from.
@export var crevice_tolerance: float = 0.5

## How many near-background pixels one path of the flood may cross in total, so it must
## be at least as long as the constriction it has to squeeze through. Zero disables the
## mechanism, leaving the flood strictly within each key's own tolerance.
##
## A total along each path rather than a run that solid background resets, because a
## resetting count is not a limit at all: alternating between straying and landing on
## a pixel some key claims outright bought a fresh budget every other step, and a white
## key at a tolerance of nothing would cross a coloured boundary and keep going. Each
## path from the border carries its own count, so a second flower reached through clean
## background still gets a full budget of its own.
##
## Setting it generously is safer than it sounds. Everywhere the flood reaches from a
## stray onwards is reclassified as edge rather than background, so it is matted by the
## usual coverage maths instead of being cut out — background beyond a crevice measures
## as background and still comes out, and genuine subject measures as fully covered, so
## it keeps its alpha. Straying too far wastes work rather than eating the subject.
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
