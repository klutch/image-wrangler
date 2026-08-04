@tool
class_name IWGeneratePreset
extends Resource

## One saved set of Generate settings, worn as a coloured square in the Presets group.

## Everything the tab held when it was saved. Its own preset list is always empty: a preset
## holds the job, not the library it sits in.
@export var settings: IWGenerateSettings

## The colour the square is drawn with. Picked at random when the preset is made. It only
## tells one square from another and means nothing.
@export var color: Color = Color.WHITE


## Made here rather than beside the export, because the codec fills a nested Resource in
## place and leaves a null one alone. A preset that started null would load as nothing.
func _init() -> void:
    settings = IWGenerateSettings.new()
