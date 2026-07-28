@tool
class_name RemoveColorSample
extends Resource

## One background colour keyed out, with the tolerance that belongs to it.
##
## Split out of [RemoveColorEntry] when picking stopped being a single click. A
## rectangle swept over the preview is not one colour — a background is speckled, or
## compressed, or lit unevenly — so what comes back is a set of them, and the entry
## became the group they are managed as.
##
## [b]The tolerance lives here rather than on the group[/b] for the reason it never
## lived on the settings: one number cannot describe two things. A near-white paper
## scan needs a loose tolerance to swallow its speckle; the flat green panel beside it
## in the same image needs a tight one or it eats into the subject. Sharing one number
## between them means tuning for whichever is worse and accepting the other — and a
## swept region routinely picks up both at once.

## Tolerance a new sample starts at.
##
## Tight, because a Remove Color is a colour the user chose and can see: it should take
## what was asked for and no more, and widening it is a deliberate act. An island
## starts much looser and for a different reason; see
## [constant IslandPick.DEFAULT_TOLERANCE].
const DEFAULT_TOLERANCE := 0.02

## The background colour itself.
##
## Stored, unlike an island's, because it is not a place: an island points at a region
## and reads whatever is there when it runs, where this [i]is[/i] the rule. Alpha is
## carried but never read — see [method IWPipelineContext.distance_at].
@export var color: Color = Color.WHITE

## How far a pixel may drift from [member color] and still count as pure background.
@export var color_tolerance: float = DEFAULT_TOLERANCE


## How far apart two colours are, by the measure the keyer actually uses.
##
## The same max-channel metric as [method IWPipelineContext.distance_at], and it has to
## be: this is what decides whether a colour a sweep found is a rule worth adding or
## one an entry already covers, and an answer measured differently from the answer the
## flood gives would list colours that key out nothing.
static func distance(a: Color, b: Color) -> float:
	return maxf(absf(a.r - b.r), maxf(absf(a.g - b.g), absf(a.b - b.b)))


## An independent copy, so two entries never share one sample.
func duplicate_sample() -> RemoveColorSample:
	var copy := RemoveColorSample.new()
	copy.color = color
	copy.color_tolerance = color_tolerance
	return copy
