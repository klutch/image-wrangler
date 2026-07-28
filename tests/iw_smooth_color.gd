extends SceneTree

## The Smooth Color stage, checked for what it promises rather than for bytes.
##
## It flattens color and leaves brightness alone, so those are the two things worth
## asserting: color noise measurably drops, and every pixel's brightness comes back where
## it started. The exact numbers are a filter's business and would only freeze a tuning
## choice in place.
##
## Reached through [method load] rather than by [code]class_name[/code], so this runs
## before the editor has rescanned the project.
##
## Run it:
## [codeblock]
## godot --headless --path . --script res://tests/iw_smooth_color.gd
## [/codeblock]

const OP_SMOOTH_COLOR := "res://addons/image_wrangler/core/smooth_color.gd"
const OP_REMOVE_BACKGROUND := "res://addons/image_wrangler/core/remove_background.gd"

const W := 96
const H := 96

## Where the color noise sits, so the numbers below mean the same thing every run.
const NOISE_SEED := 20260728

## The smeared-background fixture. Pale rather than white so its color has room to move
## either way without running out of range, which is what a real smear needs.
const GROUND := Color(0.8, 0.8, 0.8)
const SUBJECT := Color(0.15, 0.3, 0.8)

var _failures := 0


func _initialize() -> void:
    _check_binding()
    _check_flattens_color()
    _check_keeps_brightness()
    _check_identity()
    _check_edges()
    _check_gray()
    _check_helps_keying()

    if _failures == 0:
        print("Smooth Color OK — color flattens, brightness and alpha do not move, and "
                + "edges stay where the brightness put them.")
    quit(1 if _failures > 0 else 0)


func _check_binding() -> void:
    _expect(ClassDB.class_has_method("IWStageKernels", "smooth_color"),
            "IWStageKernels.smooth_color is not bound — the build did not pick up "
            + "iw_color_kernels.cpp")


# --- It does what it is for ---------------------------------------------

## Color noise on a flat field is the thing this exists to remove.
func _check_flattens_color() -> void:
    var ctx := IWPipelineContext.from_image(_noisy_flat())
    var before := _color_spread(ctx.data)
    _stage(2, 0.5, 1.0).process_context(ctx)
    var after := _color_spread(ctx.data)
    print("  color spread on a flat field: %.4f -> %.4f" % [before, after])
    _expect(after < before * 0.5, "the color did not measurably flatten")


## Brightness is the half it must not touch.
func _check_keeps_brightness() -> void:
    var image := _noisy_flat()
    var ctx := IWPipelineContext.from_image(image)
    var before: PackedByteArray = ctx.data
    _stage(2, 0.5, 1.0).process_context(ctx)

    var worst := 0.0
    for i in W * H:
        worst = maxf(worst, absf(_brightness(before, i) - _brightness(ctx.data, i)))
    print("  worst brightness move: %.4f" % worst)
    # Not zero: brightness survives the trip out and back exactly, but the color moved
    # under it and the result is rounded into eight bits on the way to disk.
    _expect(worst < 0.02, "brightness moved by %.4f, which is more than rounding" % worst)
    _expect(_alpha_matches(before, ctx.data), "alpha was not preserved byte for byte")


## An amount of zero is a request for nothing, and has to be exact rather than a round
## trip that happens to land back where it started.
func _check_identity() -> void:
    var ctx := IWPipelineContext.from_image(_noisy_flat())
    var before: PackedByteArray = ctx.data
    _stage(2, 0.5, 0.0).process_context(ctx)
    _expect(ctx.data == before, "an amount of 0.0 was not an exact identity")

    var no_reach := IWPipelineContext.from_image(_noisy_flat())
    var untouched: PackedByteArray = no_reach.data
    _stage(0, 0.5, 1.0).process_context(no_reach)
    _expect(no_reach.data == untouched, "a radius of 0 was not an exact identity")


## The point of steering by brightness: color must not cross an edge the brightness has.
func _check_edges() -> void:
    var ctx := IWPipelineContext.from_image(_two_halves())
    _stage(3, 0.5, 1.0).process_context(ctx)

    # A column well inside the dark half must not have picked up the bright half's color.
    var at := _index(W / 2 - 6, H / 2)
    var red := int(ctx.data[at * 4])
    var blue := int(ctx.data[at * 4 + 2])
    _expect(blue > red + 40,
            "color bled across a brightness edge: red %d, blue %d" % [red, blue])


## Nothing to do on an image with no color in it, and it must not invent any.
func _check_gray() -> void:
    var ctx := IWPipelineContext.from_image(_gray_ramp())
    _stage(4, 1.0, 1.0).process_context(ctx)
    var worst := 0
    for i in W * H:
        var at := i * 4
        worst = maxi(worst, maxi(absi(int(ctx.data[at]) - int(ctx.data[at + 1])),
                absi(int(ctx.data[at + 1]) - int(ctx.data[at + 2]))))
    _expect(worst <= 1, "a gray image came out %d levels off gray" % worst)


# --- The reason it was built --------------------------------------------

## Smeared color is what puts background pixels outside a key's tolerance. Cleaning it
## first should leave the keyer with fewer of them to argue about.
func _check_helps_keying() -> void:
    var box := Rect2i(W / 4, H / 4, W / 2, H / 2)
    var ragged := _leftover(_keyed(false), box)
    var cleaned := _keyed(true)
    var tidy := _leftover(cleaned, box)

    print("  background left behind beside the subject: %.3f -> %.3f" % [ragged, tidy])
    _expect(tidy < ragged * 0.5, "cleaning the color first left the keyer no better off")
    _expect(IWCompose.compose(cleaned) != null, "the composed image did not survive")


## The reach has to cover the smear or the pixels worst affected only ever see each other.
## The fixture smears three pixels, so four is the smallest reach that reaches past it.
func _keyed(clean: bool) -> IWPipelineContext:
    var ctx := IWPipelineContext.from_image(_smeared_background())
    if clean:
        _stage(4, 0.6, 1.0).process_context(ctx)
    _keyer().process_context(ctx)
    return ctx


## Mean alpha of the ring of background nearest the subject.
##
## Counted rather than the edge band, which is the same size whatever the color did — the
## keyer draws one either way. Background the key could not reach shows up here as alpha
## that has no business being there.
func _leftover(ctx: IWPipelineContext, box: Rect2i) -> float:
    var alpha: PackedFloat32Array = ctx.final_alpha()
    var total := 0.0
    var count := 0
    for y in H:
        for x in W:
            if box.has_point(Vector2i(x, y)) or _distance_to(box, x, y) > 3:
                continue
            total += alpha[_index(x, y)]
            count += 1
    return total / float(maxi(count, 1))


# --- Fixtures -----------------------------------------------------------

## A flat mid gray with color noise on it and no brightness noise at all, which is the
## shape a JPEG's color error actually takes.
func _noisy_flat() -> Image:
    var image := Image.create_empty(W, H, false, Image.FORMAT_RGBA8)
    var noise := _Lcg.new(NOISE_SEED)
    for y in H:
        for x in W:
            var wobble := (float(noise.below(41)) - 20.0) / 255.0
            var other := (float(noise.below(41)) - 20.0) / 255.0
            image.set_pixel(x, y, Color(0.5 + wobble, 0.5, 0.5 + other))
    return image


## Dark blue against bright orange, split down the middle. A hard edge in brightness and
## in color at once.
func _two_halves() -> Image:
    var image := Image.create_empty(W, H, false, Image.FORMAT_RGBA8)
    for y in H:
        for x in W:
            if x < W / 2:
                image.set_pixel(x, y, Color(0.1, 0.15, 0.6))
            else:
                image.set_pixel(x, y, Color(0.95, 0.7, 0.2))
    return image


func _gray_ramp() -> Image:
    var image := Image.create_empty(W, H, false, Image.FORMAT_RGBA8)
    for y in H:
        for x in W:
            var level := float(x) / float(W - 1)
            image.set_pixel(x, y, Color(level, level, level))
    return image


## A pale ground and a solid subject, with the ground's color pulled towards the subject
## near the edge and its brightness left exactly alone.
##
## Brightness is the half a JPEG keeps at full size and gets right; only the color is
## stored small and stretched back out. A fixture that moved both would be testing
## something this stage is not for, and the ground is pale rather than white so there is
## room for the color to move without running out of range.
func _smeared_background() -> Image:
    var image := Image.create_empty(W, H, false, Image.FORMAT_RGBA8)
    var box := Rect2i(W / 4, H / 4, W / 2, H / 2)
    for y in H:
        for x in W:
            if box.has_point(Vector2i(x, y)):
                image.set_pixel(x, y, SUBJECT)
                continue
            var reach := _distance_to(box, x, y)
            if reach > 3:
                image.set_pixel(x, y, GROUND)
                continue
            image.set_pixel(x, y, _tinted(GROUND, SUBJECT, (4.0 - float(reach)) / 4.0 * 0.4))
    return image


## [param base]'s brightness carrying some of [param other]'s color.
func _tinted(base: Color, other: Color, weight: float) -> Color:
    var light := _luma_of(base)
    var cb := lerpf(_cb_of(base), _cb_of(other), weight)
    var cr := lerpf(_cr_of(base), _cr_of(other), weight)
    return Color(
        clampf(light + 1.402 * cr, 0.0, 1.0),
        clampf(light - 0.344136 * cb - 0.714136 * cr, 0.0, 1.0),
        clampf(light + 1.772 * cb, 0.0, 1.0))


func _luma_of(c: Color) -> float:
    return 0.299 * c.r + 0.587 * c.g + 0.114 * c.b


func _cb_of(c: Color) -> float:
    return -0.168736 * c.r - 0.331264 * c.g + 0.5 * c.b


func _cr_of(c: Color) -> float:
    return 0.5 * c.r - 0.418688 * c.g - 0.081312 * c.b


func _distance_to(box: Rect2i, x: int, y: int) -> int:
    var dx := maxi(maxi(box.position.x - x, x - (box.end.x - 1)), 0)
    var dy := maxi(maxi(box.position.y - y, y - (box.end.y - 1)), 0)
    return maxi(dx, dy)


# --- Helpers ------------------------------------------------------------

func _stage(radius: int, strength: float, amount: float) -> IWStackOperation:
    var stage: IWStackOperation = load(OP_SMOOTH_COLOR).new()
    var settings := stage.get_settings()
    settings.radius = radius
    settings.strength = strength
    settings.amount = amount
    return stage


## The same Remove Background the other harnesses use, so this file is not inventing a
## second opinion about what keying looks like.
func _keyer() -> IWStackOperation:
    var stage: IWStackOperation = load(OP_REMOVE_BACKGROUND).new()
    var settings := stage.get_settings()
    settings.remove_colors.clear()
    settings.remove_colors.add(GROUND, 0.05)
    settings.edge_width = 2
    settings.contiguous = true
    settings.decontaminate = true
    settings.bleed_radius = 16
    return stage


## Mean distance of each pixel's color from the image's average color, ignoring how
## bright it is. Falls as the color flattens.
func _color_spread(data: PackedByteArray) -> float:
    var mean_blue := 0.0
    var mean_red := 0.0
    for i in W * H:
        mean_blue += _blue_part(data, i)
        mean_red += _red_part(data, i)
    mean_blue /= float(W * H)
    mean_red /= float(W * H)

    var total := 0.0
    for i in W * H:
        total += absf(_blue_part(data, i) - mean_blue) + absf(_red_part(data, i) - mean_red)
    return total / float(W * H)


func _brightness(data: PackedByteArray, index: int) -> float:
    var at := index * 4
    return (0.299 * float(data[at]) + 0.587 * float(data[at + 1])
            + 0.114 * float(data[at + 2])) / 255.0


func _blue_part(data: PackedByteArray, index: int) -> float:
    var at := index * 4
    return (-0.168736 * float(data[at]) - 0.331264 * float(data[at + 1])
            + 0.5 * float(data[at + 2])) / 255.0


func _red_part(data: PackedByteArray, index: int) -> float:
    var at := index * 4
    return (0.5 * float(data[at]) - 0.418688 * float(data[at + 1])
            - 0.081312 * float(data[at + 2])) / 255.0


func _alpha_matches(a: PackedByteArray, b: PackedByteArray) -> bool:
    for i in W * H:
        if a[i * 4 + 3] != b[i * 4 + 3]:
            return false
    return true


func _index(x: int, y: int) -> int:
    return y * W + x


func _expect(condition: bool, message: String) -> bool:
    if not condition:
        printerr("FAIL: %s" % message)
        _failures += 1
    return condition


## A small generator, so the noise is the same on every machine.
class _Lcg extends RefCounted:
    var _state: int

    func _init(seed_value: int) -> void:
        _state = seed_value & 0xFFFFFFFF

    func below(limit: int) -> int:
        _state = (_state * 1664525 + 1013904223) & 0xFFFFFFFF
        return ((_state >> 16) & 0xFFFF) % limit
