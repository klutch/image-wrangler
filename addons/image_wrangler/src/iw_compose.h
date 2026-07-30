#pragma once

// Writes an IWPipelineContext out as an image, once, after every stage has had its say.
//
// Deferred to the end rather than done by whichever stage happens to be last, because
// un-blending and colour bleed both need to read the source colours a stage may have
// decided are only partly there. Doing it early would hand the next stage a result to
// work on instead of the original, and the stack would stop being reorderable.
//
// Alpha comes from the context's coverage times the alpha the source arrived with.
// Colour is the source's, un-blended back out of the background where the fringe
// removal asks for it, replaced by the nearest subject colour where the bleed does, and
// painted over by the stroke last of all.
//
// Never instantiated — IWCompose.compose(ctx) is the whole interface.

#include "iw_pipeline_context.h"

#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>

namespace godot {

class IWCompose : public RefCounted {
	GDCLASS(IWCompose, RefCounted)

protected:
	static void _bind_methods();

public:
	static Ref<Image> compose(const Ref<IWPipelineContext> &ctx);
};

} // namespace godot
