#pragma once

// The parts of a normal map that every mode agrees on.
//
// Three modes work the map out from the pixels and one hands it to a network, but all four
// answer the same questions the same way: what the sheet's bytes are, which rectangle a
// sprite occupies, and what the space between sprites holds. Those live here rather than in
// either file, so the two cannot drift apart on the one guarantee this feature makes — that
// a sprite is worked out inside its own rectangle and nowhere else.

#include "iw_math.h"

#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>

#include <cstdint>

namespace iw {

// Facing straight out. What a pixel holds where nothing tilts it.
inline constexpr uint8_t FLAT_R = 128;
inline constexpr uint8_t FLAT_G = 128;
inline constexpr uint8_t FLAT_B = 255;

// The sheet's pixels as RGBA8, whatever it arrived as.
inline godot::PackedByteArray sheet_bytes(const godot::Ref<godot::Image> &sheet) {
    godot::PackedByteArray pixels = sheet->get_data();
    if (sheet->get_format() != godot::Image::FORMAT_RGBA8) {
        godot::Ref<godot::Image> converted = godot::Image::create_from_data(
                sheet->get_width(), sheet->get_height(), false, sheet->get_format(), pixels);
        converted->convert(godot::Image::FORMAT_RGBA8);
        pixels = converted->get_data();
    }
    return pixels;
}

// A map the size of the sheet, flat everywhere, carrying the sheet's own alpha.
//
// [b]The alpha is copied rather than filled in solid.[/b] It gives the map the same
// silhouette as the sheet, and the dock draws its sprite outlines underneath the image — an
// opaque map would hide them the moment the preview was switched over.
inline godot::PackedByteArray blank_normal(const uint8_t *src, int64_t count) {
    godot::PackedByteArray out;
    out.resize(count * 4);
    uint8_t *dst = out.ptrw();
    for (int64_t i = 0; i < count; i++) {
        dst[i * 4] = FLAT_R;
        dst[i * 4 + 1] = FLAT_G;
        dst[i * 4 + 2] = FLAT_B;
        dst[i * 4 + 3] = src[i * 4 + 3];
    }
    return out;
}

// One sprite's rectangle, clipped to the sheet. False for one of no area, which is what a
// sprite that never got placed leaves behind.
inline bool rect_at(const int32_t *rects, int64_t n, int64_t width, int64_t height,
        int64_t &r_x, int64_t &r_y, int64_t &r_w, int64_t &r_h) {
    r_x = maxi(rects[n], 0);
    r_y = maxi(rects[n + 1], 0);
    const int64_t right = mini(static_cast<int64_t>(rects[n]) + rects[n + 2], width);
    const int64_t bottom = mini(static_cast<int64_t>(rects[n + 1]) + rects[n + 3], height);
    r_w = right - r_x;
    r_h = bottom - r_y;
    return r_w > 0 && r_h > 0;
}

} // namespace iw
