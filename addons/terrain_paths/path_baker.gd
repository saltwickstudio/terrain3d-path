class_name TerrainPathBaker
extends RefCounted
## bakes each path's look to textures (cached on disk) so play uses a cheap sampling shader
## instead of terrain_path.gdshader - STONES voronoi per pixel is heavy
## top-down ortho cameras in a private SubViewport world, tile by tile, two shader variants
## (colour + world normal), tiles into Texture2DArrays plus an index texture, then material_override on the path mesh
## cache key = mesh + style uniforms + live shader code + bake settings, files go in <level dir>/path_bake/ (user:// in exports)
## STONES side faces aren't baked, only tops and gaps
## play-time only, headless draws nothing
## env: NO_PATH_BAKE=1 keeps paths live, PATH_BAKE_FRESH=1 rebakes

const TILE_M := 16.0     ## metres per baked tile
const PX_PER_M := 48.0   ## 24 looked blurry up close on cobbles
const BATCH := 6         ## tiles per frame on a miss
const MESH_NAME := "TerrainPathMesh"
const LIVE_SHADER := preload("res://addons/terrain_paths/terrain_path.gdshader")
const BAKED_SHADER := preload("res://addons/terrain_paths/terrain_path_baked.gdshader")
const KEY_META := "path_bake_key"
const EXACT_META := "path_bake_exact"
const BAKE_VERSION := 1

static var _variants: Array[Shader] = []


## coroutine, fire and forget
static func bake_all(root: Node) -> void:
	if root == null or Engine.is_editor_hint() or DisplayServer.get_name() == "headless" \
			or OS.has_environment("NO_PATH_BAKE"):
		return
	if not _make_variants():
		return
	var tree := root.get_tree()
	# let queued rebuilds settle first
	for _i in 3:
		await tree.process_frame
	var paths := root.find_children("*", "TerrainPath", true, false)
	for p in paths:
		var guard := 0
		while is_instance_valid(p) and p.get("_queued") and guard < 120:
			await tree.process_frame
			guard += 1
	var dir := _cache_dir(root)
	var shipped := _shipped_dir(root)
	var t0 := Time.get_ticks_msec()
	var hits := 0
	var baked := 0
	var rig: Dictionary = {}
	for p in paths:
		if not is_instance_valid(p):
			continue
		var src := (p as Node).get_node_or_null(MESH_NAME) as MeshInstance3D
		if src == null or src.mesh == null or not src.visible or src.material_override != null:
			continue
		var mat := src.mesh.surface_get_material(0) as ShaderMaterial
		if mat == null or mat.shader != LIVE_SHADER:
			continue
		var exact := _fingerprint(src, mat, false)
		var stem := "%s_%08x.res" % [String((p as Node).name).to_snake_case(),
				hash(str(root.get_path_to(p))) & 0xffffffff]
		var file := dir.path_join(stem)
		var cached := _load_cached([shipped.path_join(stem), file], src, mat, exact)
		if cached != null:
			src.material_override = cached
			hits += 1
			continue
		if rig.is_empty():
			rig = _make_rig(root)
		var out := await _bake_one(src, mat, rig)
		if out == null:
			continue
		out.set_meta(KEY_META, _fingerprint(src, mat))
		out.set_meta(EXACT_META, exact)
		src.material_override = out
		baked += 1
		DirAccess.make_dir_recursive_absolute(dir)
		var err := ResourceSaver.save(out, file, ResourceSaver.FLAG_COMPRESS)
		if err != OK:
			push_warning("[PathBake] couldn't cache %s (error %d)" % [file, err])
	if not rig.is_empty():
		(rig.root as Node).queue_free()
	print("[PathBake] %d cached, %d baked (%s) in %d ms" % [hits, baked, dir, Time.get_ticks_msec() - t0])


## write dir - next to the scene in editor runs, user:// in exports. reads try _shipped_dir first
static func _cache_dir(root: Node) -> String:
	var scene := root.scene_file_path
	var name := scene.get_file().get_basename() if scene != "" else String(root.name).to_snake_case()
	if OS.has_feature("editor") and scene != "":
		return _shipped_dir(root)
	return "user://path_bake".path_join(name)


static func _shipped_dir(root: Node) -> String:
	var scene := root.scene_file_path
	return scene.get_base_dir().path_join("path_bake") if scene != "" else _cache_dir(root)


## exact key first, rounded one (slow, lazy) as fallback
static func _load_cached(files: Array, src: MeshInstance3D, mat: ShaderMaterial, exact: String) -> ShaderMaterial:
	if OS.has_environment("PATH_BAKE_FRESH"):
		return null
	var rounded := ""
	for f in files:
		if not ResourceLoader.exists(f):
			continue
		var m := ResourceLoader.load(f, "", ResourceLoader.CACHE_MODE_IGNORE) as ShaderMaterial
		if m == null:
			continue
		if m.get_meta(EXACT_META, "") == exact:
			return m
		if rounded == "":
			rounded = _fingerprint(src, mat)
		if m.get_meta(KEY_META, "") == rounded:
			return m
	return null


## floats get rounded (QUANT) because another machine's libm can land an ulp off and miss a shipped bake
## quant false = raw-bits key, native hash, fast. true = rounded key, ~100 ms a path. a bake stores both
static func _fingerprint(src: MeshInstance3D, mat: ShaderMaterial, quant := true) -> String:
	var arr := src.mesh.surface_get_arrays(0)
	var h := _qhash if quant else hash
	var g := src.global_transform
	var parts: Array = [BAKE_VERSION, TILE_M, PX_PER_M, _compression(), hash(LIVE_SHADER.code),
		h.call(arr[Mesh.ARRAY_VERTEX]), h.call(arr[Mesh.ARRAY_TEX_UV]), h.call(arr[Mesh.ARRAY_TEX_UV2]),
		h.call(arr[Mesh.ARRAY_CUSTOM0]), h.call(arr[Mesh.ARRAY_CUSTOM1]),
		_qhash([g.origin, g.basis.x, g.basis.y, g.basis.z])]
	for u in mat.shader.get_shader_uniform_list():
		var v = mat.get_shader_parameter(u.name)
		parts.append((v as Resource).resource_path if v is Resource else _qhash(v))
	return "%08x%08x" % [hash(parts) & 0xffffffff, hash(str(parts)) & 0xffffffff]


const QUANT := 1000.0


static func _qhash(v: Variant) -> int:
	var q := PackedInt32Array()
	_quant(v, q)
	return hash(q) if not q.is_empty() else hash(v)


static func _quant(v: Variant, out: PackedInt32Array) -> void:
	match typeof(v):
		TYPE_FLOAT:
			out.append(roundi(float(v) * QUANT))
		TYPE_INT, TYPE_BOOL:
			out.append(int(v))
		TYPE_VECTOR2, TYPE_VECTOR3, TYPE_VECTOR4, TYPE_COLOR:
			var n := 4 if typeof(v) == TYPE_VECTOR4 or typeof(v) == TYPE_COLOR else (3 if typeof(v) == TYPE_VECTOR3 else 2)
			for i in n:
				out.append(roundi(float(v[i]) * QUANT))
		TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY:
			for f in v:
				out.append(roundi(f * QUANT))
		TYPE_PACKED_VECTOR2_ARRAY, TYPE_PACKED_VECTOR3_ARRAY, TYPE_PACKED_VECTOR4_ARRAY, TYPE_PACKED_COLOR_ARRAY, TYPE_ARRAY:
			for e in v:
				_quant(e, out)


static func _compression() -> int:
	if RenderingServer.get_rendering_device() != null and RenderingServer.has_os_feature("s3tc"):
		return Image.COMPRESS_S3TC
	if RenderingServer.has_os_feature("etc2"):
		return Image.COMPRESS_ETC2
	return -1


## BATCH colour + normal viewport pairs in one World3D, mesh copies on render layer 1 (colour) and 2 (normal)
static func _make_rig(root: Node) -> Dictionary:
	var holder := Node.new()
	holder.name = "PathBake"
	var world := World3D.new()
	var px := int(TILE_M * PX_PER_M)
	var pairs: Array = []
	for i in BATCH:
		var pair: Array = []
		for layer in [1, 2]:
			var vp := SubViewport.new()
			vp.size = Vector2i(px, px)
			vp.transparent_bg = true
			vp.world_3d = world
			vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
			vp.msaa_3d = Viewport.MSAA_DISABLED
			vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
			var cam := Camera3D.new()
			cam.projection = Camera3D.PROJECTION_ORTHOGONAL
			cam.keep_aspect = Camera3D.KEEP_HEIGHT
			cam.size = TILE_M
			cam.cull_mask = layer
			cam.rotation = Vector3(-PI * 0.5, 0.0, 0.0)   # screen up = world -Z, right = +X
			vp.add_child(cam)
			holder.add_child(vp)
			cam.current = true
			pair.append(vp)
		pairs.append(pair)
	var meshes: Array = []
	for layer in [1, 2]:
		var mi := MeshInstance3D.new()
		mi.layers = layer
		(pairs[0][0] as Node).add_child(mi)   # any node in the shared world
		meshes.append(mi)
	root.add_child(holder)
	return {"root": holder, "pairs": pairs, "meshes": meshes}


## null if nothing got drawn
static func _bake_one(src: MeshInstance3D, mat: ShaderMaterial, rig: Dictionary) -> ShaderMaterial:
	var verts: PackedVector3Array = src.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var xf := src.global_transform
	var lo := Vector3(INF, INF, INF)
	var hi := -lo
	for v in verts:
		var w := xf * v
		lo = lo.min(w)
		hi = hi.max(w)
	var origin := Vector2(floorf(lo.x / TILE_M), floorf(lo.z / TILE_M)) * TILE_M
	var tiles := Vector2i(int(ceilf((hi.x - origin.x) / TILE_M)), int(ceilf((hi.z - origin.y) / TILE_M)))
	tiles = tiles.max(Vector2i.ONE)
	var cells := {}
	for v in verts:
		var w := xf * v
		cells[Vector2i(clampi(int((w.x - origin.x) / TILE_M), 0, tiles.x - 1),
				clampi(int((w.z - origin.y) / TILE_M), 0, tiles.y - 1))] = true
	for i in 2:
		var mi: MeshInstance3D = rig.meshes[i]
		var m := mat.duplicate() as ShaderMaterial
		m.shader = _variants[i]
		mi.mesh = src.mesh
		mi.transform = xf
		mi.material_override = m
	var comp := _compression()
	var albedo: Array[Image] = []
	var normal: Array[Image] = []
	var index := Image.create(tiles.x, tiles.y, false, Image.FORMAT_R8)
	var todo: Array = cells.keys()
	var pairs: Array = rig.pairs
	while not todo.is_empty():
		var batch := todo.slice(0, BATCH)
		todo = todo.slice(BATCH)
		for i in batch.size():
			var k: Vector2i = batch[i]
			for vp: SubViewport in pairs[i]:
				var cam := vp.get_child(0) as Camera3D
				cam.near = 0.05
				cam.far = hi.y - lo.y + 10.0
				cam.position = Vector3(origin.x + (k.x + 0.5) * TILE_M, hi.y + 5.0, origin.y + (k.y + 0.5) * TILE_M)
				vp.render_target_update_mode = SubViewport.UPDATE_ONCE
		await RenderingServer.frame_post_draw
		if not is_instance_valid(src):
			return null
		for i in batch.size():
			var k: Vector2i = batch[i]
			var a := (pairs[i][0] as SubViewport).get_texture().get_image()
			if a.get_used_rect().size == Vector2i.ZERO:
				continue   # mesh reaches here but nothing drawn
			var nrm := (pairs[i][1] as SubViewport).get_texture().get_image()
			a.generate_mipmaps()
			nrm.generate_mipmaps()
			if comp >= 0:
				a.compress(comp, Image.COMPRESS_SOURCE_SRGB)
				nrm.compress(comp, Image.COMPRESS_SOURCE_GENERIC)
			albedo.append(a)
			normal.append(nrm)
			index.set_pixel(k.x, k.y, Color(albedo.size() / 255.0, 0, 0))
	for mi: MeshInstance3D in rig.meshes:
		mi.mesh = null
	if albedo.is_empty():
		return null
	var at := Texture2DArray.new()
	at.create_from_images(albedo)
	var nt := Texture2DArray.new()
	nt.create_from_images(normal)
	var out := ShaderMaterial.new()
	out.shader = BAKED_SHADER
	out.render_priority = mat.render_priority
	out.set_shader_parameter("albedo_tiles", at)
	out.set_shader_parameter("normal_tiles", nt)
	out.set_shader_parameter("tile_index", ImageTexture.create_from_image(index))
	out.set_shader_parameter("origin", origin)
	out.set_shader_parameter("tile_m", TILE_M)
	out.set_shader_parameter("tiles", tiles)
	out.set_shader_parameter("depth_pull", mat.get_shader_parameter("depth_pull"))
	return out


## variants are string-swapped from the live shader so they can't drift: [0] unshaded colour, [1] world normal
## camera-distance terms and depth pull stripped, ortho has no real distance
static func _make_variants() -> bool:
	if not _variants.is_empty():
		return true
	var code := LIVE_SHADER.code
	var swaps := [
		["render_mode blend_mix, depth_draw_never, cull_disabled, diffuse_burley, specular_disabled;",
			"render_mode blend_mix, depth_draw_never, cull_disabled, unshaded;"],
		["\tvp.xyz -= (vp.xyz / max(dist, 0.001)) * (depth_pull + dist * 0.0025);\n", ""],
		["(1.0 - smoothstep(15.0, 40.0, length(VERTEX)))", "1.0"],
	]
	for s in swaps:
		if not code.contains(s[0]):
			push_warning("[PathBake] terrain_path.gdshader changed (missing %s) — paths stay live" % s[0])
			return false
		code = code.replace(s[0], s[1])
	var tail := "\tALPHA = clamp(alpha, 0.0, 1.0) * opacity * on_top;\n}"
	if not code.contains(tail):
		push_warning("[PathBake] terrain_path.gdshader changed (missing ALPHA tail) — paths stay live")
		return false
	var colour := Shader.new()
	colour.code = code
	# target is 8-bit sRGB, pre-invert so the normal lands as n * 0.5 + 0.5
	var helper := "vec3 bake_srgb_to_linear(vec3 c) {\n\treturn mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(0.04045, c));\n}\n\nvoid fragment() {"
	var ncode := code.replace("void fragment() {", helper).replace(tail,
		"\tfloat bake_a = clamp(alpha, 0.0, 1.0) * opacity * on_top;\n"
		+ "\tALBEDO = bake_srgb_to_linear(normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz) * 0.5 + 0.5);\n"
		+ "\tALPHA = step(0.002, bake_a);\n}")
	var nshader := Shader.new()
	nshader.code = ncode
	_variants = [colour, nshader]
	return true
