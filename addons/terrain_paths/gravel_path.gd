@tool
@icon("res://addons/terrain_paths/icons/terrain_path.svg")
class_name GravelPath
extends TerrainPath
## country gravel track


func _fill_defaults() -> void:
	style = TerrainPathStyle.country_gravel()
	segment_length = 0.3
	lift = 0.0
