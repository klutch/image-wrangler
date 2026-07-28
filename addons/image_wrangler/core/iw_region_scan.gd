@tool
class_name IWRegionScan
extends RefCounted

## Walking a rectangle the user swept over the preview, at a stride that keeps the
## work bounded.
##
## Shared by the two pickers because they ask the same question of the same gesture
## and must not answer it differently. The Island Picker wants the positions inside
## the rectangle and the Remove Colors list wants the colours, but both have to say
## the same thing about how a rectangle is walked — and both have to stay finite when
## the rectangle is most of a large image.
##
## Nothing here is stateful. It is a pair of loops that two callers would otherwise
## write twice.


## How much of a pixel has to survive the stack before its colour is worth sampling.
##
## Fully, and not a threshold. Anything short of solid is a pixel some pass has already
## decided is partly background, and its colour is the blend that decision was made
## about — so there is no amount of "mostly there" that makes it a background colour.
const SOLID_ALPHA := 1.0


## Positions along one axis: [param start], then every [param step] pixels, then the
## far end of the run whether or not the stride landed on it.
##
## Both ends always, so a strided rectangle still describes the rectangle that was
## actually dragged rather than a slightly smaller one.
static func stops(start: int, count: int, step: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	if count <= 0:
		return out
	var last := start + count - 1
	var value := start
	while value < last:
		out.append(value)
		value += step
	out.append(last)
	return out


## The smallest stride that keeps [param region] to [param budget] samples or fewer.
##
## The square root is the answer for the interior and the loop is for the edges: both
## ends of both axes are always kept, so a stride that divides the rectangle awkwardly
## can still come out a row or a column over what the square root promised.
static func stride_for(region: Rect2i, budget: int) -> int:
	if region.size.x <= 0 or region.size.y <= 0 or budget <= 0:
		return 1
	var step := 1
	var area := region.size.x * region.size.y
	if area > budget:
		step = maxi(int(ceil(sqrt(float(area) / float(budget)))), 1)
	while stops(region.position.x, region.size.x, step).size() \
			* stops(region.position.y, region.size.y, step).size() > budget:
		step += 1
	return step


## Every distinct colour inside [param region] of [param image], most common first.
##
## [b]Distinct, because a colour is a rule rather than a place.[/b] Listing the same
## colour twice cannot key out anything listing it once did not — see
## [method RemoveColorList.claims] — so a hundred pixels of one flat background are one
## colour, not a hundred entries saying the same thing.
##
## [b]Most common first[/b] so that what stands for the region is the colour most of
## it actually is, and so that a cap further down keeps the colours that matter rather
## than whichever the top-left corner happened to hold.
##
## [b]Alpha is dropped and transparent pixels are skipped.[/b] Keying compares the
## three colour channels and nothing else, so two entries differing only in alpha
## would be one rule written twice; and a pixel that arrived fully transparent is
## already removed and has no colour worth listing.
##
## [b][param remaining] is what the stack has left of the image, and only the pixels it
## still shows as solid are sampled.[/b] The colour itself must come from [param image]
## and not from there — every stage keys against the source pixels, so a colour taken
## from the result would be a rule matching nothing. But which pixels are worth asking
## about is a question only the result can answer.
##
## That matters as soon as anything has been removed. Sweeping a green stem after the
## white plate has gone reads a rectangle that is mostly plate in the source: the
## colours come back white, which is what was already dealt with. Worse are the pixels
## between — a half-removed edge is a [i]blend[/i] of the thing removed and the thing
## kept, and listing a blend as a background colour keys out half-covered pixels
## everywhere in the image rather than any background at all. Solid or nothing.
##
## Pass [code]null[/code] to sample regardless, which is what a run with no result yet
## gets.
##
## No more than [param budget] pixels are read, on an even stride past that. What the
## stride can miss is a colour occupying fewer pixels than the stride is wide, which
## is a colour a tolerance would have had to swallow anyway.
static func colors_in(
		image: Image, region: Rect2i, budget: int, remaining: Image = null) -> PackedColorArray:
	var out := PackedColorArray()
	if image == null or image.is_empty():
		return out
	var frame := Rect2i(0, 0, image.get_width(), image.get_height())
	var box := region.intersection(frame)
	if box.size.x <= 0 or box.size.y <= 0:
		return out

	# Only when it describes this image. A result of another size belongs to another
	# picture, and masking one image by another's alpha would be worse than not masking.
	var masked := remaining != null and not remaining.is_empty() \
			and remaining.get_width() == image.get_width() \
			and remaining.get_height() == image.get_height()

	var step := stride_for(box, budget)
	var xs := stops(box.position.x, box.size.x, step)
	var ys := stops(box.position.y, box.size.y, step)

	# Counted by packed value rather than by Color, so the tally is a Dictionary
	# lookup on an int instead of a scan for something approximately equal.
	var counts := {}
	for y in ys:
		for x in xs:
			if masked and remaining.get_pixel(x, y).a < SOLID_ALPHA:
				continue
			var pixel := image.get_pixel(x, y)
			if pixel.a <= 0.0:
				continue
			var key := Color(pixel.r, pixel.g, pixel.b).to_rgba32()
			counts[key] = int(counts.get(key, 0)) + 1

	var order: Array = counts.keys()
	order.sort_custom(func(a: int, b: int) -> bool: return counts[a] > counts[b])
	for key: int in order:
		out.append(Color.hex(key))
	return out
