@tool
class_name BrushEditSettings
extends Resource

## Every tunable of [BrushEdit].
##
## Ranges live in [method BrushEdit.get_settings_schema] and on [BrushStroke], not here.

## Strokes painted over the preview by hand. See [BrushStroke].
##
## Coordinates, and just as meaningless applied to another image as a drawn polygon is,
## which is why [method duplicate_for_new_image] does not carry them over.
@export var strokes: BrushStrokeList

## What the next stroke is drawn at, rather than anything about the ones already down.
##
## Held on the settings so it is saved with the image and the brush is where it was left
## on coming back to it. Each stroke captures these when it starts and keeps its own copy,
## so turning the brush up for one stroke does not go back and widen the last twenty.
@export var brush_radius: int = 8
@export var brush_sharpness: float = 1.0


func _init() -> void:
    strokes = BrushStrokeList.new()


## A copy that belongs to no image: the list starts empty, since the image its strokes
## were painted over is gone. The brush itself carries over, being a preference rather
## than a coordinate.
func duplicate_for_new_image() -> BrushEditSettings:
    var copy: BrushEditSettings = duplicate()
    copy.strokes = BrushStrokeList.new()
    return copy
