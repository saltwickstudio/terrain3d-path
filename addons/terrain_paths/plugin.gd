@tool
extends EditorPlugin
## node types are global classes so they show in Add Node with the plugin off - this only adds the snap button
## no _handles()/_edit() on purpose, a second Path3D editor crashed on a stale gizmo

var _button: Button


func _enter_tree() -> void:
	_button = Button.new()
	_button.text = "Snap Path To Terrain"
	_button.tooltip_text = "Drop every point of the selected TerrainPath(s) onto the ground."
	_button.flat = true
	_button.visible = false
	_button.pressed.connect(_on_snap)
	add_control_to_container(CONTAINER_SPATIAL_EDITOR_MENU, _button)
	get_editor_interface().get_selection().selection_changed.connect(_on_selection_changed)


func _exit_tree() -> void:
	var sel := get_editor_interface().get_selection()
	if sel.selection_changed.is_connected(_on_selection_changed):
		sel.selection_changed.disconnect(_on_selection_changed)
	remove_control_from_container(CONTAINER_SPATIAL_EDITOR_MENU, _button)
	_button.queue_free()


func _selected_paths() -> Array:
	var out: Array = []
	for n in get_editor_interface().get_selection().get_selected_nodes():
		if n is TerrainPath:
			out.append(n)
	return out


func _on_selection_changed() -> void:
	_button.visible = not _selected_paths().is_empty()


func _on_snap() -> void:
	for p in _selected_paths():
		(p as TerrainPath).snap_points_to_terrain = true
