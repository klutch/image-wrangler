@tool
class_name IWPixelMath
extends RefCounted

## Pixel-buffer maths that more than one operation needs.
##
## Static and stateless on purpose. These are the passes that stopped belonging to
## any one operation the moment the pipeline was split into stages: a box mean is
## wanted by both the guided filter and the automatic stroke colour, and a
## grassfire expansion by both the nearest-subject map and the stroke contour.
## Leaving a copy in each would mean two of everything to keep in step.
##
## Never instantiated — [code]IWPixelMath.box_mean(...)[/code] is the whole
## interface.


## Mean over a (2r+1)² window, via a summed-area table so the cost is the same
## whatever the radius. The table is accumulated at double precision because a
## large image sums to a magnitude where float32 has stopped counting single
## pixels.
static func box_mean(source: PackedFloat32Array, width: int, height: int, radius: int) -> PackedFloat32Array:
	var stride := width + 1
	var integral := PackedFloat64Array()
	integral.resize(stride * (height + 1))
	for y in height:
		var row_sum := 0.0
		var row := y * width
		var out_row := (y + 1) * stride
		var prev_row := y * stride
		for x in width:
			row_sum += source[row + x]
			integral[out_row + x + 1] = integral[prev_row + x + 1] + row_sum

	var result := PackedFloat32Array()
	result.resize(width * height)
	for y in height:
		var min_y := maxi(y - radius, 0)
		var max_y := mini(y + radius, height - 1) + 1
		var top := min_y * stride
		var bottom := max_y * stride
		var rows := max_y - min_y
		for x in width:
			var min_x := maxi(x - radius, 0)
			var max_x := mini(x + radius, width - 1) + 1
			var total := integral[bottom + max_x] - integral[top + max_x] \
					- integral[bottom + min_x] + integral[top + min_x]
			result[y * width + x] = total / float(rows * (max_x - min_x))
	return result


## For every pixel within [param radius] steps of one of [param seeds], the index
## of the seed that reached it first; -1 for everything further out. A seed maps to
## itself.
##
## One breadth-first pass over the image rather than a windowed search per pixel,
## so the whole map costs what one pixel's search would have.
##
## Each pixel keeps the [i]index of the seed[/i] rather than the number of steps
## taken, which is what lets the caller measure a real Euclidean span back to it.
## Counting steps instead would give a Manhattan distance, and anything drawn from
## one comes out visibly diamond-shaped on a curve.
##
## 4-connected, matching every other flood here, and first arrival wins — with a
## FIFO queue that is also the fewest steps, though not necessarily the nearest
## seed by span. The error is sub-pixel and the alternative is a priority queue per
## pixel.
##
## [param seeds] is consumed in the order given, so a caller that builds it in
## index order gets a deterministic map.
static func grassfire(seeds: PackedInt32Array, width: int, height: int, radius: int) -> PackedInt32Array:
	var pixel_count := width * height
	var source := PackedInt32Array()
	source.resize(pixel_count)
	source.fill(-1)
	if seeds.is_empty():
		return source

	var steps := PackedInt32Array()
	steps.resize(pixel_count)
	# Each pixel is claimed at most once, so the queue can be sized up front and
	# used as a plain FIFO with no wraparound.
	var queue := PackedInt32Array()
	queue.resize(pixel_count)
	var head := 0
	var tail := 0
	for seed in seeds:
		source[seed] = seed
		queue[tail] = seed
		tail += 1

	while head < tail:
		var index := queue[head]
		head += 1
		var step := steps[index] + 1
		if step > radius:
			continue
		var from := source[index]
		var x := index % width
		@warning_ignore("integer_division")
		var y := index / width
		if x > 0:
			var left := index - 1
			if source[left] == -1:
				source[left] = from
				steps[left] = step
				queue[tail] = left
				tail += 1
		if x < width - 1:
			var right := index + 1
			if source[right] == -1:
				source[right] = from
				steps[right] = step
				queue[tail] = right
				tail += 1
		if y > 0:
			var up := index - width
			if source[up] == -1:
				source[up] = from
				steps[up] = step
				queue[tail] = up
				tail += 1
		if y < height - 1:
			var down := index + width
			if source[down] == -1:
				source[down] = from
				steps[down] = step
				queue[tail] = down
				tail += 1

	return source
