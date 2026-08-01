@tool
class_name NormalNeural
extends IWNormalLayer

## Hands each sprite to a trained network.
##
## Needs a model you have converted and pointed at yourself, and is slow enough that the
## preview waits for Refresh rather than following a setting. Failures come back through
## [member IWNormalLayer.last_error] rather than as an empty map with no explanation, since
## this is the one layer that can fail for a reason you can do something about.

const TINT := Color(0.78, 0.55, 1.0)

var settings: NormalNeuralSettings

## The network, made once and held open across a run so a 13 MB model is not read again for
## every sheet. Null in a build without ncnn. See [method _net].
var _network: RefCounted

## Which folder [member _network] currently has open, so a changed one is noticed.
var _open_model_dir := ""


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


## Whether the layer has everything it needs to actually run.
func has_model() -> bool:
    var net := _net()
    return net != null and net.has_model(settings.model_dir)


## The wrapper, made once and held. Null in a build without ncnn.
##
## Reached by name rather than named in source, for the reason [Upscale] gives: a class this
## build may not have would take the whole addon down at parse time.
func _net() -> RefCounted:
    if _network == null and is_offered():
        _network = ClassDB.instantiate(&"IWNormalNet")
    return _network


## The model is opened once and left open — reading it again per sheet would cost more than
## the run does. A changed folder is what reopens it.
func generate(sheet: Image, rects: PackedInt32Array) -> Image:
    last_error = ""
    var net := _net()
    if net == null:
        last_error = "This build has no network to run. See tools/build_ncnn.py."
        return null

    if not net.is_open() or _open_model_dir != settings.model_dir:
        net.close()
        _open_model_dir = settings.model_dir
        if net.open(settings.model_dir) != OK:
            last_error = net.get_last_error()
            return null

    var map: Image = net.process(sheet, rects, false)
    if map == null:
        last_error = net.get_last_error()
    return map


func own_schema() -> Array[Dictionary]:
    return [
        {
            "property": &"model_dir",
            "label": "Model Folder",
            "type": SettingType.STRING,
            "tooltip": "The folder holding the converted model, as a path.\n\nNo model ships with this addon. Convert one to ncnn's format yourself and put\nthe .param and .bin in a folder, then paste the path here — any pair will do,\nsince nothing here knows what your model is called.\n\nUntil then this layer is offered but makes nothing, and says why.",
        },
    ]
