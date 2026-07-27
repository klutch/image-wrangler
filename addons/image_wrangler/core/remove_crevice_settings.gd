@tool
class_name RemoveCreviceSettings
extends Resource

## Every tunable of [RemoveCrevice].
##
## Ranges are deliberately not declared here.
## [method RemoveCrevice.get_settings_schema] is the single place min, max and step
## are written down; repeating them in [code]@export_range[/code] would give two
## sources of truth free to drift apart.

## How far from the keying colour the growth may stray to squeeze through a gap too
## narrow to hold a single clean background pixel.
##
## One number for every key, unlike [member RemoveColorEntry.color_tolerance]. This
## is not a description of a background — it is how far the growth may leave one
## behind to get somewhere, and that is a property of the geometry it is squeezing
## through rather than of the colour it started from.
@export var crevice_tolerance: float = 0.5

## How many near-background pixels in a row may be crossed before solid background
## is needed again, so it must be at least as long as the constriction it has to
## squeeze through. Zero switches the stage off entirely.
##
## Setting it generously is safer than it sounds. Somewhere reached only by straying
## is classed as edge rather than background, so it is matted by the usual coverage
## maths instead of being cut out — and genuine subject measures as fully covered
## there, so it keeps its alpha. Straying too far wastes work rather than eating the
## subject.
@export var crevice_reach: int = 2


## A copy that belongs to no image. Nothing here is a coordinate and nothing is a
## nested Resource, so the plain duplicate is the whole of it.
func duplicate_for_new_image() -> RemoveCreviceSettings:
	return duplicate()
