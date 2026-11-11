@tool
@icon("res://addons/terrain_paths/icons/terrain_path.svg")
class_name RoadPath
extends TerrainPath
## two-lane asphalt road with markings


func _fill_defaults() -> void:
	style = TerrainPathStyle.road()
	segment_length = 0.8
	lift = 0.0
