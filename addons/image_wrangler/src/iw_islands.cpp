#include "iw_islands.h"

#include "iw_math.h"

namespace iw {

Islands label_islands(const float *alpha, int64_t width, int64_t height) {
    Islands found;
    const int64_t pixel_count = width * height;
    if (alpha == nullptr || pixel_count <= 0) {
        return found;
    }

    found.label.assign(static_cast<size_t>(pixel_count), -1);
    std::vector<int32_t> &label = found.label;

    // One queue for both passes. Every pixel enters it at most once — it is put there by
    // whichever label claimed it, and a labelled pixel is never offered again — so it can
    // be sized up front and used as a plain FIFO with no wraparound. The second pass
    // rewinds over what the first left in it, which is every solid pixel in the order it
    // was labelled, and appends the fringe to the same buffer.
    std::vector<int32_t> queue(static_cast<size_t>(pixel_count), 0);
    int64_t head = 0;
    int64_t tail = 0;

    // Marks one pixel as belonging to one island, stretches that island's rectangle round
    // it, and queues it.
    const auto claim = [&](int32_t index, int32_t island) {
        label[index] = island;
        const int32_t x = static_cast<int32_t>(index % width);
        const int32_t y = static_cast<int32_t>(index / width);
        if (x < found.min_x[island]) {
            found.min_x[island] = x;
        }
        if (x > found.max_x[island]) {
            found.max_x[island] = x;
        }
        if (y < found.min_y[island]) {
            found.min_y[island] = y;
        }
        if (y > found.max_y[island]) {
            found.max_y[island] = y;
        }
        queue[tail++] = index;
    };

    // The solid part, one island at a time. Each island's flood drains before the scan
    // moves on, so the queue holds them in the order they were found.
    for (int64_t i = 0; i < pixel_count; i++) {
        if (label[i] >= 0 || iw::widen(alpha[i]) < SOLID_ALPHA) {
            continue;
        }
        const int32_t here = static_cast<int32_t>(found.min_x.size());
        found.min_x.push_back(static_cast<int32_t>(i % width));
        found.max_x.push_back(found.min_x[here]);
        found.min_y.push_back(static_cast<int32_t>(i / width));
        found.max_y.push_back(found.min_y[here]);
        claim(static_cast<int32_t>(i), here);

        while (head < tail) {
            const int32_t index = queue[head++];
            const int64_t x = index % width;
            const int64_t y = index / width;
            const int64_t first_row = iw::maxi(y - 1, 0);
            const int64_t last_row = iw::mini(y + 1, height - 1);
            const int64_t first_col = iw::maxi(x - 1, 0);
            const int64_t last_col = iw::mini(x + 1, width - 1);
            for (int64_t row = first_row; row <= last_row; row++) {
                for (int64_t col = first_col; col <= last_col; col++) {
                    const int32_t n = static_cast<int32_t>(row * width + col);
                    if (label[n] < 0 && iw::widen(alpha[n]) >= SOLID_ALPHA) {
                        claim(n, here);
                    }
                }
            }
        }
    }

    if (found.count() <= 0) {
        return found;
    }

    // The fringe, from every island at once. Rewinding rather than reseeding: what the
    // first pass left in the queue is exactly the set to grow from, and growing them
    // together is what stops the island that happened to be found first claiming the
    // whole of a fringe two objects share.
    head = 0;
    while (head < tail) {
        const int32_t index = queue[head++];
        const int32_t here = label[index];
        const int64_t x = index % width;
        const int64_t y = index / width;
        const int64_t first_row = iw::maxi(y - 1, 0);
        const int64_t last_row = iw::mini(y + 1, height - 1);
        const int64_t first_col = iw::maxi(x - 1, 0);
        const int64_t last_col = iw::mini(x + 1, width - 1);
        for (int64_t row = first_row; row <= last_row; row++) {
            for (int64_t col = first_col; col <= last_col; col++) {
                const int32_t n = static_cast<int32_t>(row * width + col);
                if (label[n] < 0 && iw::widen(alpha[n]) > 0.0) {
                    claim(n, here);
                }
            }
        }
    }

    return found;
}

} // namespace iw
