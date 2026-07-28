@tool
class_name _LegacyV1Settings
extends Resource

## The shape a version 1 sidecar's [code]remove_background[/code] block had, kept
## only so [method IWSettingsIO.load_stack] can decode one.
##
## The codec is reflective: it decides how to read a stored value from the type of
## the value already sitting in the target. That is what lets it handle typed arrays
## and nested Resources without anyone parsing hint strings — and it is also why an
## old file needs an old-shaped object to be read into. Reading a version 1 block
## into the split settings would silently drop every key that moved.
##
## Nothing else may use this. It is a file format frozen in amber, and the moment it
## is edited to match something it stops being able to read the files it exists for.
## The properties and their defaults are exactly those
## [code]RemoveBackgroundSettings[/code] carried before the stack split; see
## [method IWSettingsIO._stack_from_v1] for where each one went.

@export var remove_colors: RemoveColorList
@export var edge_width: int = 2
@export var contiguous: bool = true
@export var crevice_tolerance: float = 0.5
@export var crevice_reach: int = 0
@export var islands: IslandList
@export var polygons: PolygonRegionList
@export var decontaminate: bool = true
@export var bleed_radius: int = 16
@export var refine_edges: bool = false
@export var refine_radius: int = 2
@export var alpha_floor: float = 0.0
@export var alpha_ceiling: float = 1.0
@export var edge_cleanup: bool = true
@export var stroke_softness: float = 0.75
@export var auto_stroke_color: bool = false
@export var stroke_color: Color = Color(0, 0, 0, 1)
@export var inner_stroke_width: float = 0.5
@export var outer_stroke_width: float = 0.5


func _init() -> void:
	islands = IslandList.new()
	polygons = PolygonRegionList.new()
	# The white entry matters. A version 1 file old enough to predate the colour list
	# stores a single [code]key_color[/code] and [code]tolerance[/code] instead, which
	# the codec cannot see because no property of that name exists here any more — so
	# what it decodes into is whatever the default was, and the default was white.
	# Starting empty would silently leave those images keying nothing out.
	remove_colors = RemoveColorList.new()
	remove_colors.add(Color.WHITE)


## Islands used to be bare coordinates and are now entries holding a group of picks;
## a Remove Color used to be one colour and is now a group of them. A file written
## before either change still has the old shape, and the codec cannot tell that the two
## describe the same thing — so without this every island anyone had picked and every
## colour they had listed would quietly vanish.
##
## Kept here rather than only on the split settings because a version 1 file is exactly
## the kind that predates both changes.
func migrate_loaded() -> void:
	if islands != null:
		islands.migrate_legacy()
	if remove_colors != null:
		remove_colors.migrate_legacy()
