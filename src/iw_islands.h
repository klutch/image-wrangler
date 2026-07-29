#pragma once

// Finding the separate objects in an image, off nothing but its alpha.
//
// Two stages ask this question and they have to get the same answer. RandomHSVTiles gives
// every object its own colour; Repack lifts every object out and lays it somewhere else.
// If the two disagreed about what an object is, a sheet coloured by one and packed by the
// other would come apart — so the labelling lives here rather than in either of them, and
// "the same islands as Random HSV Tiles" is a fact about the code rather than a claim in a
// comment.
//
// [b]An island is whatever the alpha says it is.[/b] Nothing here reads colour. What
// counts as visible is the caller's business: a stage hands in the alpha the run currently
// shows, so where it sits in the stack decides what it finds.

#include <cstdint>
#include <vector>

namespace iw {

// How much of a pixel has to survive for it to count as part of an object rather than
// part of its fringe. Half, matching what RemoveLines calls the solid part of a shape.
inline constexpr double SOLID_ALPHA = 0.5;

// Which island each pixel belongs to, and the smallest rectangle round each one.
//
// `label` is -1 for a pixel no island claimed. The rectangles are inclusive on both
// corners; `count` is how many islands there are.
struct Islands {
    std::vector<int32_t> label;
    std::vector<int32_t> min_x;
    std::vector<int32_t> min_y;
    std::vector<int32_t> max_x;
    std::vector<int32_t> max_y;

    int64_t count() const {
        return static_cast<int64_t>(min_x.size());
    }
};

// Labels every island of visible pixels in an alpha map.
//
// [b]Two passes, because thickness and extent are different questions.[/b] The first
// labels the solid part, where alpha is at least a half, and that is what decides which
// pixels are one object. The second grows each label outwards through anything still
// visible, which is what brings an object's antialiased fringe along with it — a fringe
// left behind would ring every object in the colour it used to be, and would be cropped
// off every sprite lifted out of a sheet. The same split RemoveLines makes, for the same
// reason. An island with no solid pixel anywhere is never labelled.
//
// [b]8-connected, where the keying floods are 4-connected.[/b] Their question is whether
// background can leak through a diagonal hairline, and it must not. The question here is
// whether two parts touching corner to corner are one object, and they are — splitting
// them would hand one flower two colours, or cut one sprite into two.
//
// Islands come back in the order they were found, which is the scan order of their first
// solid pixel: top to bottom, then left to right.
Islands label_islands(const float *alpha, int64_t width, int64_t height);

} // namespace iw
