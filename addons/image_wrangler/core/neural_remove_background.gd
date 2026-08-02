@tool
class_name NeuralRemoveBackground
extends IWStackOperation

## Removes the background by letting a trained network decide what is subject.
##
## [RemoveBackground] recovers a true fractional matte from a flat colour key, and its
## limits are about reach rather than edge quality: background enclosed by the subject is
## never flooded into, and a subject colour close to the key gets eaten. This stage fixes
## exactly those two things — the network says [i]what[/i] is subject, and the matte
## machinery that stage already uses draws the edge. The network replaces the flood, and
## nothing else.
##
## [b]The edge is still analytic.[/b] The network answers at its own resolution, so its
## boundary is a few pixels loose once stretched over the image. That does not move the
## edge: one background colour is sampled where background touches subject, the
## antialiased band is grown wide enough to contain the true edge, and inside the band
## alpha comes from colour exactly as Remove Background's does. See
## [method IWStageKernels.apply_segmentation]. [member NeuralRemoveBackgroundSettings.matte_source]
## can hand the alpha to the network's own answer instead, which survives busy backgrounds
## no single sampled colour describes, at the cost of edge sharpness and decontamination.
##
## The model behind this is IS-Net trained for general dichotomous segmentation, chosen
## over the anime-specific one after a measured sweep: it clears every sprite on a dense
## sprite sheet where that one answered nothing. Its one soft spot, also measured, is a
## single very large subject filling most of the frame. Should the network ever call
## nothing subject at all — its way of refusing a picture — the stage stands down rather
## than key the whole image out, and the Last Run readout says so.
##
## Needs a model you have downloaded or converted yourself, and takes seconds where the
## rest of the stack takes milliseconds — so the preview waits for Refresh until the
## network has run once. [b]The answer is kept[/b]: it depends on the source pixels and
## the model folder and nothing else, so dragging Threshold or Edge Width re-runs only the
## cheap half, and the second preview of the same image is instant. See [member _mask_cache].

## The colour this operation's marks are drawn in on the preview.
##
## Written out rather than worked out, and its own rather than the stack's, so it is the
## same colour every session. A unit-length colour, so no operation's marks arrive
## brighter than another's.
const TINT := Color(0.62, 0.28, 0.73)

## How many network answers are kept, each an L8 image around a megabyte. Four covers
## flicking between a couple of images without re-running anything.
const MASK_CACHE_LIMIT := 4


var settings: NeuralRemoveBackgroundSettings

## The network and its answers, [b]static on purpose[/b]: the dock's worker snapshot
## builds a brand new stage instance every run, so anything held on the instance would die
## with it. The model folder a network is open on is part of each cache key, and
## [member _open_model_dir] is what notices the folder changing between runs.
static var _network: RefCounted
static var _open_model_dir := ""
static var _mask_cache := {}
static var _mask_order: Array[String] = []


func _init() -> void:
    settings = NeuralRemoveBackgroundSettings.new()


func get_operation_name() -> String:
    return "Neural Remove Background"


func get_operation_id() -> StringName:
    return &"neural_remove_background"


func get_tint() -> Color:
    return TINT


func get_settings() -> Resource:
    return settings


func set_settings(new_settings: Resource) -> void:
    var typed := new_settings as NeuralRemoveBackgroundSettings
    if typed == null:
        push_error(
                "Image Wrangler: NeuralRemoveBackground was handed settings of the wrong type.")
        return
    settings = typed


func make_settings() -> Resource:
    return NeuralRemoveBackgroundSettings.new()


func get_output_suffix() -> String:
    return "_nobg"


## The network decides what is background; nothing needs to be keyed above it.
func needs_keying() -> bool:
    return false


## The second stage that does: the key it registers is sampled off the image rather than
## picked, but the mask everything below builds on is made here all the same.
func establishes_keying() -> bool:
    return true


## A 1024-square run of the network dwarfs everything else in the stack.
func stage_weight() -> float:
    return 3.0


## Whether this build has the network wrapper at all.
##
## False in the ordinary state of a checkout that has not run
## [code]tools/build_ncnn.py[/code]. [b]Not answered by whether a model is present[/b]:
## the folder is named on this stage's own setting, so a stage that hid itself until a
## model was found could never be given one.
static func is_offered() -> bool:
    return ClassDB.class_exists(&"IWSegNet")


## Closes the network and drops every kept answer. Called from the dock's shutdown path,
## because [code]iw_ncnn::shutdown()[/code] stands down while anything is open and static
## teardown order is not guaranteed.
static func forget() -> void:
    if _network != null:
        _network.close()
        _network = null
    _open_model_dir = ""
    _mask_cache.clear()
    _mask_order.clear()


## The wrapper, made once and held. Null in a build without ncnn.
##
## Reached by name rather than named in source, for the reason [NormalNeural] gives: a
## class this build may not have would take the whole addon down at parse time.
static func _net() -> RefCounted:
    if _network == null and is_offered():
        _network = ClassDB.instantiate(&"IWSegNet")
    return _network


## The model folder as something that can be opened, whatever was typed into it.
##
## Empty falls back to [method NeuralRemoveBackgroundSettings.default_model_dir], and a
## [code]res://[/code] path is globalised on the way out — the network reads the two files
## through the C runtime rather than through Godot.
func resolved_model_dir() -> String:
    var dir := settings.model_dir.strip_edges()
    if dir.is_empty():
        return NeuralRemoveBackgroundSettings.default_model_dir()
    return ProjectSettings.globalize_path(dir)


## True while the network would have to run from scratch for [param source].
##
## What the dock reads to decide whether the preview may follow a setting or has to wait
## for Refresh. False once the answer is in hand, so everything downstream of this stage
## goes back to being live.
func is_expensive(source: Image) -> bool:
    if source == null:
        return true
    return not _mask_cache.has(_cache_key(source.get_data(), resolved_model_dir()))


func prerequisite_note(_ctx: IWPipelineContext) -> String:
    if not is_offered():
        return "This build has no network to run. See tools/build_ncnn.py."
    var net := _net()
    if net != null and not net.has_model(resolved_model_dir()):
        return "The Model Folder holds no model yet. Download or convert one."
    return ""


func absorb_run_report(from: IWStackOperation) -> void:
    var source := from as NeuralRemoveBackground
    if source == null or source.settings == null or settings == null:
        return
    settings.last_error = source.settings.last_error
    settings.last_subject_fraction = source.settings.last_subject_fraction
    settings.has_run = source.settings.has_run


func get_settings_schema() -> Array[Dictionary]:
    return [
        {
            "property": &"threshold",
            "label": "Threshold",
            "type": SettingType.FLOAT,
            "min": 0.05,
            "max": 0.95,
            "step": 0.01,
            "tooltip": "How sure the network has to be before a pixel counts as subject.\n\nLower keeps more of the image; raise it if background survives, lower it if\nthe subject loses pieces.\n\nCheap to move: the network does not run again, its answer is re-read.",
        },
        {
            "property": &"edge_width",
            "label": "Edge Width",
            "type": SettingType.INT,
            "min": 0,
            "max": 16,
            "step": 1,
            "tooltip": "How many pixels of antialiasing to rebuild around the subject.\n2 suits ordinary antialiasing. Raise it for soft edges, glows or\ndrop shadows; set it to 0 for a hard-edged cutout.\n\nA little is always added on top: the network answers at its own resolution,\nand the band has to be wide enough to contain the true edge.",
        },
        {
            "property": &"edge_tolerance",
            "label": "Edge Tolerance",
            "type": SettingType.FLOAT,
            "min": 0.0,
            "max": 0.5,
            "step": 0.005,
            "tooltip": "Tolerance around the sampled background colour when the edge is recovered.\n\nThe background colour is sampled off the image where it touches the subject.\nRaise this when that background is speckled or gradient enough that the edge\nkeeps some of it.",
        },
        {
            "property": &"matte_source",
            "label": "Matte Source",
            "type": SettingType.ENUM,
            "options": ["Analytic", "Network Alpha"],
            "tooltip": "What writes the alpha once the network has said what is subject.\n\nAnalytic samples one background colour and recovers the edge against it, the\nway Matte Remove Background does — sharp edges, fringe removal, colour bleed.\n\nNetwork Alpha uses the network's own answer as the alpha directly. Softer\nedges and no fringe removal, but it survives busy backgrounds no single\nsampled colour describes.",
        },
        {
            "property": &"decontaminate",
            "label": "Remove Color Fringe",
            "type": SettingType.BOOL,
            "tooltip": "Un-blends the background color out of partially transparent pixels.\nThis is what stops an outline appearing once the image is composited.\n\nDoes nothing under Network Alpha, which registers no colour to un-blend.",
        },
        {
            "property": &"bleed_radius",
            "label": "Color Bleed",
            "type": SettingType.INT,
            "min": 0,
            "max": 64,
            "step": 1,
            "tooltip": "Pushes subject color into fully transparent pixels, in pixels.\nTexture filtering and mipmaps sample RGB even where alpha is zero, so\nwithout this the background can bleed back into the edge on screen.",
        },
        {
            "property": &"model_dir",
            "label": "Model Folder",
            "type": SettingType.MODEL_FOLDER,
            # What the control falls back to, and writes in, when the setting is empty.
            "default": NeuralRemoveBackgroundSettings.default_model_dir(),
            # This model's own archive, not the control's built-in one. Empty while no
            # archive is published; the button says so instead of fetching the wrong model.
            "download_url": NeuralRemoveBackgroundSettings.MODEL_URL,
            "download_bytes": NeuralRemoveBackgroundSettings.MODEL_BYTES,
            "tooltip": "The folder holding the converted segmentation model.\n\nNo model ships with this addon. Convert the DIS project's isnet-general-use\nto ncnn's format yourself and point this at the folder holding it — any\n.param with a .bin of the same name beside it will do; see the README in the\ndefault folder for the recipe.\n\nUntil then this stage is offered but makes nothing, and says why.",
        },
        {
            "property": &"threshold",
            "label": "Subject",
            "type": SettingType.READOUT,
            "text_from": &"subject_text",
            "tooltip": "How much of the image the network called subject on the last run.",
        },
        {
            "property": &"model_dir",
            "label": "Last Run",
            "type": SettingType.READOUT,
            "text_from": &"status_text",
            "tooltip": "Whether the last run made anything, and why not when it did not.",
        },
    ]


func process_context(ctx: IWPipelineContext) -> void:
    settings.last_error = ""
    settings.last_subject_fraction = -1.0
    settings.has_run = true

    # What the final write needs to know, merged the way Remove Background merges it.
    ctx.edge_width = maxi(ctx.edge_width, settings.edge_width)
    ctx.bleed_radius = maxi(ctx.bleed_radius, settings.bleed_radius)
    ctx.decontaminate = ctx.decontaminate or settings.decontaminate
    ctx.search_radius = maxi(
            maxi(ctx.bleed_radius, ctx.edge_width), IWPipelineContext.MIN_SEARCH_RADIUS)

    # Hand-set fractions, at the real boundaries. The network is nearly all of the run,
    # and there is no interruption point inside it — a cancel is noticed only afterwards.
    if not report_progress(0.02):
        return

    var probability := _probability_for(ctx)
    if probability == null:
        return
    if not report_progress(0.85):
        return

    # How many full-resolution pixels one network pixel covers, so the band is guaranteed
    # to contain the true edge however coarse the answer was.
    var slack := ceili(maxi(ctx.width, ctx.height) / 1024.0)
    if settings.matte_source == NeuralRemoveBackgroundSettings.MatteSource.NETWORK_ALPHA:
        _write_network_alpha(ctx, probability)
        report_progress(1.0)
        return

    IWStageKernels.apply_segmentation(ctx, probability, settings.threshold,
            settings.edge_tolerance, settings.edge_width + slack)
    if ctx.mask.is_empty():
        # The pass stood down: either the network called nothing subject — its way of
        # refusing a picture outside its training, and acting on it would delete the whole
        # image — or nothing background, so there is no colour to matte against. Either
        # way the image comes through untouched, and the readout says so.
        settings.last_error = "The network could not tell a subject from a background here."
        report_progress(1.0)
        return
    settings.last_subject_fraction = \
            float(ctx.mask.count(IWPipelineContext.MASK_SUBJECT)) / ctx.pixel_count
    if not report_progress(0.92):
        return

    # The drawn regions have the last word, then the maps every stage below reads.
    ctx.apply_regions_to_mask()
    ctx.rebuild_nearest()
    ctx.compute_coverage(ctx.all_indices())
    report_progress(1.0)


## The network's answer for these pixels, from the cache when it already exists.
##
## The key is a hash of the source bytes — exact, and milliseconds against seconds of
## inference — plus the model folder. Threshold and the edge settings are deliberately not
## in it: they are applied after the network, so dragging them re-runs only the cheap half.
func _probability_for(ctx: IWPipelineContext) -> Image:
    var dir := resolved_model_dir()
    var key := _cache_key(ctx.data, dir)
    if _mask_cache.has(key):
        _mask_order.erase(key)
        _mask_order.append(key)
        return _mask_cache[key]

    var net := _net()
    if net == null:
        settings.last_error = "This build has no network to run. See tools/build_ncnn.py."
        return null
    if not net.is_open() or _open_model_dir != dir:
        net.close()
        _open_model_dir = dir
        if net.open(dir) != OK:
            settings.last_error = net.get_last_error()
            return null

    var source := Image.create_from_data(
            ctx.width, ctx.height, false, Image.FORMAT_RGBA8, ctx.data)
    var mask: Image = net.segment(source)
    if mask == null:
        settings.last_error = net.get_last_error()
        return null

    _mask_cache[key] = mask
    _mask_order.append(key)
    while _mask_order.size() > MASK_CACHE_LIMIT:
        _mask_cache.erase(_mask_order.pop_front())
    return mask


static func _cache_key(data: PackedByteArray, model_dir: String) -> String:
    return "%d|%s" % [hash(data), model_dir]


## The fallback matte: the network's probability, stretched over the image, as the alpha.
##
## No key is registered and no mask is written, so this replaces whatever alpha the run
## had rather than narrowing it — the mode is for backgrounds the analytic matte cannot
## describe, not for composing. Transparent source pixels stay transparent because
## coverage is multiplied by the source's own alpha at compose.
func _write_network_alpha(ctx: IWPipelineContext, probability: Image) -> void:
    var scaled := probability.duplicate() as Image
    scaled.resize(ctx.width, ctx.height, Image.INTERPOLATE_BILINEAR)
    scaled.convert(Image.FORMAT_RF)
    ctx.coverage = scaled.get_data().to_float32_array()
    ctx.apply_regions_to_coverage()
