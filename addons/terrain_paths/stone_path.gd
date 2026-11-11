@tool
@icon("res://addons/terrain_paths/icons/terrain_path.svg")
class_name StonePath
extends TerrainPath
## flat slate stones, terrain shows through the gaps


func _fill_defaults() -> void:
	style = TerrainPathStyle.stones()
	segment_length = 1.05
	lift = 0.0
