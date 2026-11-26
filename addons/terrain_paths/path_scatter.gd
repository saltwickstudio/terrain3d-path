@tool
class_name PathScatter
extends Node3D
## lays stones along its parent TerrainPath, add as a child of one
## no tile scenes = it makes its own (see Made Stones), or give it your own path tile scenes (2 m grid)
## tiles go on a grid in path space, get split into single stones and each one is seated on the terrain separately
## so the edge is cut stone by stone
## tile bends: clashing stones skipped, gaps filled from edge_pieces then stray_pieces where they fit
## one ArrayMesh per chunk, transient, no collision

const MESH_PREFIX := "_Scatter"
const Stones := preload("res://addons/terrain_paths/path_stones.gd")
# optional func(mi) run on each built mesh, e.g. a cel shading pass
static var mesh_hook: Callable
const CHUNK_LENGTH := 16.0   # metres of path per mesh, so off-screen chunks cull

## hides the paint so terrain shows between stones (the paint is pulled toward the camera and tints them)
@export var hide_path_paint := true:
	set(v):
		hide_path_paint = v
		if _path != null:
			_path.paint = not v

## your own tile scenes for the body. leave empty and it makes its own stones (Made Stones)
@export var pieces: Array[PackedScene] = []:
	set(v):
		pieces = v
		_reload()
		notify_property_list_changed()   # swaps which group shows
## scales the stones (and tiles), 1 = default
@export_range(0.25, 4.0, 0.01) var size := 1.0:
	set(v):
		size = v
		_reload()
## half-widths from the centre line
@export_range(0.0, 1.5, 0.01) var fill := 1.0:
	set(v):
		fill = v
		_queue_rebuild()
## informal look - chance of a loose stone just outside each edge
@export_range(0.0, 1.0, 0.01) var stray_chance := 0.0:
	set(v):
		stray_chance = v
		_queue_rebuild()
@export_range(-0.2, 0.3, 0.005) var sink := 0.01:
	set(v):
		sink = v
		_queue_rebuild()
@export_range(0.0, 1.0, 0.01) var follow_slope := 1.0:
	set(v):
		follow_slope = v
		_queue_rebuild()
@export var seed := 1:
	set(v):
		seed = v
		_reload()
## rounds sharp corners on the path (m), 0 = follow it exactly
@export_range(0.0, 10.0, 0.1) var round_corners := 2.5:
	set(v):
		round_corners = v
		_queue_rebuild()

@export_group("Tiles")
# only shown once pieces has something in it
## sparse tiles for bends and outer columns
@export var edge_pieces: Array[PackedScene] = []:
	set(v):
		edge_pieces = v
		_reload()
## loose pebble tiles for bends and stray_chance
@export var stray_pieces: Array[PackedScene] = []:
	set(v):
		stray_pieces = v
		_reload()
## grid spacing at size 1. tile scenes have a margin round the stones, under 2 closes the seam
@export_range(0.25, 5.0, 0.01) var tile_spacing := 1.8:
	set(v):
		tile_spacing = v
		_queue_rebuild()
@export var random_turns := true:
	set(v):
		random_turns = v
		_queue_rebuild()
## outline scale for the clash test. 1 = edges may just touch, lower lets them overlap a bit
@export_range(0.5, 1.2, 0.01) var overlap := 0.97:
	set(v):
		overlap = v
		_queue_rebuild()
## degrees of turn per row before it counts as a bend
@export_range(1.0, 90.0, 0.5) var bend_angle := 6.0:
	set(v):
		bend_angle = v
		_queue_rebuild()
## informal look - chance an outer tile is a sparse one
@export_range(0.0, 1.0, 0.01) var edge_chance := 0.0:
	set(v):
		edge_chance = v
		_queue_rebuild()

@export_group("Made Stones")
# only shown while pieces is empty
@export_range(0.0, 0.3, 0.005) var stone_gap := 0.03:
	set(v):
		stone_gap = v
		_reload()
## m above the ground before sink
@export_range(0.01, 1.0, 0.005) var stone_height := 0.1:
	set(v):
		stone_height = v
		_reload()
@export_range(0.0, 0.2, 0.005) var height_jitter := 0.03:
	set(v):
		height_jitter = v
		_reload()
@export_range(0.0, 0.2, 0.005) var bevel := 0.04:
	set(v):
		bevel = v
		_reload()
## 0 = sharp voronoi corners
@export_range(0, 3) var roundness := 1:
	set(v):
		roundness = v
		_reload()
## 0 = a square grid, 1 = fully random
@export_range(0.0, 1.0, 0.01) var irregular := 0.7:
	set(v):
		irregular = v
		_reload()
@export var stone_colour := Color(0.54, 0.57, 0.62):
	set(v):
		stone_colour = v
		_reload()
@export_range(0.0, 0.5, 0.01) var colour_jitter := 0.08:
	set(v):
		colour_jitter = v
		_reload()

var _queued := false
var _gen := 0                 # bumps per rebuild; a stale (awaiting) rebuild bails out
var _path: TerrainPath
var _tiles := {}              # "body"/"edge"/"stray" → Array of tiles (Array of stone dicts)


const TILE_ONLY := [&"edge_pieces", &"stray_pieces", &"tile_spacing", &"random_turns", &"overlap", &"bend_angle", &"edge_chance"]
const MADE_ONLY := [&"stone_gap", &"stone_height", &"height_jitter", &"bevel", &"roundness",
		&"irregular", &"stone_colour", &"colour_jitter"]
const STONE_SIZE := 0.4   # made stone across, m, at size 1


func _stone_size() -> float:
	return STONE_SIZE * size


# hide whichever group isn't in use (still saved, just not shown)
func _validate_property(property: Dictionary) -> void:
	var hide: bool = (property.name in TILE_ONLY) if pieces.is_empty() else (property.name in MADE_ONLY)
	if hide:
		property.usage &= ~PROPERTY_USAGE_EDITOR


func _ready() -> void:
	_bind_parent()
	_queue_rebuild()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PARENTED:
		_bind_parent()
		_queue_rebuild()
	elif what == NOTIFICATION_UNPARENTED or what == NOTIFICATION_PREDELETE:
		# give the paint back
		if _path != null and is_instance_valid(_path):
			_path.paint = true
		_path = null


func _bind_parent() -> void:
	var p := get_parent() as TerrainPath
	if p == _path:
		return
	_path = p
	if _path == null:
		return
	_path.paint = not hide_path_paint
	if not _path.curve_changed.is_connected(_queue_rebuild):
		_path.curve_changed.connect(_queue_rebuild)
	if _path.curve != null and not _path.curve.changed.is_connected(_queue_rebuild):
		_path.curve.changed.connect(_queue_rebuild)
	if _path.style != null and not _path.style.changed.is_connected(_queue_rebuild):
		_path.style.changed.connect(_queue_rebuild)


func _reload() -> void:
	_tiles.clear()
	_queue_rebuild()


func _queue_rebuild() -> void:
	if _queued or not is_inside_tree():
		return
	_queued = true
	_rebuild.call_deferred()


func _clear() -> void:
	for c in get_children():
		if String(c.name).begins_with(MESH_PREFIX):
			remove_child(c)
			c.queue_free()


func _rebuild() -> void:
	_queued = false
	_gen += 1
	var gen := _gen
	# Terrain3D data isn't ready for a frame or two
	await get_tree().process_frame
	if gen != _gen or not is_inside_tree():
		return   # a newer rebuild superseded this one
	# path only builds once terrain heights are in, give it ~5s
	for k in 300:
		if _path == null or _path.is_built():
			break
		await get_tree().process_frame
		if gen != _gen or not is_inside_tree():
			return
	_clear()
	if _path == null or _path.curve == null or _path.curve.point_count < 2:
		return
	var made := pieces.is_empty()
	if _tiles.is_empty():
		_tiles = {"body": _load_tiles(pieces), "edge": _load_tiles(edge_pieces),
				"stray": _load_tiles(stray_pieces)}
		if made:
			# small stones for bends and strays, three 1 m patches
			var pebbles: Array = []
			var maker := _maker(_stone_size() * 0.6)
			for k in 3:
				var rect := Rect2(k * 5.0, 0.0, 1.0, 1.0)
				var stones: Array = maker.patch(rect)
				for st in stones:
					st.centre -= rect.get_center()
				pebbles.append(stones)
			if _tiles.edge.is_empty():
				_tiles.edge = pebbles
			if _tiles.stray.is_empty():
				_tiles.stray = pebbles
	if _tiles.body.is_empty() and not made:
		return

	var curve := _smoothed(_path.curve)
	var length := curve.get_baked_length()
	var ts := maxf(tile_spacing * size, 0.1)
	var hw := _path.half_width()
	var rows := floori(length / ts)
	if rows < 1:
		return
	var lead := (length - rows * ts) * 0.5          # centre the rows on the curve
	var half_cols := ceili((hw * maxf(fill, 1.0) + ts) / ts)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var ctx := {
		"curve": curve, "length": length, "data": _path._terrain_data(),
		"to_me": global_transform.affine_inverse(), "taken": {}, "chunks": {}, "tile_id": 0,
	}

	# body, A/B tiles on the grid
	var bend_rows: Array[int] = []
	for r in rows:
		var u := lead + (r + 0.5) * ts
		if _turn_deg(curve, u - ts * 0.5, u + ts * 0.5, length) > bend_angle:
			bend_rows.append(r)
	if made:
		_lay_made(ctx, hw)
	for r in rows:
		if made:
			break
		var u := lead + (r + 0.5) * ts
		for c in range(-half_cols, half_cols + 1):
			var w := c * ts + (ts * 0.5 if (2 * half_cols + 1) % 2 == 0 else 0.0)
			var set_name := "body"
			if absf(w) > hw - ts and rng.randf() < edge_chance and not _tiles.edge.is_empty():
				set_name = "edge"
			_lay_tile(ctx, _pick(rng, _tiles[set_name]), u, w, _turns(rng), hw * fill, rng)

	# bends, edge then stray, only stones that land in a gap
	for set_name in ["edge", "stray"]:
		if made or _tiles[set_name].is_empty():   # made stones close bends themselves
			continue
		for r in bend_rows:
			for c in range(-half_cols, half_cols + 1):
				var u := lead + (r + rng.randf()) * ts
				var w := (c + rng.randf() - 0.5) * ts
				_lay_tile(ctx, _pick(rng, _tiles[set_name]), u, w, _turns(rng), hw * fill, rng)

	# strays outside the edges
	if stray_chance > 0.0 and not _tiles.stray.is_empty():
		for r in rows:
			for side in [-1.0, 1.0]:
				if rng.randf() >= stray_chance:
					continue
				var u := lead + (r + rng.randf()) * ts
				var w: float = side * (hw * fill + ts * rng.randf_range(0.1, 0.5))
				_lay_tile(ctx, _pick(rng, _tiles.stray), u, w, _turns(rng), hw * fill + ts, rng)

	for key in ctx.chunks:
		_emit(ctx.chunks[key], "%s%d" % [MESH_PREFIX, key])


# voronoi done AFTER bending the seeds round the curve, so bends need no filler
func _lay_made(ctx: Dictionary, hw: float) -> void:
	var maker := _maker(_stone_size())
	var bucket := _stone_size() * 2.0
	var seeds := _bent_seeds(ctx, maker, hw)
	var grid := {}
	for k in seeds.size():
		var cell := Vector2i((seeds[k].xz / bucket).floor())
		if not grid.has(cell):
			grid[cell] = []
		grid[cell].append(k)

	for k in seeds.size():
		var seed_pt: Dictionary = seeds[k]
		if not seed_pt.keep:
			continue
		var cell := Vector2i((seed_pt.xz / bucket).floor())
		var neighbours := PackedVector2Array()
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				for other in grid.get(cell + Vector2i(dx, dy), []):
					if other != k:
						neighbours.append(seeds[other].xz)
		var poly := maker.cell(seed_pt.xz, neighbours)
		if poly.size() < 3:
			continue
		var st := maker.stone(poly, seed_pt.i, seed_pt.j)
		var xf: Transform3D = ctx.to_me * _seat(ctx.data, st, seed_pt.y)
		var chunk := int(seed_pt.u / CHUNK_LENGTH)
		if not ctx.chunks.has(chunk):
			ctx.chunks[chunk] = {}
		_append(ctx.chunks[chunk], st, xf)


# grid seeds mapped through the curve. extra rows past each end so end stones get neighbours
func _bent_seeds(ctx: Dictionary, maker: Stones, hw: float) -> Array[Dictionary]:
	var curve: Curve3D = ctx.curve
	var length: float = ctx.length
	var limit := hw * fill
	var wide := hw * maxf(fill, 1.0) + _stone_size() * 2.0
	var out: Array[Dictionary] = []
	for j in range(-3, ceili(length / _stone_size()) + 3):
		for i in range(floori(-wide / _stone_size()), ceili(wide / _stone_size()) + 1):
			var s := maker.seed_at(i, j)
			var u := clampf(s.y, 0.0, length)
			var fwd := _tangent(curve, u, length)
			var wp := _path.to_global(curve.sample_baked(u) + fwd * (s.y - u) + Vector3.UP.cross(fwd) * s.x)
			out.append({"xz": Vector2(wp.x, wp.z), "y": wp.y, "u": s.y, "i": i, "j": j,
					"keep": s.y >= 0.0 and s.y <= length and absf(s.x) <= limit})
	return out


# world transform for a stone on the ground. falls back to curve_y off the terrain
func _seat(data: Object, st: Dictionary, curve_y: float) -> Transform3D:
	var c: Vector2 = st.centre
	var wp := Vector3(c.x, curve_y, c.y)
	var up := Vector3.UP
	if data != null:
		var h: float = data.get_height(wp)
		if not is_nan(h):
			wp.y = h
		var nrm: Vector3 = data.get_normal(wp)
		if nrm.is_finite() and nrm.length() > 0.5:
			up = Vector3.UP.slerp(nrm.normalized(), follow_slope)
		# drawn terrain can sit a few cm above get_height, lift to the highest point under the outline
		for o in st.outline:
			var oh: float = data.get_height(Vector3(c.x + o.x, wp.y, c.y + o.y))
			if not is_nan(oh):
				var plane_y: float = wp.y - (up.x * o.x + up.z * o.y) / maxf(up.y, 0.1)
				wp.y += maxf(oh - plane_y, 0.0)
	var tilt := Basis(Quaternion(Vector3.UP, up)) if not up.is_equal_approx(Vector3.UP) else Basis()
	return Transform3D(tilt, wp - up * sink)


# clicked-in sharp corners get bezier handles (max round_corners m), hand-made handles kept
func _smoothed(src: Curve3D) -> Curve3D:
	if round_corners <= 0.0:
		return src
	var c := Curve3D.new()
	c.bake_interval = src.bake_interval
	var n := src.point_count
	for k in n:
		var p := src.get_point_position(k)
		var h_in := src.get_point_in(k)
		var h_out := src.get_point_out(k)
		if k > 0 and k < n - 1 and h_in.is_zero_approx() and h_out.is_zero_approx():
			var prev := src.get_point_position(k - 1)
			var next := src.get_point_position(k + 1)
			var dir := (next - prev).normalized()
			h_in = -dir * minf(round_corners, p.distance_to(prev) * 0.5)
			h_out = dir * minf(round_corners, p.distance_to(next) * 0.5)
		c.add_point(p, h_in, h_out)
	return c


func _maker(size: float) -> Stones:
	var m := Stones.new()
	m.size = size
	m.gap = stone_gap
	m.height = stone_height
	m.height_jitter = height_jitter
	m.bevel = bevel
	m.roundness = roundness
	m.jitter = irregular
	m.colour = stone_colour
	m.colour_jitter = colour_jitter
	m.seed = seed
	return m


func _turns(rng: RandomNumberGenerator) -> int:
	return rng.randi_range(0, 3) if random_turns else 0


func _pick(rng: RandomNumberGenerator, tiles: Array) -> Array:
	return tiles[rng.randi_range(0, tiles.size() - 1)]


## u along, w across
func _lay_tile(ctx: Dictionary, stones: Array, u: float, w: float, turn: int, limit: float,
		rng: RandomNumberGenerator) -> void:
	var curve: Curve3D = ctx.curve
	var length: float = ctx.length
	ctx.tile_id += 1
	var yaw := Basis(Vector3.UP, turn * PI * 0.5)
	var k := size
	for st in stones:
		var off: Vector3 = yaw * Vector3(st.centre.x, 0.0, st.centre.y) * k
		var su := u + off.z
		var sw := w + off.x
		if su < 0.0 or su > length or absf(sw) > limit:
			continue
		var fwd := _tangent(curve, su, length)
		var side := Vector3.UP.cross(fwd)
		var lp := curve.sample_baked(su) + side * sw
		var wp := _path.to_global(lp)
		var gf := (_path.global_basis * fwd)
		gf.y = 0.0
		gf = gf.normalized()
		var frame := Basis(Vector3.UP.cross(gf), Vector3.UP, gf)
		# footprint in world xz, shrunk by overlap
		var foot := PackedVector2Array()
		for p in st.outline:
			var q: Vector3 = frame * yaw * Vector3(p.x, 0.0, p.y) * overlap * k
			foot.append(Vector2(wp.x + q.x, wp.z + q.z))
		if _overlaps(ctx.taken, foot, ctx.tile_id):
			continue
		_take(ctx.taken, foot, ctx.tile_id)
		var up := Vector3.UP
		var data: Object = ctx.data
		if data != null:
			var h: float = data.get_height(wp)
			if not is_nan(h):
				wp.y = h
			var nrm: Vector3 = data.get_normal(wp)
			if nrm.is_finite() and nrm.length() > 0.5:
				up = Vector3.UP.slerp(nrm.normalized(), follow_slope)
		var tilt := Basis(Quaternion(Vector3.UP, up)) if not up.is_equal_approx(Vector3.UP) else Basis()
		var b: Basis = tilt * frame * yaw * Basis.from_scale(Vector3.ONE * k)
		var xf: Transform3D = ctx.to_me * Transform3D(b, wp - up * sink)
		var chunk := int(su / CHUNK_LENGTH)
		if not ctx.chunks.has(chunk):
			ctx.chunks[chunk] = {}
		_append(ctx.chunks[chunk], st, xf)


## same-tile stones never clash, only other tiles are tested
func _overlaps(taken: Dictionary, foot: PackedVector2Array, tile_id: int) -> bool:
	var seen := {}
	for cell in _cells(foot):
		for o in taken.get(cell, []):
			if o[1] == tile_id or seen.has(o):
				continue
			seen[o] = true
			if not Geometry2D.intersect_polygons(foot, o[0]).is_empty():
				return true
	return false


func _take(taken: Dictionary, foot: PackedVector2Array, tile_id: int) -> void:
	var entry := [foot, tile_id]
	for cell in _cells(foot):
		if not taken.has(cell):
			taken[cell] = []
		taken[cell].append(entry)


# 1 m grid cells the footprint's box touches
func _cells(foot: PackedVector2Array) -> Array[Vector2i]:
	var lo := foot[0]
	var hi := foot[0]
	for p in foot:
		lo = lo.min(p)
		hi = hi.max(p)
	var out: Array[Vector2i] = []
	for y in range(floori(lo.y), floori(hi.y) + 1):
		for x in range(floori(lo.x), floori(hi.x) + 1):
			out.append(Vector2i(x, y))
	return out


func _tangent(curve: Curve3D, d: float, length: float) -> Vector3:
	var t := curve.sample_baked(minf(d + 0.1, length)) - curve.sample_baked(maxf(d - 0.1, 0.0))
	t.y = 0.0
	return t.normalized() if t.length() > 1e-5 else Vector3.FORWARD


func _turn_deg(curve: Curve3D, d0: float, d1: float, length: float) -> float:
	var a := _tangent(curve, clampf(d0, 0.0, length), length)
	var b := _tangent(curve, clampf(d1, 0.0, length), length)
	return rad_to_deg(a.angle_to(b))


func _append(chunk: Dictionary, st: Dictionary, xf: Transform3D) -> void:
	var mat: Material = st.material
	if not chunk.has(mat):
		chunk[mat] = {"v": PackedVector3Array(), "n": PackedVector3Array(),
				"uv": PackedVector2Array(), "i": PackedInt32Array()}
	# packed arrays are COW - pull them out of the dict first so appends don't copy
	var acc: Dictionary = chunk[mat]
	var pv: PackedVector3Array = acc.v
	var pn: PackedVector3Array = acc.n
	var puv: PackedVector2Array = acc.uv
	var pi: PackedInt32Array = acc.i
	acc.v = null
	acc.n = null
	acc.uv = null
	acc.i = null
	var base := pv.size()
	var nb := xf.basis.inverse().transposed()
	var verts: PackedVector3Array = st.v
	var norms: PackedVector3Array = st.n
	for k in verts.size():
		pv.append(xf * verts[k])
		pn.append((nb * norms[k]).normalized())
	puv.append_array(st.uv)
	for idx in st.i:
		pi.append(base + idx)
	acc.v = pv
	acc.n = pn
	acc.uv = puv
	acc.i = pi


func _emit(chunk: Dictionary, node_name: String) -> void:
	var mesh := ArrayMesh.new()
	for mat in chunk:
		var acc: Dictionary = chunk[mat]
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = acc.v
		arrays[Mesh.ARRAY_NORMAL] = acc.n
		arrays[Mesh.ARRAY_TEX_UV] = acc.uv
		arrays[Mesh.ARRAY_INDEX] = acc.i
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		mesh.surface_set_material(mesh.get_surface_count() - 1, mat)
	var mi := MeshInstance3D.new()
	mi.name = node_name
	mi.mesh = mesh
	add_child(mi)   # no owner → transient, never saved
	if mesh_hook.is_valid():
		mesh_hook.call(mi)


## each scene becomes one tile, stones split out by connected triangles
## stone = {v, n, uv, i, centre, radius, material}
func _load_tiles(scenes: Array[PackedScene]) -> Array:
	var tiles: Array = []
	for ps in scenes:
		if ps == null:
			continue
		var inst := ps.instantiate()
		var stones: Array = []
		var mis := inst.find_children("*", "MeshInstance3D", true, false)
		if inst is MeshInstance3D:
			mis.push_front(inst)
		for mi in mis:
			var to_tile := _relative_xf(mi as MeshInstance3D, inst)
			var mesh: Mesh = (mi as MeshInstance3D).mesh
			for s in mesh.get_surface_count():
				var mat: Material = (mi as MeshInstance3D).get_active_material(s)
				stones.append_array(_split(mesh.surface_get_arrays(s), to_tile, mat))
		inst.free()
		if not stones.is_empty():
			tiles.append(stones)
	return tiles


func _relative_xf(n: Node3D, root: Node) -> Transform3D:
	var xf := Transform3D()
	var cur: Node = n
	while cur != null and cur != root:
		if cur is Node3D:
			xf = (cur as Node3D).transform * xf
		cur = cur.get_parent()
	if root is Node3D and n != root:
		xf = (root as Node3D).transform * xf
	return xf


## verts welded by position so uv / normal seams don't split a stone
func _split(arrays: Array, xf: Transform3D, mat: Material) -> Array:
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var norms: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV] if arrays[Mesh.ARRAY_TEX_UV] != null else PackedVector2Array()
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
	if idx.is_empty():
		idx.resize(verts.size())
		for k in verts.size():
			idx[k] = k
	if uvs.size() != verts.size():
		uvs.resize(verts.size())
	var nb := xf.basis.inverse().transposed()
	# union-find
	var weld := {}
	var parent := PackedInt32Array()
	parent.resize(verts.size())
	for k in verts.size():
		var key := Vector3i((verts[k] * 1000.0).round())
		if weld.has(key):
			parent[k] = weld[key]
		else:
			weld[key] = k
			parent[k] = k
	for t in range(0, idx.size(), 3):
		var a := _find(parent, idx[t])
		for j in range(1, 3):
			var b := _find(parent, idx[t + j])
			if a != b:
				parent[b] = a
	var groups := {}
	for t in range(0, idx.size(), 3):
		var g := _find(parent, idx[t])
		if not groups.has(g):
			groups[g] = []
		groups[g].append_array([idx[t], idx[t + 1], idx[t + 2]])
	var out: Array = []
	for g in groups:
		var tri: Array = groups[g]
		var remap := {}
		var v := PackedVector3Array()
		var n := PackedVector3Array()
		var uv := PackedVector2Array()
		var ii := PackedInt32Array()
		for k in tri:
			if not remap.has(k):
				remap[k] = v.size()
				v.append(xf * verts[k])
				n.append((nb * norms[k]).normalized() if k < norms.size() else Vector3.UP)
				uv.append(uvs[k])
			ii.append(remap[k])
		var c := Vector2.ZERO
		for p in v:
			c += Vector2(p.x, p.z)
		c /= float(v.size())
		var r := 0.0
		for k in v.size():
			v[k] -= Vector3(c.x, 0.0, c.y)
			r += Vector2(v[k].x, v[k].z).length()
		r /= float(v.size())   # mean, max overstates irregular stones
		var flat := PackedVector2Array()
		for p in v:
			flat.append(Vector2(p.x, p.z))
		out.append({"v": v, "n": n, "uv": uv, "i": ii, "centre": c, "radius": r, "material": mat,
				"outline": Geometry2D.convex_hull(flat)})
	return out


func _find(parent: PackedInt32Array, k: int) -> int:
	while parent[k] != k:
		parent[k] = parent[parent[k]]
		k = parent[k]
	return k
