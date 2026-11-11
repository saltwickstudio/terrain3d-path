@tool
@icon("res://addons/terrain_paths/icons/terrain_path.svg")
class_name CobblePath
extends TerrainPath
## mossy cobbles, TEXTURE pattern


func _fill_defaults() -> void:
	style = TerrainPathStyle.cobbles()
	segment_length = 1.05
	lift = 0.0
