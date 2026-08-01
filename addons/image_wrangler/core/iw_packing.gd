@tool
class_name IWPacking
extends IWOperation

## Lifts every separate object out of the open images and lays them all on one sheet.
##
## The second operation here that describes the batch rather than any one image, and it
## sits beside [Rename] for that reason: its settings are held once for the session, no
## sidecar is written, and it answers a question none of the stack operations can, because
## the answer is not an image — it is [i]the[/i] image, made out of all of them.
##
## [b]An object is an island of visible pixels, and the alpha decides.[/b] Exactly what
## [RandomHSVTiles] calls a tile, through exactly the same code — see
## [method IWStageKernels.find_islands]. Each image is run through its own stack first, so
## what gets packed is what you keyed out and corrected rather than what came off disk. A
## file with no transparency is one sprite the size of itself, which is the honest answer
## and usually a sign the stack above it has not been built yet.
##
## [b]The sheet starts at the size you chose and doubles until everything fits.[/b] Width
## first, then height, then width again, stopping at the largest a texture may be. Switch
## [member PackingSettings.expand_to_fit] off to hold it at exactly the size asked for
## instead, which is the right way round when that size is one something else has already
## decided — a texture budget, a hardware limit, an atlas the rest of the project agrees
## on. Either way, running out of room is reported and the packing stops rather than
## quietly dropping whichever sprites were awkward.
##
## [b]One sheet, so one thing to save.[/b] Save Current writes it as a PNG; Save All has
## nothing to mean here, since the whole list has already gone into the one image, and
## stands down while this is showing. Nothing is written to a sidecar either — these
## settings describe the batch, like [Rename]'s.
##
## [b]The one thing a sheet cannot tell you is where anything on it went.[/b] Switch
## [member PackingSettings.create_lookup_table] on and saving writes a second file beside
## the PNG, named the same with [code]_lut.res[/code] on the end — a texture holding one
## pixel per sprite, in the order the sprites were found, whose red, green, blue and alpha
## are that sprite's left, top, width and height on the sheet in pixels. A shader given the
## sprite's number reads its rectangle in one fetch, instead of being told the layout some
## other way. See [method build_lookup_image] for the shape of it.

## How the sprites are arranged.
##
## The four differ in what they are willing to give up. Shelf and Tight both chase density
## and both scramble the order to get it; Grid gives up density entirely to keep a fixed
## stride; Original gives up density to keep the order it found things in.
enum PackMode {
    ## Tallest first, laid left to right, dropping to a new row when one fills. Rows are
    ## as tall as the tallest sprite on them, which sorting by height is what minimises.
    SHELF,
    ## One cell per sprite, every cell the size of the largest. Wasteful, and the only one
    ## that puts frames on a stride simple enough to index by number.
    GRID,
    ## Each sprite dropped into the lowest gap wide enough to take it, so shapes of
    ## different heights interlock. The densest of the four and the least predictable.
    TIGHT,
    ## Rows again, but in the order the sprites were found rather than by size — image by
    ## image, and within an image top to bottom. The only one where the order out means
    ## anything.
    ORIGINAL,
}

## Dropdown labels, in enum order.
const MODE_LABELS := ["Shelf", "Grid", "Tight", "Original Order"]

## What each mode does, in enum order, for the dock to show under the dropdown.
##
## [b]A sentence about what it does and a sentence about what it costs.[/b] The four are
## easy to tell apart once you know what each gives up, and impossible to choose between
## from the names alone — Shelf and Tight in particular sound like the same idea, and the
## thing that separates them is not density but whether you can predict where anything
## landed.
##
## Kept here beside the enum rather than in the dock, so a mode cannot be added without the
## line that explains it.
const MODE_DESCRIPTIONS := [
    "Sorts the sprites tallest first and fills rows left to right, starting a new row when one is full. Packs well and is the usual choice. The order is lost.",
    "Gives every sprite an identical cell, as wide as the widest and as tall as the tallest. Wastes room, and is the only mode that puts frames on a fixed stride you can index by number. The order is kept.",
    "Drops each sprite into the lowest gap wide enough to take it, so shapes of different heights interlock. Packs the tightest of the four. Where anything landed is anyone's guess.",
    "Fills rows without sorting, so the sprites stay in the order they were found — image by image, and within an image top to bottom. Packs worst, and is the only mode where the order out means something.",
]

## How a normal map is worked out for the sheet, if at all.
enum NormalMode {
    ## No normal map is written.
    DISABLED,
}

## Dropdown labels, in enum order.
const NORMAL_LABELS := ["Disabled"]

## What goes on the end of the normal map's name, extension included.
const NORMAL_SUFFIX := "_normal.png"

## Widest and shortest sheet that can be asked for.
##
## The ceiling is what a texture is allowed to be almost everywhere, and the floor is one
## pixel because there is no size small enough to be worth refusing — a sheet too small for
## the sprites reports that it did not fit, which is a better answer than a range that
## stops you asking.
const MIN_SIZE := 1
const MAX_SIZE := 16384

## How wide the lookup table is, in pixels, whatever is in it.
##
## Fixed rather than fitted to the sprite count so the shader side is a constant it can
## divide by rather than a number it has to be told. 256 rows the table over at a width
## every GPU takes, and a row of it is 4 KB — small enough that a sheet of nine sprites
## paying for the whole row is not worth a second thought.
const LUT_WIDTH := 256

## What goes on the end of the lookup table's name, extension included.
const LUT_SUFFIX := "_lut.res"

var settings: PackingSettings


func _init() -> void:
    settings = PackingSettings.new()


func get_operation_name() -> String:
    return "Export"


func get_operation_id() -> StringName:
    return &"packing"


func get_settings() -> Resource:
    return settings


func set_settings(new_settings: Resource) -> void:
    var typed := new_settings as PackingSettings
    if typed == null:
        push_error("Image Wrangler: IWPacking was handed settings of the wrong type.")
        return
    settings = typed


func make_settings() -> Resource:
    return PackingSettings.new()


func get_output_suffix() -> String:
    return "_packed"


## Held once for the session, like [Rename]'s: a sheet size and an arrangement describe the
## batch, and one that changed with whichever file was highlighted would mean nothing.
func settings_are_per_image() -> bool:
    return false


## False, because this does not turn one image into another — it turns a list of them into
## a single sheet, which is a different shape of job and does not go through the per-file
## write path at all. The dock saves the sheet itself; see the class note.
func transforms_pixels() -> bool:
    return false


func get_settings_schema() -> Array[Dictionary]:
    return [
        {
            "property": &"mode",
            "label": "Packing Mode",
            "type": SettingType.ENUM,
            "options": MODE_LABELS,
            "tooltip": "How the sprites are arranged on the sheet.\n\nShelf sorts them tallest first and fills rows, which packs well and is the\nusual choice. Grid gives every sprite an identical cell sized to the largest,\nwhich wastes room but puts frames on a fixed stride. Tight drops each one into\nthe lowest gap that will take it and packs best of all. Original Order fills\nrows without sorting, so the sprites stay in the order they were found.",
        },
        {
            "property": &"output_width",
            "label": "Width",
            "type": SettingType.INT,
            "min": MIN_SIZE,
            "max": MAX_SIZE,
            "step": 1,
            "tooltip": "How wide the packed sheet starts, in pixels.\n\nWhere it ends up depends on Expand to Fit: on, this is a starting point and the\nsheet doubles from it until everything fits; off, it is exactly the size used\nand you are told when the sprites do not fit in it.",
        },
        {
            "property": &"output_height",
            "label": "Height",
            "type": SettingType.INT,
            "min": MIN_SIZE,
            "max": MAX_SIZE,
            "step": 1,
            "tooltip": "How tall the packed sheet starts, in pixels.\n\nWhere it ends up depends on Expand to Fit: on, this is a starting point and the\nsheet doubles from it until everything fits; off, it is exactly the size used\nand you are told when the sprites do not fit in it.",
        },
        {
            "property": &"expand_to_fit",
            "label": "Expand to Fit",
            "type": SettingType.BOOL,
            "tooltip": "Doubles the sheet until everything fits, taking the width first, then the\nheight, then the width again.\n\nOff, the sheet stays exactly the size above and you are told when that is not\nenough — which is what you want when the size is one something else has already\ndecided.\n\nIt stops at %d, the largest a texture is allowed to be almost anywhere, and\nsays so if it gets there with sprites still to place." % MAX_SIZE,
        },
        {
            "property": &"create_lookup_table",
            "label": "Create Lookup Table",
            "type": SettingType.BOOL,
            "tooltip": "Writes a second file beside the sheet holding where every sprite landed on\nit, named the same with %s on the end.\n\nIt is a %d-wide texture with one pixel per sprite, in the order the sprites\nwere found. That pixel's red, green, blue and alpha are the sprite's left,\ntop, width and height on the sheet, in pixels — so a shader handed a sprite\nnumber can read its rectangle in one fetch.\n\nSprite n is at x = n %% %d, y = n / %d. The file is only written when the\nsheet is saved." % [LUT_SUFFIX, LUT_WIDTH, LUT_WIDTH, LUT_WIDTH],
        },
        {
            "property": &"normals",
            "label": "Normals",
            "type": SettingType.ENUM,
            "options": NORMAL_LABELS,
            "tooltip": "How a normal map is worked out for the packed sheet.\n\nDisabled writes nothing. Any other mode writes the map as a second file\nbeside the sheet, named the same with %s on the end, and only when the\nsheet is saved.\n\nDisabled is the only choice so far." % NORMAL_SUFFIX,
        },
    ]


## [param mode] pulled back into range, for a value that came from a hand-edited file
## rather than from the dropdown.
static func sanitise_mode(mode: int) -> int:
    return mode if mode >= 0 and mode < MODE_LABELS.size() else PackMode.SHELF


## What [param mode] does, in a couple of sentences.
static func describe_mode(mode: int) -> String:
    return MODE_DESCRIPTIONS[sanitise_mode(mode)]


# --- The packing --------------------------------------------------------

## Where each sprite goes on the sheet, given the size of each.
##
## [param sizes] is one [Vector2i] per sprite, in the order they were found. Returns
## [code]{"positions": Array[Vector2i], "placed": int, "width": int, "height": int}[/code],
## where positions runs alongside [param sizes] and holds the top-left corner each sprite
## was given, and the two sizes are the sheet it was planned for — which is not the one in
## the settings once [member PackingSettings.expand_to_fit] has grown it.
##
## [b]It stops at the first sprite that does not fit rather than skipping it.[/b] A packer
## that carried on would produce a sheet missing whichever sprites happened to be awkward,
## and nothing on it would say which — where stopping leaves one number to report and one
## thing to do about it. [code]placed[/code] is how many went down before that happened, so
## a caller can say how far it got.
func plan(sizes: Array) -> Dictionary:
    var width: int = clampi(settings.output_width, MIN_SIZE, MAX_SIZE)
    var height: int = clampi(settings.output_height, MIN_SIZE, MAX_SIZE)
    var mode := sanitise_mode(settings.mode)
    var wanted := _packable(sizes)

    var attempt := _plan_at(sizes, width, height, mode)
    if attempt["placed"] >= wanted or not settings.expand_to_fit:
        return _at_size(attempt, width, height)

    # [b]Doubling, alternately, rather than working out the size that would fit.[/b] There
    # is no size to work out: Grid's capacity appears a whole cell at a time, and the row
    # modes depend on which sprite lands where, so a sheet arrived at by calculation is one
    # the packer might still refuse over a rounding. Doubling and asking is the answer that
    # cannot be wrong, and it is at most a couple of dozen attempts from any starting size
    # to the ceiling.
    #
    # Width first, then height, so a sheet grows wide before it grows tall — which is the
    # way a sprite sheet is usually looked at, and the way the rows already run.
    var grow_width := true
    while width < MAX_SIZE or height < MAX_SIZE:
        # The axis whose turn it is, unless that one is already at the ceiling and the
        # other is not — alternating into a wall would stop the search early.
        if grow_width and width >= MAX_SIZE:
            grow_width = false
        elif not grow_width and height >= MAX_SIZE:
            grow_width = true

        if grow_width:
            width = mini(width * 2, MAX_SIZE)
        else:
            height = mini(height * 2, MAX_SIZE)
        grow_width = not grow_width

        attempt = _plan_at(sizes, width, height, mode)
        if attempt["placed"] >= wanted:
            break

    return _at_size(attempt, width, height)


## One attempt, at one size.
func _plan_at(sizes: Array, width: int, height: int, mode: int) -> Dictionary:
    match mode:
        PackMode.GRID:
            return _plan_grid(sizes, width, height)
        PackMode.TIGHT:
            return _plan_tight(sizes, width, height, _by_height(sizes))
        PackMode.ORIGINAL:
            return _plan_rows(sizes, width, height, _in_order(sizes))
        _:
            return _plan_rows(sizes, width, height, _by_height(sizes))


## How many of [param sizes] are real sprites, which is what "everything fitted" means.
##
## A sprite of no area is skipped rather than placed, so counting the list itself would
## make a plan holding one look like a plan that failed — and, with expansion on, would
## double the sheet to the ceiling chasing a sprite that was never going down.
func _packable(sizes: Array) -> int:
    var count := 0
    for size: Vector2i in sizes:
        if size.x > 0 and size.y > 0:
            count += 1
    return count


## The plan, told what size it was made for.
##
## The caller needs the size as well as the positions once expansion is in play, since the
## sheet it goes on to make is no longer the one in the settings.
func _at_size(attempt: Dictionary, width: int, height: int) -> Dictionary:
    attempt["width"] = width
    attempt["height"] = height
    return attempt


## Sprite indices tallest first, and widest first among equals.
##
## The width tiebreak matters more than it looks: rows are filled left to right, so putting
## the wide ones down first leaves the narrow ones to fill the gap at the end of a row
## rather than starting a new one.
func _by_height(sizes: Array) -> Array:
    var order := _in_order(sizes)
    order.sort_custom(func(a: int, b: int) -> bool:
        var first: Vector2i = sizes[a]
        var second: Vector2i = sizes[b]
        if first.y != second.y:
            return first.y > second.y
        if first.x != second.x:
            return first.x > second.x
        # Falls back to the order they were found, so the sort is total and two runs on
        # the same sprites cannot come out differently.
        return a < b)
    return order


func _in_order(sizes: Array) -> Array:
    var order := []
    for i in sizes.size():
        order.append(i)
    return order


## Rows, filled left to right, each as tall as the tallest sprite on it.
func _plan_rows(sizes: Array, width: int, height: int, order: Array) -> Dictionary:
    var positions := _blank_positions(sizes.size())
    var pen := Vector2i.ZERO
    var row_height := 0
    var placed := 0

    for index: int in order:
        var size: Vector2i = sizes[index]
        if size.x <= 0 or size.y <= 0:
            continue
        # A sprite wider than the sheet can never go anywhere, so it is a failure rather
        # than a row that gets dropped and retried forever.
        if size.x > width:
            return {"positions": positions, "placed": placed}
        if pen.x + size.x > width:
            pen = Vector2i(0, pen.y + row_height)
            row_height = 0
        if pen.y + size.y > height:
            return {"positions": positions, "placed": placed}
        positions[index] = pen
        pen.x += size.x
        row_height = maxi(row_height, size.y)
        placed += 1

    return {"positions": positions, "placed": placed}


## One cell per sprite, every cell the size of the largest.
##
## Laid in the order found rather than sorted: the whole point of a fixed stride is that
## the nth cell is the nth sprite, and sorting would break the only property this mode has
## that the others do not.
func _plan_grid(sizes: Array, width: int, height: int) -> Dictionary:
    var positions := _blank_positions(sizes.size())
    var cell := Vector2i.ZERO
    for size: Vector2i in sizes:
        cell.x = maxi(cell.x, size.x)
        cell.y = maxi(cell.y, size.y)
    if cell.x <= 0 or cell.y <= 0:
        return {"positions": positions, "placed": 0}

    var columns: int = width / cell.x
    var rows: int = height / cell.y
    if columns <= 0 or rows <= 0:
        return {"positions": positions, "placed": 0}

    var placed := 0
    for index in sizes.size():
        var size: Vector2i = sizes[index]
        if size.x <= 0 or size.y <= 0:
            continue
        if placed >= columns * rows:
            return {"positions": positions, "placed": placed}
        @warning_ignore("integer_division")
        positions[index] = Vector2i((placed % columns) * cell.x, (placed / columns) * cell.y)
        placed += 1

    return {"positions": positions, "placed": placed}


## Each sprite dropped into the lowest gap wide enough to take it.
##
## The skyline is one height per column: how far down the sheet is already spoken for
## there. A sprite of width w can go at x only above the highest point of the w columns it
## would cover, so the best x is the one where that running maximum is smallest.
##
## [b]The running maximum is swept rather than recomputed.[/b] Asking for the maximum of
## every window separately is the obvious way and is the width of the sheet times the width
## of the sprite, per sprite — on a 2048-wide sheet with a hundred sprites that is tens of
## millions of comparisons in GDScript. The sliding window below answers all of them in one
## pass over the row, which is what makes this mode usable on a real sheet rather than
## merely correct.
func _plan_tight(sizes: Array, width: int, height: int, order: Array) -> Dictionary:
    var positions := _blank_positions(sizes.size())
    var skyline := PackedInt32Array()
    skyline.resize(width)
    skyline.fill(0)
    var placed := 0

    for index: int in order:
        var size: Vector2i = sizes[index]
        if size.x <= 0 or size.y <= 0:
            continue
        if size.x > width:
            return {"positions": positions, "placed": placed}

        var at := _lowest_gap(skyline, size.x, width)
        if at.x < 0 or at.y + size.y > height:
            return {"positions": positions, "placed": placed}

        positions[index] = at
        var settled := at.y + size.y
        for x in range(at.x, at.x + size.x):
            skyline[x] = settled
        placed += 1

    return {"positions": positions, "placed": placed}


## The lowest place a sprite [param span] wide will sit on [param skyline], and the
## leftmost of those where several are equally low.
##
## A monotone deque sweep: the front of the queue is always the tallest column in the
## window, and columns shorter than one arriving behind them can never be the answer again,
## so they are dropped. One pass, and every column enters and leaves once.
##
## Returns (-1, -1) when the sprite is wider than the sheet.
func _lowest_gap(skyline: PackedInt32Array, span: int, width: int) -> Vector2i:
    if span > width:
        return Vector2i(-1, -1)

    var window := PackedInt32Array()
    var head := 0
    var best := Vector2i(-1, -1)

    for x in width:
        while window.size() > head and skyline[window[window.size() - 1]] <= skyline[x]:
            window.resize(window.size() - 1)
        window.append(x)
        # The tallest column that has dropped out of the window behind us is no longer
        # anybody's answer.
        if window[head] <= x - span:
            head += 1
        if x < span - 1:
            continue
        var top: int = skyline[window[head]]
        if best.x < 0 or top < best.y:
            best = Vector2i(x - span + 1, top)

    return best


func _blank_positions(count: int) -> Array:
    var out := []
    for _i in count:
        out.append(Vector2i(-1, -1))
    return out


# --- The lookup table ----------------------------------------------------

## Where the lookup table goes, given where the sheet went.
##
## The sheet's own name with the extension swapped, so the two travel together and it is
## obvious at a glance which table belongs to which sheet.
static func lookup_path_for(sheet_path: String) -> String:
    return sheet_path.get_basename() + LUT_SUFFIX


## How big a table [param count] sprites needs.
##
## [constant LUT_WIDTH] across always, and as many rows as that takes rounded up to a power
## of two. Rounding wastes at most half a table's worth of empty pixels, which at 4 KB a row
## is nothing, and buys a height a shader can shift by rather than divide by — and one that
## stops changing every time a sprite is added or taken away.
static func lookup_size(count: int) -> Vector2i:
    var rows: int = maxi(1, ceili(float(maxi(count, 1)) / float(LUT_WIDTH)))
    return Vector2i(LUT_WIDTH, nearest_po2(rows))


## The lookup table itself, from one [Rect2i] per sprite in the order they were found.
##
## Sprite n is the pixel at [code](n % LUT_WIDTH, n / LUT_WIDTH)[/code], and its channels
## are the rectangle: red and green the top-left corner, blue and alpha the size, all four
## in sheet pixels rather than normalized — divide by [code]textureSize()[/code] in the
## shader if UVs are what is wanted.
##
## [b]RGBAF, so the numbers survive.[/b] A coordinate on a 2048-wide sheet needs more than
## the 256 steps a byte per channel gives, and full floats hold a whole pixel count exactly
## with nothing to unpack at the other end. Pixels past the last sprite are left at zero,
## which is a rectangle of no area and so cannot be mistaken for a sprite.
static func build_lookup_image(rects: Array) -> Image:
    var size := lookup_size(rects.size())
    var image := Image.create_empty(size.x, size.y, false, Image.FORMAT_RGBAF)
    for i in rects.size():
        var rect: Rect2i = rects[i]
        @warning_ignore("integer_division")
        image.set_pixel(i % LUT_WIDTH, i / LUT_WIDTH,
                Color(rect.position.x, rect.position.y, rect.size.x, rect.size.y))
    return image


## The lookup table as the thing that gets saved.
##
## An [ImageTexture] rather than the [Image], because what this is for is being dropped into
## a shader's texture slot — and saved as a binary [code].res[/code], which keeps the float
## format exactly. A PNG could not: the image importer only ever hands back bytes, and
## Detect 3D would quietly re-compress it the first time a 3D material touched it.
static func build_lookup_texture(rects: Array) -> ImageTexture:
    return ImageTexture.create_from_image(build_lookup_image(rects))
