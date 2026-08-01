#include "iw_islands.h"
#include "iw_math.h"
#include "iw_normal_shared.h"
#include "iw_pixel_math.h"
#include "iw_stage_kernels.h"

#include <godot_cpp/classes/image.hpp>

#include <cmath>
#include <cstring>
#include <vector>

using namespace godot;

namespace {

using iw::blank_normal;
using iw::rect_at;
using iw::sheet_bytes;

// How far the surface has risen `t` of the way in from the outline, 0 to 1 in both.
double curve_height(int64_t curve, double t) {
    const double along = iw::clampf(t, 0.0, 1.0);
    switch (curve) {
        case 1: { // Soft: eased at both ends, so the rounding starts without a crease.
            return along * along * (3.0 - 2.0 * along);
        }
        case 2: { // Straight: one slope all the way, a flat chamfer.
            return along;
        }
        case 3: { // Hollow: gentle at the rim and steepening inwards.
            return along * along;
        }
        default: { // Round: a quarter circle, steep at the rim and flat in the middle.
            const double from_rim = 1.0 - along;
            return std::sqrt(iw::maxf(1.0 - from_rim * from_rim, 0.0));
        }
    }
}

// A slope written as a colour.
//
// [param dhdy] is the change going [i]down[/i], because image y runs down. With
// [param green_down] off, the top rim of a rise comes out light green and the bottom rim
// dark, which is the way round Godot reads it; on, the green channel is flipped for the
// engines that read it the other way. Red is the same in both.
void pack_normal(double dhdx, double dhdy, bool green_down, uint8_t *out) {
    const double nx = -dhdx;
    const double ny = green_down ? -dhdy : dhdy;
    const double length = std::sqrt(nx * nx + ny * ny + 1.0);
    out[0] = static_cast<uint8_t>(
            iw::roundi(iw::clampf(nx / length * 0.5 + 0.5, 0.0, 1.0) * 255.0));
    out[1] = static_cast<uint8_t>(
            iw::roundi(iw::clampf(ny / length * 0.5 + 0.5, 0.0, 1.0) * 255.0));
    out[2] = static_cast<uint8_t>(
            iw::roundi(iw::clampf(1.0 / length * 0.5 + 0.5, 0.0, 1.0) * 255.0));
}

// Scharr, which is Sobel with the weights that keep a diagonal edge pointing where it
// really points. Which way a surface faces is the whole of what a normal map holds, so
// that is worth the same eight reads Sobel costs.
void scharr_at(const float *field, int64_t at, int64_t stride, double &r_gx, double &r_gy) {
    const double a00 = iw::widen(field[at - stride - 1]);
    const double a01 = iw::widen(field[at - stride]);
    const double a02 = iw::widen(field[at - stride + 1]);
    const double a10 = iw::widen(field[at - 1]);
    const double a12 = iw::widen(field[at + 1]);
    const double a20 = iw::widen(field[at + stride - 1]);
    const double a21 = iw::widen(field[at + stride]);
    const double a22 = iw::widen(field[at + stride + 1]);
    r_gx = (3.0 * (a02 - a00) + 10.0 * (a12 - a10) + 3.0 * (a22 - a20)) / 32.0;
    r_gy = (3.0 * (a20 - a00) + 10.0 * (a21 - a01) + 3.0 * (a22 - a02)) / 32.0;
}

// The smallest z a packed normal is read back with.
//
// The slope is z divided into x and y, so a pixel that has been written facing all the way
// over is a division by nothing. Nothing this addon generates gets there, but a map loaded
// from somewhere else can.
constexpr double MIN_Z = 0.001;

// A packed normal read back out as a direction.
void unpack_normal(const uint8_t *px, double &r_x, double &r_y, double &r_z) {
    r_x = px[0] / 255.0 * 2.0 - 1.0;
    r_y = px[1] / 255.0 * 2.0 - 1.0;
    r_z = iw::maxf(px[2] / 255.0 * 2.0 - 1.0, MIN_Z);
}

// A direction written back as a colour, renormalised on the way. Alpha is left alone.
void pack_direction(double x, double y, double z, uint8_t *out) {
    const double length = iw::maxf(std::sqrt(x * x + y * y + z * z), MIN_Z);
    out[0] = static_cast<uint8_t>(
            iw::roundi(iw::clampf(x / length * 0.5 + 0.5, 0.0, 1.0) * 255.0));
    out[1] = static_cast<uint8_t>(
            iw::roundi(iw::clampf(y / length * 0.5 + 0.5, 0.0, 1.0) * 255.0));
    out[2] = static_cast<uint8_t>(
            iw::roundi(iw::clampf(z / length * 0.5 + 0.5, 0.0, 1.0) * 255.0));
}

// The largest of the three channel differences, each 0 to 1.
//
// The largest rather than the sum, so three differences too small to see cannot add up to
// an edge between them.
double color_gap(const uint8_t *a, const uint8_t *b) {
    const double red = iw::absf(static_cast<double>(a[0]) - b[0]);
    const double green = iw::absf(static_cast<double>(a[1]) - b[1]);
    const double blue = iw::absf(static_cast<double>(a[2]) - b[2]);
    return iw::maxf(red, iw::maxf(green, blue)) / 255.0;
}

} // namespace

// The margin every sprite is worked out inside. One clear pixel all round the rectangle,
// which is what lets a sprite filling its whole rectangle still get a rounded rim — and is
// also the clamp, since nothing outside the rectangle is ever read.
static constexpr int64_t MARGIN = 1;

Ref<Image> IWStageKernels::normal_from_shape(
        const Ref<Image> &sheet,
        const PackedInt32Array &rects,
        int64_t roll_off,
        int64_t curve,
        double strength,
        double color_tolerance,
        bool green_down) {
    ERR_FAIL_COND_V(sheet.is_null(), Ref<Image>());
    if (sheet->is_empty() || rects.is_empty()) {
        return Ref<Image>();
    }

    const int64_t width = sheet->get_width();
    const int64_t height = sheet->get_height();
    const int64_t reach = iw::maxi(roll_off, 1);
    const bool reads_color = color_tolerance >= 0.0;

    const PackedByteArray pixels = sheet_bytes(sheet);
    const uint8_t *src = pixels.ptr();
    PackedByteArray out = blank_normal(src, width * height);
    uint8_t *dst = out.ptrw();

    const int32_t *rect_ptr = rects.ptr();
    for (int64_t n = 0; n + 3 < rects.size(); n += 4) {
        int64_t rx = 0;
        int64_t ry = 0;
        int64_t rw = 0;
        int64_t rh = 0;
        if (!rect_at(rect_ptr, n, width, height, rx, ry, rw, rh)) {
            continue;
        }

        const int64_t lw = rw + MARGIN * 2;
        const int64_t lh = rh + MARGIN * 2;
        const int64_t lcount = lw * lh;

        // Solid is alpha at or above a half, the same half the packer cut these islands at,
        // so the rounding follows exactly the silhouette that was lifted out.
        std::vector<uint8_t> solid(static_cast<size_t>(lcount), 0);
        for (int64_t y = 0; y < rh; y++) {
            const int64_t row = (ry + y) * width + rx;
            const int64_t local = (y + MARGIN) * lw + MARGIN;
            for (int64_t x = 0; x < rw; x++) {
                const double alpha = src[(row + x) * 4 + 3] / 255.0;
                solid[static_cast<size_t>(local + x)] = alpha >= iw::SOLID_ALPHA ? 1 : 0;
            }
        }

        // Every pixel the rounding falls away to. The margin is in here too, which is what
        // seeds the outline itself.
        std::vector<int32_t> found;
        found.reserve(static_cast<size_t>(lcount));
        for (int64_t i = 0; i < lcount; i++) {
            if (!solid[static_cast<size_t>(i)]) {
                found.push_back(static_cast<int32_t>(i));
            }
        }

        // Color Regions adds the boundaries inside the sprite, so each flat area of colour
        // rises from its own outline instead of the whole sprite lifting as one lump.
        //
        // These sit on the boundary pixel where the silhouette's seeds sit outside it, so an
        // interior line reads a touch sharper than the outline does — which is the right way
        // round for art drawn as shapes with lines between them.
        if (reads_color) {
            for (int64_t y = 0; y < rh; y++) {
                const int64_t row = (ry + y) * width + rx;
                const int64_t local = (y + MARGIN) * lw + MARGIN;
                for (int64_t x = 0; x < rw; x++) {
                    if (!solid[static_cast<size_t>(local + x)]) {
                        continue;
                    }
                    const uint8_t *here = src + (row + x) * 4;
                    bool parts = false;
                    if (x > 0 && solid[static_cast<size_t>(local + x - 1)]) {
                        parts = color_gap(here, src + (row + x - 1) * 4) > color_tolerance;
                    }
                    if (!parts && x + 1 < rw && solid[static_cast<size_t>(local + x + 1)]) {
                        parts = color_gap(here, src + (row + x + 1) * 4) > color_tolerance;
                    }
                    if (!parts && y > 0 && solid[static_cast<size_t>(local + x - lw)]) {
                        parts = color_gap(here, src + (row + x - width) * 4) > color_tolerance;
                    }
                    if (!parts && y + 1 < rh && solid[static_cast<size_t>(local + x + lw)]) {
                        parts = color_gap(here, src + (row + x + width) * 4) > color_tolerance;
                    }
                    if (parts) {
                        found.push_back(static_cast<int32_t>(local + x));
                    }
                }
            }
        }

        PackedInt32Array seeds;
        seeds.resize(static_cast<int64_t>(found.size()));
        if (!found.empty()) {
            memcpy(seeds.ptrw(), found.data(), found.size() * sizeof(int32_t));
        }
        const PackedInt32Array nearest = IWPixelMath::grassfire(seeds, lw, lh, reach);
        const int32_t *near_ptr = nearest.ptr();

        // How high each pixel has risen, in pixels, so the strength reads as a slope rather
        // than as a number whose meaning changes with the roll-off distance.
        PackedFloat32Array raised;
        raised.resize(lcount);
        float *raise = raised.ptrw();
        for (int64_t i = 0; i < lcount; i++) {
            if (!solid[static_cast<size_t>(i)]) {
                raise[i] = 0.0f;
                continue;
            }
            // Straight-line distance back to the seed rather than a count of steps taken to
            // reach it. A step count is the same in every direction and would bevel every
            // sprite into a diamond; the nearest seed is what grassfire returns for this.
            double distance = static_cast<double>(reach);
            const int32_t seed = near_ptr[i];
            if (seed >= 0) {
                const int64_t dx = (i % lw) - (seed % lw);
                const int64_t dy = (i / lw) - (seed / lw);
                distance = std::sqrt(static_cast<double>(dx * dx + dy * dy));
            }
            raise[i] = iw::narrow(
                    strength * reach * curve_height(curve, distance / static_cast<double>(reach)));
        }

        // One pixel of mean. The distance comes back in whole steps and shows facets along a
        // diagonal; a summed-area mean this small takes them out for nothing, and softens the
        // crease where two colour regions meet.
        const PackedFloat32Array smoothed = IWPixelMath::box_mean(raised, lw, lh, 1);
        const float *risen = smoothed.ptr();

        for (int64_t y = 0; y < rh; y++) {
            const int64_t row = (ry + y) * width + rx;
            const int64_t local = (y + MARGIN) * lw + MARGIN;
            for (int64_t x = 0; x < rw; x++) {
                // Anything the sheet shows at all, so an antialiased rim takes the tilt of
                // what it edges rather than a flat patch. Clear pixels are left as they were.
                if (src[(row + x) * 4 + 3] == 0) {
                    continue;
                }
                const int64_t at = local + x;
                const double dhdx = (iw::widen(risen[at + 1]) - iw::widen(risen[at - 1])) * 0.5;
                const double dhdy = (iw::widen(risen[at + lw]) - iw::widen(risen[at - lw])) * 0.5;
                pack_normal(dhdx, dhdy, green_down, dst + (row + x) * 4);
            }
        }
    }

    return Image::create_from_data(width, height, false, Image::FORMAT_RGBA8, out);
}

Ref<Image> IWStageKernels::normal_from_brightness(
        const Ref<Image> &sheet,
        const PackedInt32Array &rects,
        int64_t coarse_size,
        double coarse_strength,
        double fine_strength,
        bool green_down) {
    ERR_FAIL_COND_V(sheet.is_null(), Ref<Image>());
    if (sheet->is_empty() || rects.is_empty()) {
        return Ref<Image>();
    }

    const int64_t width = sheet->get_width();
    const int64_t height = sheet->get_height();
    const bool wants_coarse = coarse_strength > 0.0;
    const bool wants_fine = fine_strength > 0.0;

    const PackedByteArray pixels = sheet_bytes(sheet);
    const uint8_t *src = pixels.ptr();
    PackedByteArray out = blank_normal(src, width * height);
    if (!wants_coarse && !wants_fine) {
        return Image::create_from_data(width, height, false, Image::FORMAT_RGBA8, out);
    }
    uint8_t *dst = out.ptrw();

    const int32_t *rect_ptr = rects.ptr();
    for (int64_t n = 0; n + 3 < rects.size(); n += 4) {
        int64_t rx = 0;
        int64_t ry = 0;
        int64_t rw = 0;
        int64_t rh = 0;
        if (!rect_at(rect_ptr, n, width, height, rx, ry, rw, rh)) {
            continue;
        }

        const int64_t lw = rw + MARGIN * 2;
        const int64_t lh = rh + MARGIN * 2;

        PackedFloat32Array fine;
        fine.resize(lw * lh);
        float *light = fine.ptrw();

        double total = 0.0;
        int64_t counted = 0;
        for (int64_t y = 0; y < rh; y++) {
            const int64_t row = (ry + y) * width + rx;
            const int64_t local = (y + MARGIN) * lw + MARGIN;
            for (int64_t x = 0; x < rw; x++) {
                const uint8_t *here = src + (row + x) * 4;
                const double level =
                        (0.299 * here[0] + 0.587 * here[1] + 0.114 * here[2]) / 255.0;
                light[local + x] = iw::narrow(level);
                if (here[3] / 255.0 >= iw::SOLID_ALPHA) {
                    total += level;
                    counted++;
                }
            }
        }
        // A rectangle holding nothing solid has no brightness worth reading, and is left as
        // flat as it was.
        if (counted == 0) {
            continue;
        }

        // [b]Everything outside the sprite is filled with the sprite's own average.[/b] A
        // clear pixel carries near-black colour under its zero alpha, so left as it was every
        // silhouette would read as a cliff and swamp whatever is drawn inside.
        const float average = iw::narrow(total / static_cast<double>(counted));
        for (int64_t y = 0; y < rh; y++) {
            const int64_t row = (ry + y) * width + rx;
            const int64_t local = (y + MARGIN) * lw + MARGIN;
            for (int64_t x = 0; x < rw; x++) {
                if (src[(row + x) * 4 + 3] / 255.0 < iw::SOLID_ALPHA) {
                    light[local + x] = average;
                }
            }
        }
        // The margin repeats the row or column beside it, so the edge of the rectangle is not
        // itself a step for the gradient to find.
        for (int64_t y = 0; y < lh; y++) {
            const int64_t from_y = iw::mini(iw::maxi(y, MARGIN), rh);
            for (int64_t x = 0; x < lw; x++) {
                if (y >= MARGIN && y <= rh && x >= MARGIN && x <= rw) {
                    continue;
                }
                const int64_t from_x = iw::mini(iw::maxi(x, MARGIN), rw);
                light[y * lw + x] = light[from_y * lw + from_x];
            }
        }

        PackedFloat32Array coarse;
        if (wants_coarse) {
            coarse = IWPixelMath::box_mean(fine, lw, lh, iw::maxi(coarse_size, 1));
        }
        const float *detail = fine.ptr();
        const float *form = wants_coarse ? coarse.ptr() : nullptr;

        for (int64_t y = 0; y < rh; y++) {
            const int64_t row = (ry + y) * width + rx;
            const int64_t local = (y + MARGIN) * lw + MARGIN;
            for (int64_t x = 0; x < rw; x++) {
                if (src[(row + x) * 4 + 3] == 0) {
                    continue;
                }
                const int64_t at = local + x;
                double dhdx = 0.0;
                double dhdy = 0.0;
                if (wants_fine) {
                    double gx = 0.0;
                    double gy = 0.0;
                    scharr_at(detail, at, lw, gx, gy);
                    dhdx += fine_strength * gx;
                    dhdy += fine_strength * gy;
                }
                if (wants_coarse) {
                    double gx = 0.0;
                    double gy = 0.0;
                    scharr_at(form, at, lw, gx, gy);
                    dhdx += coarse_strength * gx;
                    dhdy += coarse_strength * gy;
                }
                pack_normal(dhdx, dhdy, green_down, dst + (row + x) * 4);
            }
        }
    }

    return Image::create_from_data(width, height, false, Image::FORMAT_RGBA8, out);
}

Ref<Image> IWStageKernels::combine_normals(
        const Ref<Image> &base,
        const Ref<Image> &detail,
        const PackedInt32Array &rects,
        int64_t mode,
        double opacity) {
    ERR_FAIL_COND_V(base.is_null(), Ref<Image>());
    if (detail.is_null() || base->is_empty() || detail->is_empty() || rects.is_empty()) {
        return base;
    }

    const int64_t width = base->get_width();
    const int64_t height = base->get_height();
    // Two maps of different sizes describe different sheets, and there is no answer to what
    // merging them would mean. The base is what the stack had, so it is what carries on.
    if (detail->get_width() != width || detail->get_height() != height) {
        return base;
    }

    const PackedByteArray under = sheet_bytes(base);
    const PackedByteArray over = sheet_bytes(detail);

    // Started as a copy of the base, so the space between sprites keeps whatever it had
    // there and the alpha comes through untouched.
    PackedByteArray out = under;
    uint8_t *dst = out.ptrw();
    const uint8_t *lower = under.ptr();
    const uint8_t *upper = over.ptr();

    const bool reorients = mode == 1;
    const int32_t *rect_ptr = rects.ptr();
    for (int64_t n = 0; n + 3 < rects.size(); n += 4) {
        int64_t rx = 0;
        int64_t ry = 0;
        int64_t rw = 0;
        int64_t rh = 0;
        if (!rect_at(rect_ptr, n, width, height, rx, ry, rw, rh)) {
            continue;
        }

        for (int64_t y = 0; y < rh; y++) {
            const int64_t row = (ry + y) * width + rx;
            for (int64_t x = 0; x < rw; x++) {
                const int64_t at = (row + x) * 4;
                double bx = 0.0;
                double by = 0.0;
                double bz = 0.0;
                unpack_normal(lower + at, bx, by, bz);
                double dx = 0.0;
                double dy = 0.0;
                double dz = 0.0;
                unpack_normal(upper + at, dx, dy, dz);

                // The detail as a slope, dialled down by the opacity. Done before either
                // mode runs, which is what makes an opacity of zero mean "the base exactly"
                // in both of them rather than in only one.
                const double sx = dx / dz * opacity;
                const double sy = dy / dz * opacity;

                if (reorients) {
                    // The detail turned to face the way the base does, so it follows a
                    // curve instead of lying flat across it.
                    const double length = std::sqrt(sx * sx + sy * sy + 1.0);
                    const double ux = -sx / length;
                    const double uy = -sy / length;
                    const double uz = 1.0 / length;
                    const double tz = bz + 1.0;
                    const double reach = (bx * ux + by * uy + tz * uz) / tz;
                    pack_direction(bx * reach - ux, by * reach - uy, tz * reach - uz,
                            dst + at);
                } else {
                    // Slopes added. See the header: the same answer as adding the two height
                    // surfaces and working the normal out once.
                    pack_direction(bx / bz + sx, by / bz + sy, 1.0, dst + at);
                }
            }
        }
    }

    return Image::create_from_data(width, height, false, Image::FORMAT_RGBA8, out);
}

Ref<Image> IWStageKernels::normal_flip_green(const Ref<Image> &map) {
    ERR_FAIL_COND_V(map.is_null(), Ref<Image>());
    if (map->is_empty()) {
        return map;
    }

    const int64_t width = map->get_width();
    const int64_t height = map->get_height();
    PackedByteArray out = sheet_bytes(map);
    uint8_t *dst = out.ptrw();

    // [b]255 minus the byte is the exact answer rather than an approximation of it.[/b]
    // Unpacking the value, negating it and packing it again lands on precisely this, because
    // the two halves of the range sit a half step either side of zero rather than on it.
    // That is also why a flat pixel comes back 127 rather than 128, which is a tilt of about
    // a fifth of a degree.
    const int64_t count = width * height;
    for (int64_t i = 0; i < count; i++) {
        dst[i * 4 + 1] = static_cast<uint8_t>(255 - dst[i * 4 + 1]);
    }

    return Image::create_from_data(width, height, false, Image::FORMAT_RGBA8, out);
}
