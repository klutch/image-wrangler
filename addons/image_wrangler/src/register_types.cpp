#include "register_types.h"

#include "iw_compose.h"
#include "iw_math_compat.h"
#include "iw_pipeline_context.h"
#include "iw_pixel_math.h"
#include "iw_stage_kernels.h"

// The two upscalers are left out of a build that has not had ncnn made for it, which is the
// ordinary state of a fresh checkout — see tools/build_ncnn.py. SConstruct defines this
// when it has one to link against, and the Upscale tab tests for the classes at runtime.
#ifdef IW_HAVE_NCNN
#include "iw_ncnn_instance.h"
#include "iw_realesrgan.h"
#include "iw_waifu2x.h"
#endif

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
#ifdef IW_HAVE_NCNN
    GDREGISTER_CLASS(IWWaifu2x);
    GDREGISTER_CLASS(IWRealESRGAN);
#endif
}

void uninitialize_image_wrangler(ModuleInitializationLevel p_level) {
    if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
        return;
    }
#ifdef IW_HAVE_NCNN
    // The one thing here that is process-wide: the Vulkan instance both upscalers run on.
    // Everything else is either a static kernel or a Resource the engine is already taking
    // apart.
    iw_ncnn::shutdown();
#endif
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
