@tool
@icon("res://addons/terrain_paths/icons/terrain_path.svg")
class_name WoodlandPath
extends TerrainPath
## woodland mud trail


func _fill_defaults() -> void:
	style = TerrainPathStyle.woodland_mud()
	segment_length = 0.85
	lift = 0.0
