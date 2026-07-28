@tool
class_name HSVRegionList
extends Resource

## Every region [HSVAdjust] has been given, in the order they were picked.
##
## A Resource rather than a bare Array so the sidecar codec, which reflects over stored
## properties, walks into the regions rather than storing the array's identity.

@export var regions: Array[HSVRegion] = []


func size() -> int:
    return regions.size()


func is_empty() -> bool:
    return regions.is_empty()


func get_at(index: int) -> HSVRegion:
    if index < 0 or index >= regions.size():
        return null
    return regions[index]


## Adds a region and hands it back, so the caller can select it.
##
## An empty rectangle is refused: it would be a row that could never do anything and
## could not be told apart from any other empty one.
func add(rect: Rect2i) -> HSVRegion:
    if rect.size.x <= 0 or rect.size.y <= 0:
        return null
    var region := HSVRegion.new()
    region.rect = rect
    regions.append(region)
    return region


func remove_at(index: int) -> void:
    if index >= 0 and index < regions.size():
        regions.remove_at(index)


func clear() -> void:
    regions.clear()


## Whether any region would change anything.
func has_active() -> bool:
    for region in regions:
        if region != null and region.is_active():
            return true
    return false


## A copy that belongs to no image, with regions of its own rather than shared ones.
func duplicate_for_new_image() -> HSVRegionList:
    var copy := HSVRegionList.new()
    for region in regions:
        if region != null:
            copy.regions.append(region.duplicate())
    return copy
