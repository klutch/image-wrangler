@tool
class_name NormalNeuralSettings
extends NormalLayerSettings

## Every tunable of [NormalNeural].

## Where a model goes unless told otherwise, as a path inside the addon.
##
## Beside the rest of the addon's gitignored third-party folders, and empty in a fresh
## checkout — no model ships here. Download Latest Model is what fills it.
const MODEL_SUBDIR := "res://addons/image_wrangler/thirdparty/deepbump"


## The same folder as something that can be opened.
##
## [b]Absolute rather than [code]res://[/code].[/b] The network reads the two files through
## the C runtime rather than through Godot, so it cannot be handed a [code]res://[/code] path
## at all — and a folder shown in the dock should be one that can be pasted into a file
## browser.
static func default_model_dir() -> String:
    return ProjectSettings.globalize_path(MODEL_SUBDIR)


## How strongly the map leans. One is the network's answer untouched; lower flattens it,
## higher exaggerates it.
@export var strength: float = 1.0

## The folder holding the converted model the network runs.
##
## [b]Empty means [method default_model_dir].[/b] It is not a folder anyone chose — it is
## what a settings file written before this had a default says, and what clearing the field
## leaves behind. Both mean the same thing: put the model where the model goes.
@export var model_dir: String = default_model_dir()
