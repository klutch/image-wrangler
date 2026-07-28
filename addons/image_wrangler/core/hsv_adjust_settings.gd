@tool
class_name HSVAdjustSettings
extends Resource

## Every tunable of [HSVAdjust].
##
## One list, because every adjustment belongs to a region rather than to the stage. A
## setting here would apply to the whole image, which is what the region list exists to
## avoid.

@export var regions: HSVRegionList = HSVRegionList.new()


## A copy that belongs to no image, with regions of its own rather than shared ones.
func duplicate_for_new_image() -> HSVAdjustSettings:
    var copy := HSVAdjustSettings.new()
    if regions != null:
        copy.regions = regions.duplicate_for_new_image()
    return copy


## Rebuilds the list when a sidecar left it null, which a file written before this
## operation existed would.
func migrate_loaded() -> void:
    if regions == null:
        regions = HSVRegionList.new()
