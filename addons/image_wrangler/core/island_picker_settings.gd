@tool
class_name IslandPickerSettings
extends Resource

## Every tunable of [IslandPickerOp].

## What a fresh Island Picker asks for.
##
## The same number [RemoveBackground] starts at, so an Island Picker standing on its own
## cuts to the same depth as one sitting under a Remove Background.
const DEFAULT_EDGE_WIDTH := 2

## Regions picked off the preview, each removed or protected on its own terms.
##
## Each island keys out the colour of the pixel it lands on, sampled at process time
## rather than stored, so an island always removes exactly what was clicked and can
## never disagree with the image.
##
## These describe one particular image harder than almost anything else here does:
## every other setting is a number that would at least mean something applied to a
## different image, where a coordinate simply would not.
@export var islands: IslandList

## How many pixels of antialiasing to rebuild around what a Subtract island opens.
##
## Offered to the run rather than owned by it: the widest any stage asks for is what
## every edge in the image gets.
@export var edge_width: int = DEFAULT_EDGE_WIDTH


func _init() -> void:
    islands = IslandList.new()


## A copy that belongs to no image: the list starts empty, since the image its
## points were placed in is gone.
func duplicate_for_new_image() -> IslandPickerSettings:
    var copy: IslandPickerSettings = duplicate()
    copy.islands = IslandList.new()
    return copy


## Called by [method IWSettingsIO.load_settings] once a sidecar has been decoded.
##
## Islands used to be bare coordinates and are now entries carrying a switch and a
## mode. A file written before that change still has the old array, and the codec
## cannot tell that the two describe the same thing — so without this every island
## anyone had picked would quietly vanish the first time they reopened an image.
func migrate_loaded() -> void:
    if islands != null:
        islands.migrate_legacy()
