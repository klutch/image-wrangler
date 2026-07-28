#pragma once

// Scalar arithmetic with GDScript's semantics, exactly.
//
// The port's contract is that the bytes coming out do not change, and most of the ways
// that can quietly fail are in here rather than in any algorithm. GDScript's `float` is
// a double, its `roundi` rounds half away from zero where C++'s `nearbyint` rounds half
// to even, and its `lerpf` is defined as `a + (b - a) * w`, which is not the same
// double as `(1 - w) * a + w * b`. None of those differences are visible in a preview.
// All of them are permanent.
//
// So every ported line uses these instead of the raw operators, and the rule lives in
// one place where it can be read and checked rather than being re-derived at each call
// site. `IWMathCompat` exposes them to the parity harness for exactly that reason.

#include <cmath>
#include <cstdint>

namespace iw {

// Godot's roundi, which is NOT std::round.
//
// Godot rounds by adding a half and flooring, mirrored about zero for negatives. That
// agrees with std::round on every exact half — round(2.5) == 3, round(-2.5) == -3,
// where std::rint would give the even neighbour — but it disagrees just below one:
//
//     x = 0.49999999999999994          the largest double under a half
//     std::round(x)              -> 0  correct to the value
//     floor(x + 0.5)             -> 1  because x + 0.5 rounds up to exactly 1.0
//
// GDScript answers 1, so this answers 1. Measured rather than assumed: the parity
// harness caught it on the first native function it checked, which is the entire
// reason that harness was written before any of this code.
inline int64_t roundi(double value) {
	const double rounded = value >= 0.0
			? std::floor(value + 0.5)
			: -std::floor(-value + 0.5);
	return static_cast<int64_t>(rounded);
}

// Godot's CLAMP, which is a pair of comparisons in this order and nothing cleverer.
// Note what that means when the bounds are crossed: clampf(0.5, 1.0, 0.0) returns 1.0,
// because the lower bound is tested first. std::clamp is undefined for that input.
inline double clampf(double value, double lo, double hi) {
	return value < lo ? lo : (value > hi ? hi : value);
}

// Godot's Math::lerp. Written in this exact form on purpose; the algebraically equal
// (1 - w) * a + w * b differs in the last bit for most inputs.
inline double lerpf(double from, double to, double weight) {
	return from + (to - from) * weight;
}

// Godot's MAX/MIN: a plain comparison, not std::fmax/fmin. They part company on NaN,
// which nothing here should produce but everything here would propagate.
inline double maxf(double a, double b) {
	return a > b ? a : b;
}

inline double minf(double a, double b) {
	return a < b ? a : b;
}

inline int64_t maxi(int64_t a, int64_t b) {
	return a > b ? a : b;
}

inline int64_t mini(int64_t a, int64_t b) {
	return a < b ? a : b;
}

inline double absf(double value) {
	return std::fabs(value);
}

// Godot's ceili/floori: the real ceil or floor, then truncated to an integer. Unlike
// roundi (see above) these two are exactly what the C library does.
inline int64_t ceili(double value) {
	return static_cast<int64_t>(std::ceil(value));
}

inline int64_t floori(double value) {
	return static_cast<int64_t>(std::floor(value));
}

// The narrowing a PackedFloat32Array store performs, made explicit.
//
// Reading an element of one in GDScript promotes float32 to double; writing narrows
// back, round-to-nearest-even. Any ported pass that keeps a value in double across a
// point where the GDScript rounded it through float32 will drift, and drift silently,
// because it is more accurate rather than less. Where the reference stored, store.
inline float narrow(double value) {
	return static_cast<float>(value);
}

// The promotion on the way back out, spelled out so the intent is visible at the call
// site rather than left to implicit conversion.
inline double widen(float value) {
	return static_cast<double>(value);
}

} // namespace iw
