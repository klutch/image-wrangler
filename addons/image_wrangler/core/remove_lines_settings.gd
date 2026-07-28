@tool
class_name RemoveLinesSettings
extends Resource

## Every tunable of [RemoveLines].
##
## Ranges live in [method RemoveLines.get_settings_schema], not here.

## The widest structure that gets removed, in pixels.
##
## Read as a width the user can measure off the image rather than as a radius or a
## reach: at one, a one-pixel hairline goes and a two-pixel line stays. The kernel
## turns it into a square of side [code]thickness + 1[/code] — the smallest square a
## shape must have room for to count as thick enough — which is what makes the
## boundary land exactly between the number and the next one up.
##
## One rather than zero, because a stage in the stack is there to do something. Zero
## still works and means the same as switching the entry off, so a saved file that
## turned the rule off keeps its place in the order.
@export var thickness: int = 1

## Whether a thin part hanging off something thick is spared.
##
## On, because the usual job is debris — hairlines, scan borders, specks — sitting in
## the transparency beside a subject that is nothing to do with them, and taking a
## whisker off the subject at the same time is a second decision the user did not
## make. Off is the plain opening and is the right answer when the thin parts [i]are[/i]
## the problem.
@export var detached_only: bool = true


## A copy that belongs to no image. Nothing here is a coordinate and nothing is a
## nested Resource, so the plain duplicate is the whole of it.
func duplicate_for_new_image() -> RemoveLinesSettings:
	return duplicate()
