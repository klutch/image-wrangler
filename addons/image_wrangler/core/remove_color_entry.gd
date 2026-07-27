@tool
class_name RemoveColorEntry
extends Resource

## One background colour [RemoveBackground] keys out, with the tolerance that
## belongs to it.
##
## The tolerance lives here rather than on the settings because a single global
## one cannot describe an image with more than one background. A near-white paper
## scan needs a loose tolerance to swallow its speckle; a flat green panel in the
## same image needs a tight one or it eats into the subject. Sharing one number
## between them means tuning for whichever is worse and accepting the other.

## Tolerance a new entry starts at.
##
## Tight, because a Remove Color is a colour the user chose and can see: it should take
## what was asked for and no more, and widening it is a deliberate act. An island
## starts much looser and for a different reason; see
## [constant IslandEntry.DEFAULT_TOLERANCE].
const DEFAULT_TOLERANCE := 0.02

## Widest tolerance offered. The max-channel metric this is compared against
## cannot exceed 1.0, and half of that already keys out most of any image.
const MAX_TOLERANCE := 0.5

## The background colour itself.
@export var color: Color = Color.WHITE

## How far a pixel may drift from [member color] and still count as pure
## background.
@export var color_tolerance: float = DEFAULT_TOLERANCE

## Off excludes this colour from the run without losing it, so a tolerance worth
## keeping can be set aside and brought back rather than retyped.
@export var enabled: bool = true


## An independent copy, so two images never share one entry.
func duplicate_entry() -> RemoveColorEntry:
	var copy := RemoveColorEntry.new()
	copy.color = color
	copy.color_tolerance = color_tolerance
	copy.enabled = enabled
	return copy
