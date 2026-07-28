#include "iw_pixel_math.h"

#include "iw_math.h"

#include <vector>

using namespace godot;

void IWPixelMath::_bind_methods() {
	ClassDB::bind_static_method("IWPixelMath",
			D_METHOD("box_mean", "source", "width", "height", "radius"),
			&IWPixelMath::box_mean);
	ClassDB::bind_static_method("IWPixelMath",
			D_METHOD("grassfire", "seeds", "width", "height", "radius"),
			&IWPixelMath::grassfire);
}

// Mean over a (2r+1)² window, via a summed-area table so the cost is the same whatever
// the radius.
//
// The table is accumulated at double precision because a large image sums to a
// magnitude where float32 has stopped counting single pixels. That is not a detail: at
// a running total near 3.5e8 the gap between representable float32s is 32, so a table
// kept in float32 loses whole pixels and every mean downstream of it is wrong by an
// amount that varies across the image. The parity harness probes this directly.
PackedFloat32Array IWPixelMath::box_mean(
		const PackedFloat32Array &source, int64_t width, int64_t height, int64_t radius) {
	PackedFloat32Array result;
	if (width <= 0 || height <= 0) {
		return result;
	}

	const int64_t stride = width + 1;
	// Zero-filled, and the zeros matter: row 0 and column 0 of the table are the
	// out-of-bounds edge every window subtraction leans on.
	std::vector<double> integral(static_cast<size_t>(stride * (height + 1)), 0.0);
	const float *src = source.ptr();

	for (int64_t y = 0; y < height; y++) {
		double row_sum = 0.0;
		const int64_t row = y * width;
		const int64_t out_row = (y + 1) * stride;
		const int64_t prev_row = y * stride;
		for (int64_t x = 0; x < width; x++) {
			// Promoted to double on the way in, as reading a PackedFloat32Array in
			// GDScript does.
			row_sum += iw::widen(src[row + x]);
			integral[out_row + x + 1] = integral[prev_row + x + 1] + row_sum;
		}
	}

	result.resize(width * height);
	float *dst = result.ptrw();
	for (int64_t y = 0; y < height; y++) {
		const int64_t min_y = iw::maxi(y - radius, 0);
		const int64_t max_y = iw::mini(y + radius, height - 1) + 1;
		const int64_t top = min_y * stride;
		const int64_t bottom = max_y * stride;
		const int64_t rows = max_y - min_y;
		for (int64_t x = 0; x < width; x++) {
			const int64_t min_x = iw::maxi(x - radius, 0);
			const int64_t max_x = iw::mini(x + radius, width - 1) + 1;
			// Left to right, in this order. Subtraction does not associate in floating
			// point, so grouping these differently — even in a way that looks tidier —
			// gives different last bits.
			const double total = integral[bottom + max_x] - integral[top + max_x]
					- integral[bottom + min_x] + integral[top + min_x];
			// Narrowed on the way out, as storing into a PackedFloat32Array does.
			dst[y * width + x] = iw::narrow(total / static_cast<double>(rows * (max_x - min_x)));
		}
	}
	return result;
}

// For every pixel within radius steps of one of the seeds, the index of the seed that
// reached it first; -1 for everything further out. A seed maps to itself.
//
// One breadth-first pass over the image rather than a windowed search per pixel, so the
// whole map costs what one pixel's search would have.
//
// Each pixel keeps the *index of the seed* rather than the number of steps taken, which
// is what lets the caller measure a real Euclidean span back to it. Counting steps
// instead would give a Manhattan distance, and anything drawn from one comes out
// visibly diamond-shaped on a curve.
//
// 4-connected, matching every other flood here, and first arrival wins. The neighbour
// order — left, right, up, down — is load-bearing: it decides which seed claims a pixel
// two could reach in the same number of steps, and reordering it changes the output.
PackedInt32Array IWPixelMath::grassfire(
		const PackedInt32Array &seeds, int64_t width, int64_t height, int64_t radius) {
	const int64_t pixel_count = width * height;
	PackedInt32Array source;
	if (pixel_count <= 0) {
		return source;
	}
	source.resize(pixel_count);
	source.fill(-1);
	if (seeds.is_empty()) {
		return source;
	}

	std::vector<int32_t> steps(static_cast<size_t>(pixel_count), 0);
	// Each pixel is claimed at most once, so the queue can be sized up front and used
	// as a plain FIFO with no wraparound. Sized for the seed list as well: a caller
	// that passed the same seed twice would push it twice, which changes nothing about
	// the result — the second pop finds every neighbour already claimed — but would run
	// off the end of a queue sized for the image alone.
	std::vector<int32_t> queue(static_cast<size_t>(pixel_count + seeds.size()), 0);
	int32_t *out = source.ptrw();
	const int32_t *seed_ptr = seeds.ptr();

	int64_t head = 0;
	int64_t tail = 0;
	for (int64_t i = 0; i < seeds.size(); i++) {
		const int32_t seed = seed_ptr[i];
		// GDScript would raise on an out-of-range index; here it would corrupt memory.
		// Skipped instead, which can only differ from the reference on input the
		// reference refused to run at all.
		if (seed < 0 || seed >= pixel_count) {
			continue;
		}
		out[seed] = seed;
		queue[tail++] = seed;
	}

	while (head < tail) {
		const int32_t index = queue[head++];
		const int32_t step = steps[index] + 1;
		if (step > radius) {
			continue;
		}
		const int32_t from = out[index];
		const int64_t x = index % width;
		const int64_t y = index / width;
		if (x > 0) {
			const int32_t left = index - 1;
			if (out[left] == -1) {
				out[left] = from;
				steps[left] = step;
				queue[tail++] = left;
			}
		}
		if (x < width - 1) {
			const int32_t right = index + 1;
			if (out[right] == -1) {
				out[right] = from;
				steps[right] = step;
				queue[tail++] = right;
			}
		}
		if (y > 0) {
			const int32_t up = index - static_cast<int32_t>(width);
			if (out[up] == -1) {
				out[up] = from;
				steps[up] = step;
				queue[tail++] = up;
			}
		}
		if (y < height - 1) {
			const int32_t down = index + static_cast<int32_t>(width);
			if (out[down] == -1) {
				out[down] = from;
				steps[down] = step;
				queue[tail++] = down;
			}
		}
	}
	return source;
}
