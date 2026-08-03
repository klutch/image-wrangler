// The Denoise stage's one call, on Intel Open Image Denoise.
//
// Its own translation unit because it is the only file in the extension that includes a
// third-party header, and because the C API is deliberately the one it includes.
// godot-cpp builds this with disable_exceptions, which means _HAS_EXCEPTIONS=0 and no
// /EHsc: OpenImageDenoise/oidn.hpp throws and will not compile under that. oidn.h is
// plain C and pulls in nothing but <stdint.h> and <stddef.h>. Do not "upgrade" it.
//
// The vendored runtime, the DLL layout and the CRT question are in
// thirdparty/oidn/README-vendored.md.

#include "iw_stage_kernels.h"

#include "iw_math.h"

#include <godot_cpp/core/error_macros.hpp>

#include <OpenImageDenoise/oidn.h>

#include <string>
#include <vector>

#ifdef _WIN32
// NOMINMAX is already on the command line, so only this one is set here.
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#endif

using namespace godot;

namespace {

// Whether the Open Image Denoise runtime is loaded, loading it if it is merely on disk.
//
// [b]Nothing here may call an oidn* function before this has said yes.[/b] The DLL is
// delay-loaded — see SConstruct — so the first call is what would fetch it, and the
// delay-load helper reports a failure by raising a structured exception. This extension is
// built with exceptions disabled, so that would take the editor down rather than return.
//
// Loaded by full path rather than by name. Godot resolves the extension's own imports
// against the folder it loaded it from, but a plain LoadLibrary later searches from the
// running executable instead, which is Godot's folder and not this addon's.
// LOAD_WITH_ALTERED_SEARCH_PATH is then what lets OpenImageDenoise_core.dll resolve as a
// sibling. Once it is in, the delay-load helper finds it already loaded under that name and
// reuses it.
//
// Asked again each time rather than remembered, so that a runtime downloaded into bin/ works
// without restarting the editor. Costs a module-table lookup once it is there.
bool oidn_runtime_loaded() {
#ifdef _WIN32
	if (GetModuleHandleW(L"OpenImageDenoise.dll") != nullptr) {
		return true;
	}
	HMODULE self = nullptr;
	if (GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
							   GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
				reinterpret_cast<LPCWSTR>(&oidn_runtime_loaded), &self) == 0) {
		return false;
	}
	wchar_t buffer[MAX_PATH];
	const DWORD length = GetModuleFileNameW(self, buffer, MAX_PATH);
	if (length == 0 || length >= MAX_PATH) {
		return false;
	}
	std::wstring path(buffer, length);
	const size_t slash = path.find_last_of(L'\\');
	if (slash == std::wstring::npos) {
		return false;
	}
	path.replace(slash + 1, std::wstring::npos, L"OpenImageDenoise.dll");
	return LoadLibraryExW(path.c_str(), nullptr, LOAD_WITH_ALTERED_SEARCH_PATH) != nullptr;
#else
	return true;
#endif
}

// Released on every path out, including the early ones, so that no return has to
// remember two of them.
struct DeviceHandle {
	OIDNDevice device = nullptr;

	~DeviceHandle() {
		if (device != nullptr) {
			oidnReleaseDevice(device);
		}
	}
};

struct FilterHandle {
	OIDNFilter filter = nullptr;

	~FilterHandle() {
		if (filter != nullptr) {
			oidnReleaseFilter(filter);
		}
	}
};

// Whatever OIDN last complained about, or empty.
//
// Reading it also clears it, which is why it is asked after each committed step rather
// than once at the end: the first failure is the one worth reporting, and a later call
// would otherwise hand back a message about something that failed because of it.
String device_error(OIDNDevice device) {
	const char *message = nullptr;
	if (oidnGetDeviceError(device, &message) == OIDN_ERROR_NONE) {
		return String();
	}
	return message != nullptr ? String(message) : String("unknown error");
}

// DenoiseSettings.Quality onto OIDN's own, which are 4, 5 and 6 rather than 0, 1 and 2.
//
// Mapped by hand rather than cast, so that a renumbering on either side is a
// compile-time edit here instead of a silently different filter. The default arm is not
// decoration: SettingType.ENUM is not one of the kinds clamp_settings_to_schema clamps,
// so a hand-edited sidecar can deliver anything at all.
OIDNQuality quality_for(int64_t index) {
	switch (index) {
		case 0:
			return OIDN_QUALITY_FAST;
		case 1:
			return OIDN_QUALITY_BALANCED;
		case 2:
			return OIDN_QUALITY_HIGH;
		default:
			return OIDN_QUALITY_HIGH;
	}
}

} // namespace

bool IWStageKernels::denoise_available() {
	return oidn_runtime_loaded();
}

bool IWStageKernels::denoise(const Ref<IWPipelineContext> &ctx, int64_t quality, double blend) {
	ERR_FAIL_COND_V(ctx.is_null(), false);
	// The backstop. The stage asks denoise_available() and stands down long before this,
	// so reaching it means something called the kernel directly.
	ERR_FAIL_COND_V_MSG(!oidn_runtime_loaded(), false,
			"Image Wrangler: the Open Image Denoise runtime is not in "
			"addons/image_wrangler/bin/. Use Download Runtime on the Denoise stage.");

	const int64_t pixel_count = ctx->pixel_count;
	const int64_t width = ctx->width;
	const int64_t height = ctx->height;
	if (pixel_count <= 0 || width <= 0 || height <= 0) {
		return false;
	}
	ERR_FAIL_COND_V(ctx->data.size() < pixel_count * 4, false);

	// Three floats a pixel in and three out. OIDN will not read bytes and cannot filter
	// in place, so neither buffer is avoidable — at four thousand square that is two
	// lots of 192 MiB, which is worth knowing here rather than in a bug report.
	std::vector<float> in(static_cast<size_t>(pixel_count) * 3);
	std::vector<float> out(static_cast<size_t>(pixel_count) * 3);

	const uint8_t *src = ctx->data.ptr();
	const double to_unit = 1.0 / 255.0;
	for (int64_t i = 0; i < pixel_count; i++) {
		const int64_t s = i * 4;
		const size_t d = static_cast<size_t>(i) * 3;
		// Straight through, with no transfer function applied: the filter is told below
		// that these are sRGB-encoded and returns them the same way, so converting here
		// as well would be doing it twice.
		in[d] = iw::narrow(src[s] * to_unit);
		in[d + 1] = iw::narrow(src[s + 1] * to_unit);
		in[d + 2] = iw::narrow(src[s + 2] * to_unit);
	}

	DeviceHandle dev;
	// CPU by name rather than OIDN_DEVICE_TYPE_DEFAULT, which probes for CUDA, HIP and
	// SYCL modules. Only the CPU device is vendored, so DEFAULT would spend the probe
	// and land here anyway — and would start finding GPUs the moment anyone dropped the
	// other device DLLs in beside it, which is not a thing to discover by accident.
	dev.device = oidnNewDevice(OIDN_DEVICE_TYPE_CPU);
	ERR_FAIL_NULL_V_MSG(dev.device, false,
			"Image Wrangler: could not create an Open Image Denoise device. Check that "
			"OpenImageDenoise_core.dll and OpenImageDenoise_device_cpu.dll sit beside "
			"image_wrangler.dll in addons/image_wrangler/bin/.");

	// The editor already owns this process's threads, and this usually runs on the
	// preview worker. Letting OIDN pin its own would have the two fighting over the
	// same cores.
	oidnSetDeviceBool(dev.device, "setAffinity", false);
	oidnCommitDevice(dev.device);
	String problem = device_error(dev.device);
	if (!problem.is_empty()) {
		ERR_FAIL_V_MSG(false, "Image Wrangler: Open Image Denoise device: " + problem);
	}

	FilterHandle flt;
	flt.filter = oidnNewFilter(dev.device, "RT");
	ERR_FAIL_NULL_V_MSG(flt.filter, false,
			"Image Wrangler: Open Image Denoise has no RT filter.");

	oidnSetSharedFilterImage(flt.filter, "color", in.data(), OIDN_FORMAT_FLOAT3,
			static_cast<size_t>(width), static_cast<size_t>(height), 0, 0, 0);
	oidnSetSharedFilterImage(flt.filter, "output", out.data(), OIDN_FORMAT_FLOAT3,
			static_cast<size_t>(width), static_cast<size_t>(height), 0, 0, 0);
	// Eight bits a channel is low dynamic range by construction, and the bytes in a PNG
	// carry the sRGB curve rather than light. Saying both is what stops the filter
	// reading a mid-grey as the fifth of the energy it would be if linear.
	oidnSetFilterBool(flt.filter, "hdr", false);
	oidnSetFilterBool(flt.filter, "srgb", true);
	oidnSetFilterInt(flt.filter, "quality", quality_for(quality));
	oidnCommitFilter(flt.filter);
	problem = device_error(dev.device);
	if (!problem.is_empty()) {
		ERR_FAIL_V_MSG(false, "Image Wrangler: Open Image Denoise filter: " + problem);
	}

	// Uninterruptible, and nothing here pretends otherwise. OIDN's progress monitor
	// fires from its own threads, where calling into a Callable is not safe, and the
	// thread that would set a flag for it is this one — which is inside the call. Same
	// bargain every other single-pass stage makes.
	oidnExecuteFilter(flt.filter);
	problem = device_error(dev.device);
	if (!problem.is_empty()) {
		ERR_FAIL_V_MSG(false, "Image Wrangler: Open Image Denoise: " + problem);
	}

	// A copy taken from the context and written through, rather than ctx->data.ptrw():
	// src above is still pointing into the original, and ptrw() on an array the context
	// also holds would copy anyway. This way the copy is where it can be seen.
	PackedByteArray result = ctx->data;
	uint8_t *dst = result.ptrw();
	const double amount = iw::clampf(blend, 0.0, 1.0);
	for (int64_t i = 0; i < pixel_count; i++) {
		const int64_t s = i * 4;
		const size_t d = static_cast<size_t>(i) * 3;
		for (int64_t c = 0; c < 3; c++) {
			// The original is read from the bytes rather than from `in`, so that a blend
			// of zero is the identity to the last bit instead of a round trip through
			// float32 that happens to land back where it started nearly every time.
			const double was = src[s + c] * to_unit;
			const double now = iw::widen(out[d + static_cast<size_t>(c)]);
			const double mixed = iw::lerpf(was, now, amount);
			dst[s + c] = static_cast<uint8_t>(iw::roundi(iw::clampf(mixed, 0.0, 1.0) * 255.0));
		}
		// Alpha is untouched, and untouched by omission rather than by being copied
		// back: it is already in `result`, which started as the whole of ctx->data.
	}

	ctx->data = result;
	return true;
}
