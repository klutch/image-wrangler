#pragma once

// The scalar compatibility rules in iw_math.h, exposed to GDScript.
//
// Its only caller is tests/iw_parity.gd, which runs each of these over the awkward
// inputs — halves, negative zero, the double just below 0.5 — and compares against
// what GDScript's own operators returned on the same run. That is what turns iw_math.h
// from a comment claiming these match into something that fails a gate when they stop.
//
// Kept as its own class rather than folded into a working one so that nothing in the
// pipeline can start depending on a test surface.

#include "iw_math.h"

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>

namespace godot {

class IWMathCompat : public RefCounted {
	GDCLASS(IWMathCompat, RefCounted)

protected:
	static void _bind_methods();

public:
	int64_t roundi(double value) const;
	double clampf(double value, double lo, double hi) const;
	double lerpf(double from, double to, double weight) const;
	// Round trip through float32, which is what every PackedFloat32Array store does.
	double narrow(double value) const;
};

} // namespace godot
