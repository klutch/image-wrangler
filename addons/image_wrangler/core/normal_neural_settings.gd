@tool
class_name NormalNeuralSettings
extends NormalLayerSettings

## Every tunable of [NormalNeural].

## The folder holding the converted model the network runs, as a path.
##
## No model ships with this addon, so this is empty until you convert one and say where it
## went. The layer is offered anyway, and says what it is missing.
@export var model_dir: String = ""
