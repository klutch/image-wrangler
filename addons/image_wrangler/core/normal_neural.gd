@tool
class_name NormalNeural
extends IWNormalLayer

## Hands each sprite to a trained network.
##
## Needs a model you have converted and pointed at yourself, and takes seconds where the
## other three take milliseconds. Failures come back through
## [member IWNormalLayer.last_error] rather than as an empty map with no explanation, since
## this is the one layer that can fail for a reason you can do something about.
##
## [b]The map it makes is kept and handed back again.[/b] Nothing below this layer in the
## stack changes what the network would say — the sheet is the only thing it reads — so
## dragging a Round Edges slider under it must not cost another pass. The map is worked out
## once per sheet and reused until the sheet, the rectangles or the model folder move. See
## [method generate] and [method is_expensive].

const TINT := Color(0.78, 0.55, 1.0)

var settings: NormalNeuralSettings

## The network, made once and held open across a run so a 13 MB model is not read again for
## every sheet. Null in a build without ncnn. See [method _net].
var _network: RefCounted

## Which folder [member _network] currently has open, so a changed one is noticed.
var _open_model_dir := ""

## The map the last run made, and what it was made from.
##
## [b]The sheet is held rather than named.[/b] Two sheets are the same sheet when they are
## the same object, and holding the reference is what makes that test sound — an Image let
## go of can have its identity handed to the next one allocated, and a map from the wrong
## sheet is worse than a slow one. It costs the memory of one sheet, which is the same order
## as the map beside it.
var _made: Image
var _made_from: Image
var _made_rects := PackedInt32Array()
var _made_dir := ""

## [member _made] with a strength applied, kept so dragging the slider costs one combine
## pass rather than a run of the network.
var _tuned: Image
var _tuned_strength := 1.0


func _init() -> void:
    settings = NormalNeuralSettings.new()


func get_operation_name() -> String:
    return "Neural"


func get_operation_id() -> StringName:
    return &"normal_neural"


func get_description() -> String:
    return "Hands each sprite to a trained network. Needs a model you have converted and pointed at yourself, and is slow enough that the preview waits for Refresh."


func get_tint() -> Color:
    return TINT


func get_settings() -> Resource:
    return settings


func set_settings(new_settings: Resource) -> void:
    var typed := new_settings as NormalNeuralSettings
    if typed == null:
        push_error("Image Wrangler: NormalNeural was handed settings of the wrong type.")
        return
    settings = typed


func make_settings() -> Resource:
    return NormalNeuralSettings.new()


## Whether this build has the network wrapper at all.
##
## False in the ordinary state of a checkout that has not run
## [code]tools/build_ncnn.py[/code], and the dock drops the layer from the dropdown when it
## is. [b]Not answered by whether a model is present[/b]: the folder is named on this
## layer's own setting, so a layer that hid itself until a model was found could never be
## given one.
static func is_offered() -> bool:
    return ClassDB.class_exists(&"IWNormalNet")


## The model folder as something that can be opened, whatever was typed into it.
##
## Empty falls back to [method NormalNeuralSettings.default_model_dir] rather than to nothing:
## a settings file written before this setting had a default carries an empty one, and the
## folder it meant is the one the model goes in.
##
## [b]Globalised on the way out rather than on the way in.[/b] The network reads the two files
## through the C runtime rather than through Godot, so it cannot be handed a
## [code]res://[/code] path at all. An absolute one comes back unchanged.
func resolved_model_dir() -> String:
    var dir := settings.model_dir.strip_edges()
    if dir.is_empty():
        return NormalNeuralSettings.default_model_dir()
    return ProjectSettings.globalize_path(dir)


## Whether the layer has everything it needs to actually run.
func has_model() -> bool:
    var net := _net()
    return net != null and net.has_model(resolved_model_dir())


## The wrapper, made once and held. Null in a build without ncnn.
##
## Reached by name rather than named in source, for the reason [Upscale] gives: a class this
## build may not have would take the whole addon down at parse time.
func _net() -> RefCounted:
    if _network == null and is_offered():
        _network = ClassDB.instantiate(&"IWNormalNet")
    return _network


## Whether the map this layer has in hand still describes [param sheet].
##
## The network reads the sheet and nothing else, so those three are the whole of what could
## make its answer wrong. A layer added, removed, reordered or retuned below this one does
## not appear here, which is the point.
func can_reuse(sheet: Image, rects: PackedInt32Array) -> bool:
    return _made != null and _made_from == sheet and _made_rects == rects \
            and _made_dir == resolved_model_dir()


## True while the map would have to be worked out from scratch.
##
## What the dock reads to decide whether the preview may follow a setting or has to wait for
## Refresh. False once there is a map to hand back, so everything downstream of this layer
## goes back to being live.
func is_expensive(sheet: Image, rects: PackedInt32Array) -> bool:
    return not can_reuse(sheet, rects)


## The model is opened once and left open — reading it again per sheet would cost more than
## the run does. A changed folder is what reopens it.
##
## The map from the last run is handed straight back when it still describes the sheet; see
## the class note.
func generate(sheet: Image, rects: PackedInt32Array) -> Image:
    last_error = ""
    if can_reuse(sheet, rects):
        return _with_strength()

    var net := _net()
    if net == null:
        last_error = "This build has no network to run. See tools/build_ncnn.py."
        return null

    var dir := resolved_model_dir()
    if not net.is_open() or _open_model_dir != dir:
        net.close()
        _open_model_dir = dir
        if net.open(dir) != OK:
            last_error = net.get_last_error()
            return null

    var map: Image = net.process(sheet, rects, false)
    if map == null:
        last_error = net.get_last_error()
        # What was made before is deliberately kept rather than thrown away. A folder typed
        # wrong and then typed right again matches it once more, and the network does not
        # have to run a second time to arrive back where it already was.
        return null

    _made = map
    _made_from = sheet
    _made_rects = rects
    _made_dir = dir
    _tuned = null
    return _with_strength()


## The raw map scaled by [member NormalNeuralSettings.strength]. At one it comes back
## untouched.
##
## Scaled by slope-combining the map with itself at strength minus one: its own slope plus
## that much of it again is the slope times the strength. Combining takes alpha from the
## base, and here the base is the map itself, so transparency comes through untouched.
func _with_strength() -> Image:
    var strength := settings.strength
    if is_equal_approx(strength, 1.0):
        return _made
    if _tuned != null and is_equal_approx(_tuned_strength, strength):
        return _tuned
    _tuned = IWStageKernels.combine_normals(_made, _made, _made_rects, CombineMode.SLOPE,
            strength - 1.0)
    _tuned_strength = strength
    return _tuned


func own_schema() -> Array[Dictionary]:
    return [
        {
            "property": &"strength",
            "label": "Strength",
            "type": SettingType.FLOAT,
            "min": 0.0,
            "max": 3.0,
            "step": 0.01,
            "tooltip": "How strongly the map leans.\n\nAt one the network's answer comes through untouched. Below one flattens it\ntowards facing straight up; above one exaggerates it.\n\nCheap to move: the network does not run again, the map it already made is\nrescaled.",
        },
        {
            "property": &"model_dir",
            "label": "Model Folder",
            "type": SettingType.MODEL_FOLDER,
            # What the control falls back to, and writes in, when the setting is empty. See
            # NormalNeuralSettings.model_dir.
            "default": NormalNeuralSettings.default_model_dir(),
            "tooltip": "The folder holding the converted model.\n\nNo model ships with this addon. Download Latest Model fetches one into this\nfolder; otherwise convert one to ncnn's format yourself and point this at the\nfolder holding it — any .param with a .bin of the same name beside it will do,\nsince nothing here knows what your model is called.\n\nUntil then this layer is offered but makes nothing, and says why.",
        },
    ]
