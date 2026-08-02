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
## the PNG, named the same with [code]_lut.res[/code] on the end — a texture holding two
## pixels per sprite, in the order the sprites were found: the rectangle it landed in, then
## its pivot. A shader given the sprite's number reads both in two fetches, instead of
## being told the layout some other way. See [method build_lookup_image] for the shape of
## it.
##
## [b]A normal map can come off the same sheet.[/b] Add anything to [member normal_layers]
## and saving writes a third file, named the same with [code]_normal.png[/code] on the end,
## holding which way each pixel of each sprite faces so a 2D light has something to catch.
## Every sprite is worked out inside its own rectangle and nowhere else, so nothing on the
## sheet can lean on whatever it was packed next to — see [method build_normal_map]. The dock
## can show it in place of the sheet while it is being tuned, which is the only way to tell
## whether the rounding is following the art.
##
## [b]The layers are a stack, not a choice.[/b] Each [IWNormalLayer] reads something different
## about the sprite — its outline, its colours, its colour boundaries — and each builds on
## what the ones above it made rather than replacing them, so the shape a rounded rim gives a
## sprite and the texture its paint holds can both be in the same map.

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

## The widest gap that can be asked for between sprites.
const MAX_PADDING := 16

## What goes on the end of the lookup table's name, extension included.
const LUT_SUFFIX := "_lut.res"

var settings: PackingSettings

## The normal map generators, in the order they run. See [method build_normal_map].
##
## Held here rather than in the dock for the same reason [member settings] is: this is what
## a normal map is made out of, and the dock is only where it is edited. An empty stack, or
## one with nothing switched on, means no normal map is written at all.
var normal_layers: Array = []

## Why the last normal map could not be made, or empty when it could.
##
## [b]Deliberately not exported.[/b] An observation about one run rather than a setting, the
## way [member RemoveMinimumAreaSettings.removed_bounds] is — and the only layer that can
## fail for a reason worth reading is the one that depends on a file the user brought.
var normal_error := ""


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


## Held once for the batch, like [Rename]'s: a sheet size and an arrangement describe the
## batch, and one that changed with whichever file was highlighted would mean nothing.
##
## [b]This does not mean they are not saved.[/b] They go to a file of their own named for
## the batch rather than into any one image's sidecar; see [method export_config_path].
func settings_are_per_image() -> bool:
    return false


## The codec, for the one constant [method export_config_path] needs off it. Preloaded
## rather than named, because that file claims no class name of its own.
const SettingsIO := preload("res://addons/image_wrangler/core/iw_settings_io.gd")

## What goes on the front of the file this tab's settings are saved to.
const EXPORT_CONFIG_PREFIX := "export_"

## The folder every batch's export settings go to, inside the project's user data.
const EXPORT_CONFIG_DIR := "user://image_wrangler/exports"

## How much of the batch's fingerprint goes into that name, in characters.
##
## Sixteen hexadecimal characters is sixty-four bits. Two different sets of images landing
## on the same name would mean one opening with the other's settings, and at sixty-four bits
## that will not happen to anybody.
const EXPORT_CONFIG_KEY_LENGTH := 16


## Where this batch's export settings live: in [constant EXPORT_CONFIG_DIR], named for
## which images they are.
##
## The Export tab describes a whole list of files rather than any one of them, so it has no
## image to put a sidecar next to. It gets a file of its own instead, keyed on what is in the
## list, so a batch you come back to comes back with the sheet size and the normal map
## generators you left it with.
##
## [b]Keyed on the file names sorted, not on the full paths.[/b] Moving the folder keeps the
## match, and the order the files were added in is not part of what the settings describe.
##
## A different set of images is a different key and so a different file — adding one image to
## a batch does not find the config the batch had without it. The old file is left where it
## is rather than cleaned up, so putting the list back finds it again.
static func export_config_path(sources: PackedStringArray) -> String:
    if sources.is_empty():
        return ""
    var names := []
    for path in sources:
        names.append(path.get_file())
    names.sort()
    var key := "\n".join(names).sha256_text().substr(0, EXPORT_CONFIG_KEY_LENGTH)
    return EXPORT_CONFIG_DIR.path_join("%s%s%s"
            % [EXPORT_CONFIG_PREFIX, key, SettingsIO.SIDECAR_SUFFIX])


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
            "property": &"padding",
            "label": "Padding",
            "type": SettingType.INT,
            "min": 0,
            "max": MAX_PADDING,
            "step": 1,
            "tooltip": "Empty pixels kept between the sprites, and between the sprites and the\nsheet's edges.\n\nOne is enough to stop texture filtering pulling a neighbour's colour in at\nthe rim. The lookup table holds each sprite's own rectangle, without the\npadding.",
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
            "tooltip": "Writes a second file beside the sheet holding where every sprite landed on\nit, named the same with %s on the end.\n\nIt is a texture with two pixels per sprite, in the order the sprites were\nfound. The first pixel is the sprite's rectangle: left, top, width, height\non the sheet, in pixels. The second is its pivot: where it sits, then a unit\nvector for which way it points — the middle of the rectangle pointing (0, 1)\nuntil a pivot is set.\n\nSprite n's first pixel is at x = (2n) %% width, y = (2n) / width, and the\nsecond is one to its right. Both sides are powers of two, grown width first\nas sprites are added — read the size with textureSize(). The file is only\nwritten when the sheet is saved." % LUT_SUFFIX,
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
    var padding: int = clampi(settings.padding, 0, MAX_PADDING)
    # [b]Padding is a trick of sizes, not a change to the packers.[/b] Each sprite is grown
    # by the padding on its right and bottom, and planned into a sheet shrunk by the same
    # amount at the left and top. The growth becomes the gap to the next sprite along and
    # the border at the far edges; the shrink becomes the border at the near ones. The
    # positions come back shifted onto the real sheet at the end.
    var padded := _padded(sizes, padding)
    var wanted := _packable(sizes)

    var attempt := _plan_at(padded, maxi(width - padding, 0), maxi(height - padding, 0), mode)
    if attempt["placed"] >= wanted or not settings.expand_to_fit:
        return _at_size(_shifted(attempt, padding), width, height)

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

        attempt = _plan_at(padded, maxi(width - padding, 0), maxi(height - padding, 0), mode)
        if attempt["placed"] >= wanted:
            break

    return _at_size(_shifted(attempt, padding), width, height)


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


## Each real sprite grown by [param padding] on the right and bottom. Empty ones stay
## empty, so they are still skipped rather than placed as a square of nothing.
func _padded(sizes: Array, padding: int) -> Array:
    if padding <= 0:
        return sizes
    var out := []
    for size: Vector2i in sizes:
        if size.x > 0 and size.y > 0:
            out.append(size + Vector2i(padding, padding))
        else:
            out.append(size)
    return out


## Every placed position moved down and right by [param padding], onto the real sheet.
func _shifted(attempt: Dictionary, padding: int) -> Dictionary:
    if padding > 0:
        var positions: Array = attempt["positions"]
        for i in positions.size():
            if positions[i].x >= 0:
                positions[i] += Vector2i(padding, padding)
    return attempt


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


## How big a table [param count] sprites needs, at two pixels each.
##
## Both sides powers of two, grown width first: when the table is full, the width doubles
## while it equals the height and the height doubles otherwise, so it goes 2 x 1, 2 x 2,
## 4 x 2, 4 x 4 and stays square or 2:1. The width is always even, which is what keeps a
## sprite's two pixels on one row. The shader reads the size with
## [code]textureSize()[/code] rather than being told it.
static func lookup_size(count: int) -> Vector2i:
    var pixels := maxi(count * 2, 2)
    var width := 2
    var height := 1
    while width * height < pixels:
        if width == height:
            width *= 2
        else:
            height *= 2
    return Vector2i(width, height)


## The lookup table itself, from one [Rect2i] per sprite in the order they were found.
##
## Sprite n owns pixels [code]2n[/code] and [code]2n + 1[/code], counted row by row: the
## first is at [code]((2n) % width, (2n) / width)[/code] and the second sits directly to
## its right. The first pixel is the rectangle — red and green the top-left corner, blue
## and alpha the size. The second is the pivot: red and green where it sits, blue and
## alpha a unit vector for which way it points. Everything is in sheet pixels rather than
## normalized — divide by the sheet's size in the shader if UVs are what is wanted.
##
## Until the pivot editor exists, every pivot is the middle of its rectangle pointing
## [code](0, 1)[/code].
##
## [b]RGBAF, so the numbers survive.[/b] A coordinate on a 2048-wide sheet needs more than
## the 256 steps a byte per channel gives, and full floats hold a whole pixel count exactly
## with nothing to unpack at the other end. A sprite that was not placed keeps both pixels
## at zero — no area, and a pivot direction of no length — as does everything past the
## last sprite.
static func build_lookup_image(rects: Array) -> Image:
    var size := lookup_size(rects.size())
    var image := Image.create_empty(size.x, size.y, false, Image.FORMAT_RGBAF)
    for i in rects.size():
        var rect: Rect2i = rects[i]
        if rect.size.x <= 0 or rect.size.y <= 0:
            continue
        var base := i * 2
        @warning_ignore("integer_division")
        var at := Vector2i(base % size.x, base / size.x)
        image.set_pixel(at.x, at.y,
                Color(rect.position.x, rect.position.y, rect.size.x, rect.size.y))
        var pivot := Vector2(rect.position) + Vector2(rect.size) * 0.5
        image.set_pixel(at.x + 1, at.y, Color(pivot.x, pivot.y, 0.0, 1.0))
    return image


## The lookup table as the thing that gets saved.
##
## An [ImageTexture] rather than the [Image], because what this is for is being dropped into
## a shader's texture slot — and saved as a binary [code].res[/code], which keeps the float
## format exactly. A PNG could not: the image importer only ever hands back bytes, and
## Detect 3D would quietly re-compress it the first time a 3D material touched it.
static func build_lookup_texture(rects: Array) -> ImageTexture:
    return ImageTexture.create_from_image(build_lookup_image(rects))


# --- The normal map ------------------------------------------------------

## Where the normal map goes, given where the sheet went.
##
## The sheet's own name with the extension swapped, for the reason [method lookup_path_for]
## does the same: the two travel together and it is obvious which belongs to which.
static func normal_path_for(sheet_path: String) -> String:
    return sheet_path.get_basename() + NORMAL_SUFFIX


## The normal map for a finished sheet, or null when nothing is generating one.
##
## [param rects] is where every sprite landed, one [Rect2i] each in the order they were
## found — the same array the lookup table is built from.
##
## [b]Worked out from the finished sheet rather than sprite by sprite on the way in.[/b]
## The sheet and the rectangles are both already in hand once a packing has run, so changing
## a strength costs one pass over pixels that exist rather than a run of every open image's
## stack to arrive back at the same sprites. It is also what makes the dock's preview of this
## affordable at all.
##
## Every sprite is worked out inside its own rectangle and nowhere else, which is what stops
## one leaning on whatever it was packed next to. The space between them is left flat.
##
## [b]Each layer builds on what the ones above it left.[/b] The first one switched on is the
## base and its own combine settings mean nothing; every one after it is merged in the way
## its card says. A layer that cannot make a map is stepped over rather than failing the
## stack, and says why through [member normal_error].
##
## [b]Green is flipped once, here, rather than by each layer.[/b] Every generator writes
## green pointing up, so combining never has to reason about which way round its inputs were
## written.
func build_normal_map(sheet: Image, rects: Array) -> Image:
    normal_error = ""
    if sheet == null or sheet.is_empty():
        return null
    var flat := _flat_rects(rects)
    if flat.is_empty():
        return null

    var out: Image = null
    for layer: IWNormalLayer in normal_layers:
        if not layer.enabled:
            continue
        var map := layer.generate(sheet, flat)
        if map == null:
            if not layer.last_error.is_empty():
                normal_error = layer.last_error
            continue
        if out == null:
            out = map
        else:
            var how: NormalLayerSettings = layer.get_settings()
            out = IWStageKernels.combine_normals(out, map, flat, how.combine_mode,
                    how.combine_opacity)

    if out == null:
        return null
    # Before the flip, which only moves a channel and so cannot care either way — but after
    # everything that makes a shape, since what this evens out is what they left at the rim.
    if settings.normal_clean_edges:
        out = IWStageKernels.normal_clean_edges(out, flat, settings.normal_inner_reach)
    if settings.normal_green_down:
        out = IWStageKernels.normal_flip_green(out)
    return out


## Whether working the map out for [param sheet] now would mean waiting on something slow.
##
## True while a layer that runs a network has nothing in hand for this sheet, and false once
## it has — so the dock can follow a slider again the moment the expensive part is done, and
## a change to a layer below the network costs nothing but the pass it is worth.
##
## Asked of the stack rather than of the ids in it, so a second slow layer would be answered
## by the same question rather than by another special case here.
func normals_need_run(sheet: Image, rects: Array) -> bool:
    if sheet == null or sheet.is_empty():
        return false
    var flat := _flat_rects(rects)
    if flat.is_empty():
        return false
    for layer: IWNormalLayer in normal_layers:
        if layer.enabled and layer.is_expensive(sheet, flat):
            return true
    return false


## The rectangles flattened to x, y, w, h per sprite, which is the shape the kernels take.
##
## A rectangle of no area is left in place rather than dropped, so what comes out is still
## numbered the way the lookup table is.
func _flat_rects(rects: Array) -> PackedInt32Array:
    var flat := PackedInt32Array()
    flat.resize(rects.size() * 4)
    for i in rects.size():
        var rect: Rect2i = rects[i]
        flat[i * 4] = rect.position.x
        flat[i * 4 + 1] = rect.position.y
        flat[i * 4 + 2] = rect.size.x
        flat[i * 4 + 3] = rect.size.y
    return flat
