#include "register_types.h"

#include "iw_compose.h"
#include "iw_math_compat.h"
#include "iw_pipeline_context.h"
#include "iw_pixel_math.h"
#include "iw_stage_kernels.h"

#include <gdextension_interface.h>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

using namespace godot;

// SCENE rather than CORE: these are ordinary classes the addon instantiates, not
// engine-level services, and registering them any earlier buys nothing. The editor
// plugin that uses them is loaded well after this.
void initialize_image_wrangler(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
	GDREGISTER_CLASS(IWMathCompat);
	GDREGISTER_CLASS(IWPixelMath);
	GDREGISTER_CLASS(IWCompose);
	GDREGISTER_CLASS(IWPipelineContext);
	GDREGISTER_CLASS(IWStageKernels);
}

void uninitialize_image_wrangler(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
}

extern "C" {
GDExtensionBool GDE_EXPORT image_wrangler_library_init(
		GDExtensionInterfaceGetProcAddress p_get_proc_address,
		const GDExtensionClassLibraryPtr p_library,
		GDExtensionInitialization *r_initialization) {
	GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);

	init_obj.register_initializer(initialize_image_wrangler);
	init_obj.register_terminator(uninitialize_image_wrangler);
	init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);

	return init_obj.init();
}
}
