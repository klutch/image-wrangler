#pragma once

// Pixel-buffer maths that more than one operation needs.
//
// Static and stateless on purpose. These are the passes that stopped belonging to any
// one operation the moment the pipeline was split into stages: a box mean is wanted by
// both the guided filter and the automatic stroke colour, and a grassfire expansion by
// both the nearest-subject map and the stroke contour. Leaving a copy in each would
// mean two of everything to keep in step.
//
// Never instantiated — IWPixelMath.box_mean(...) is the whole interface, exactly as it
// was in GDScript.

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>

namespace godot {

class IWPixelMath : public RefCounted {
	GDCLASS(IWPixelMath, RefCounted)

protected:
	static void _bind_methods();

public:
	static PackedFloat32Array box_mean(
			const PackedFloat32Array &source, int64_t width, int64_t height, int64_t radius);

	static PackedInt32Array grassfire(
			const PackedInt32Array &seeds, int64_t width, int64_t height, int64_t radius);
};

} // namespace godot
