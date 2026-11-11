@tool
@icon("res://addons/terrain_paths/icons/terrain_path.svg")
class_name CitySlabPath
extends TerrainPath
## city paving, big slabs


func _fill_defaults() -> void:
	style = TerrainPathStyle.city_slabs()
	lift = 0.0
