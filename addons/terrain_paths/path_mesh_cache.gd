class_name TerrainPathMeshCache
extends RefCounted
## ribbon mesh cache, the per-vertex grid build is slow in GDScript. play + editor, `_flats` and run uniforms still built live
## key only covers this path, its branches, end joins and the terrain regions under it
## editor runs hash terrain_path.gd's source too - exports can't, so re-run levels in the editor before exporting
## files are mesh_<path>_<id>.res next to the bakes (same dirs as TerrainPathBaker)
## env: NO_PATH_MESH_CACHE, PATH_BAKE_FRESH

const VERSION := 2
const KEY_META := "path_mesh_key"
const SRC_META := "path_mesh_src"

static var _region_keys: Dictionary = {}   # [data id, region loc] -> height-map hash
static var _region_frame := -1             # editor: only good for a frame, sculpting
static var _disk_keys: Dictionary = {}     # file -> key, skip loading known misses


static func active() -> bool:
	return not OS.has_environment("NO_PATH_MESH_CACHE")


## "" = can't cache (no level scene, or ground isn't Terrain3D)
## grid = local xz box
static func key(path: TerrainPath, data: Object, flats: Array, joins: Array, grid: Rect2) -> String:
	var root := _root(path)
	if root == null or root.scene_file_path == "" or (data != null and not (data is Terrain3DData)):
		return ""
	var g := path.global_transform
	var parts: Array = [VERSION, TerrainPathBaker._qhash([g.origin, g.basis.x, g.basis.y, g.basis.z]),
		TerrainPathBaker._qhash([path.width, path.segment_length, path.lift, path.straight_tolerance]),
		path.draw_order, path.paint, _style_key(path.style), _local_key(flats, joins),
		_terrain_key(path, data, grid)]
	return "%08x%08x" % [hash(parts) & 0xffffffff, hash(str(parts)) & 0xffffffff]


static func fetch(path: TerrainPath, k: String) -> ArrayMesh:
	if k == "" or OS.has_environment("PATH_BAKE_FRESH"):
		return null
	var root := _root(path)
	var src := _src_hash(path)
	for dir in [TerrainPathBaker._shipped_dir(root), TerrainPathBaker._cache_dir(root)]:
		var f: String = dir.path_join(_stem(path, root))
		if _disk_keys.has(f) and _disk_keys[f] != k:
			continue
		if not ResourceLoader.exists(f):
			continue
		var m := ResourceLoader.load(f, "", ResourceLoader.CACHE_MODE_IGNORE) as ArrayMesh
		if m == null:
			continue
		_disk_keys[f] = m.get_meta(KEY_META, "")
		if m.get_meta(KEY_META, "") != k:
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
	var f := dir.path_join(_stem(path, root))
	var err := ResourceSaver.save(m, f, ResourceSaver.FLAG_COMPRESS)
	if err != OK:
		push_warning("[PathMeshCache] couldn't save %s (%s)" % [path.name, error_string(err)])
	else:
		_disk_keys[f] = k


## nearest ancestor saved as a scene (runtime-built paths have no owner)
static func _root(path: TerrainPath) -> Node:
	var n := path.get_parent()
	while n != null and n.scene_file_path == "":
		n = n.get_parent()
	return n


static func _stem(path: TerrainPath, root: Node) -> String:
	return "mesh_%s_%08x.res" % [String(path.name).to_snake_case(), hash(str(root.get_path_to(path))) & 0xffffffff]


## "" in exports. presets subclass terrain_path.gd so hash the whole chain
static func _src_hash(path: TerrainPath) -> String:
	var code := ""
	var s := path.get_script() as Script
	while s != null:
		code += s.source_code
		s = s.get_base_script()
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


## own curve + branches with junction rank, plus end joins (only bit other paths feed in)
static func _local_key(flats: Array, joins: Array) -> int:
	var parts: Array = []
	for fi in flats.size():
		var c: Curve3D = flats[fi].src
		var pts := PackedVector3Array()
		for i in c.point_count:
			pts.append_array([c.get_point_position(i), c.get_point_in(i), c.get_point_out(i)])
		parts.append([TerrainPathBaker._qhash(pts), c.closed, (flats[fi].node as TerrainPath).draw_order])
		for jn in joins[fi]:
			parts.append(0 if jn == null else TerrainPathBaker._qhash([jn.p, jn.n]))
	return hash(parts)


## native hash of the height maps under the grid box (local xz), only those regions
static func _terrain_key(path: TerrainPath, data: Object, grid: Rect2) -> int:
	if data == null or not data.has_method("get_region_location"):
		return 0
	var terrain := path._terrain_node()
	var vs: float = terrain.vertex_spacing if terrain != null else 1.0
	var box := Rect2()
	var corners := [grid.position, Vector2(grid.end.x, grid.position.y), grid.end, Vector2(grid.position.x, grid.end.y)]
	for i in 4:
		var w := path.global_transform * Vector3(corners[i].x, 0.0, corners[i].y)
		box = Rect2(Vector2(w.x, w.z), Vector2.ZERO) if i == 0 else box.expand(Vector2(w.x, w.z))
	box = box.grow(vs * 2.0)   # height/normal reads near a region edge touch the next one
	if Engine.is_editor_hint() and Engine.get_process_frames() != _region_frame:
		_region_frame = Engine.get_process_frames()
		_region_keys.clear()
	var a: Vector2i = data.get_region_location(Vector3(box.position.x, 0.0, box.position.y))
	var b: Vector2i = data.get_region_location(Vector3(box.end.x, 0.0, box.end.y))
	var id := data.get_instance_id()
	var parts: Array = [vs, terrain.region_size if terrain != null else 0]
	for ry in range(mini(a.y, b.y), maxi(a.y, b.y) + 1):
		for rx in range(mini(a.x, b.x), maxi(a.x, b.x) + 1):
			var loc := Vector2i(rx, ry)
			var rk := [id, loc]
			if not _region_keys.has(rk):
				var r = data.get_region(loc) if data.has_region(loc) else null
				var hm: Image = r.get_height_map() if r != null else null
				_region_keys[rk] = hash(hm.get_data()) if hm != null else 0
			parts.append([loc, _region_keys[rk]])
	return hash(parts)
