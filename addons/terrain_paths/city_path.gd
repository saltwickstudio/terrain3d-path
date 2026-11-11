@tool
@icon("res://addons/terrain_paths/icons/terrain_path.svg")
class_name CityPath
extends TerrainPath
## city paving, small setts


func _fill_defaults() -> void:
	style = TerrainPathStyle.city_paved()
	segment_length = 1.05
	lift = 0.0
