class_name TerrainPathMeshCache
extends RefCounted
## play-time cache of the ribbon mesh - the per-vertex grid build is slow in GDScript and paths don't change in play
## `_flats` and the shader run uniforms still get built live
## key covers this path, every path's curve (branches / junction partners), the terrain height maps
## and terrain_path.gd's source in editor runs - exports can't read source so re-run each level in the editor before exporting
## files are mesh_<path>_<id>.res next to the bakes (same dirs as TerrainPathBaker)
## env: NO_PATH_MESH_CACHE, PATH_BAKE_FRESH

const VERSION := 1
const KEY_META := "path_mesh_key"
const SRC_META := "path_mesh_src"

static var _terrain_keys: Dictionary = {}   # terrain data instance id -> height-map hash


static func active() -> bool:
	return not Engine.is_editor_hint() and not OS.has_environment("NO_PATH_MESH_CACHE")


## "" = can't cache (no level scene, or ground isn't Terrain3D)
static func key(path: TerrainPath, data: Object) -> String:
	var root := _root(path)
	if root == null or root.scene_file_path == "" or (data != null and not (data is Terrain3DData)):
		return ""
	var g := path.global_transform
	var parts: Array = [VERSION, TerrainPathBaker._qhash([g.origin, g.basis.x, g.basis.y, g.basis.z]),
		TerrainPathBaker._qhash([path.width, path.segment_length, path.lift, path.straight_tolerance]),
		path.draw_order, path.paint, _style_key(path.style), _paths_key(path.get_tree()), _terrain_key(data)]
	return "%08x%08x" % [hash(parts) & 0xffffffff, hash(str(parts)) & 0xffffffff]


static func fetch(path: TerrainPath, k: String) -> ArrayMesh:
	if k == "" or OS.has_environment("PATH_BAKE_FRESH"):
		return null
	var root := _root(path)
	var src := _src_hash(path)
	for dir in [TerrainPathBaker._shipped_dir(root), TerrainPathBaker._cache_dir(root)]:
		var f: String = dir.path_join(_stem(path, root))
		if not ResourceLoader.exists(f):
			continue
		var m := ResourceLoader.load(f, "", ResourceLoader.CACHE_MODE_IGNORE) as ArrayMesh
		if m == null or m.get_meta(KEY_META, "") != k:
			continue
		if src != "" and m.get_meta(SRC_META, "") != src:
			continue
		return m
	return null


static func store(path: TerrainPath, k: String, mesh: ArrayMesh) -> void:
	if k == "":
		return
	var root := _root(path)
	var dir := TerrainPathBaker._cache_dir(root)
	DirAccess.make_dir_recursive_absolute(dir)
	var m := mesh.duplicate() as ArrayMesh
	m.surface_set_material(0, null)
	m.set_meta(KEY_META, k)
	m.set_meta(SRC_META, _src_hash(path))
	var err := ResourceSaver.save(m, dir.path_join(_stem(path, root)), ResourceSaver.FLAG_COMPRESS)
	if err != OK:
		push_warning("[PathMeshCache] couldn't save %s (%s)" % [path.name, error_string(err)])


## nearest ancestor saved as a scene (runtime-built paths have no owner)
static func _root(path: TerrainPath) -> Node:
	var n := path.get_parent()
	while n != null and n.scene_file_path == "":
		n = n.get_parent()
	return n


static func _stem(path: TerrainPath, root: Node) -> String:
	return "mesh_%s_%08x.res" % [String(path.name).to_snake_case(), hash(str(root.get_path_to(path))) & 0xffffffff]


## "" in exports, no source there
static func _src_hash(path: TerrainPath) -> String:
	var code := (path.get_script() as Script).source_code
	return "%08x" % (hash(code) & 0xffffffff) if code != "" else ""


static func _style_key(style: TerrainPathStyle) -> int:
	if style == null:
		return 0
	var parts: Array = []
	for p in style.get_property_list():
		if p.usage & PROPERTY_USAGE_STORAGE == 0 or p.name == "script" or p.name.begins_with("resource_"):
			continue
		var v = style.get(p.name)
		parts.append((v as Resource).resource_path if v is Resource else TerrainPathBaker._qhash(v))
	return hash(parts)


static func _paths_key(tree: SceneTree) -> int:
	var parts: Array = []
	for n in tree.get_nodes_in_group(TerrainPath.GROUP):
		var p := n as TerrainPath
		var pg := p.global_transform
		var c := p.curve
		var pts := PackedVector3Array()
		if c != null:
			for i in c.point_count:
				pts.append_array([c.get_point_position(i), c.get_point_in(i), c.get_point_out(i)])
		parts.append([str(p.get_path()), TerrainPathBaker._qhash([pg.origin, pg.basis.x, pg.basis.y, pg.basis.z]),
			TerrainPathBaker._qhash(pts), c != null and c.closed, TerrainPathBaker._qhash(p.half_width()),
			p.draw_order, p.style.end_style if p.style != null else -1])
	return hash(parts)


## native hash of every active height map, once per terrain
static func _terrain_key(data: Object) -> int:
	if data == null or not data.has_method("get_regions_active"):
		return 0
	var id := data.get_instance_id()
	if _terrain_keys.has(id):
		return _terrain_keys[id]
	var parts: Array = [data.get("vertex_spacing"), data.get("region_size")]
	for r in data.get_regions_active():
		var hm: Image = r.get_height_map()
		parts.append([r.location, hash(hm.get_data()) if hm != null else 0])
	var h := hash(parts)
	_terrain_keys[id] = h
	return h
