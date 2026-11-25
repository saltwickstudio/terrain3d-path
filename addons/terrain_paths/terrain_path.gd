@tool
@icon("res://addons/terrain_paths/icons/terrain_path.svg")
class_name TerrainPath
extends Path3D
## paints a path/road onto Terrain3D along this curve, look comes from `style` (presets/ has a few)
## visual only, no collision
##
## child TerrainPaths become branches, baked into the parent's mesh with the parent's style/width

const MESH_NAME := "TerrainPathMesh"
const GROUP := "terrain_paths"
const MAX_GRID_VERTS := 80000   # grid coarsens past this
const SHADER := preload("res://addons/terrain_paths/terrain_path.gdshader")
const MAX_RUNS := 128           # same as the shader arrays
# sits under the default (0) transparents so water/decals draw over paths
const DRAW_ORDER_BASE := -120
const JOIN_TOLERANCE := 0.6     # m, xz

## edit a shared .tres to restyle every path using it
@export var style: TerrainPathStyle:
	set(v):
		if style != null and style.changed.is_connected(_on_style_changed):
			style.changed.disconnect(_on_style_changed)
		style = v
		if style != null:
			style.changed.connect(_on_style_changed)
		_queue_rebuild()
## metres, 0 = style default
@export_range(0.0, 20.0, 0.1) var width := 0.0:
	set(v):
		width = v
		_queue_rebuild()
## metres per vertex, ignored on Terrain3D (grid locks to its vertices)
@export_range(0.1, 2.0, 0.05) var segment_length := 0.4:
	set(v):
		segment_length = maxf(v, 0.1)   # 0 from a bad save = very slow grid
		_queue_rebuild()
@export var lift := 0.03:
	set(v):
		lift = v
		_queue_rebuild()
## max deviation (m) when splitting the curve into straight paving runs
@export_range(0.01, 1.0, 0.01) var straight_tolerance := 0.12:
	set(v):
		straight_tolerance = maxf(v, 0.01)
		_queue_rebuild()
## higher draws on top, on a branch it's junction priority instead
@export_range(-50, 50) var draw_order := 0:
	set(v):
		draw_order = v
		_queue_restack()
		if is_branch():
			_queue_rebuild()   # it ranks the branch at junctions (see _outranks)

## off = still there for surface_at / scatter, just not drawn
@export var paint := true:
	set(v):
		paint = v
		if _mi != null:
			_mi.visible = v

## one-shot, resets itself
@export var snap_points_to_terrain := false:
	set(v):
		snap_points_to_terrain = false
		if v and is_inside_tree():
			_snap_points()

var _mi: MeshInstance3D
var _mat: ShaderMaterial
var _queued := false
# flattened curves from the last rebuild, one per curve in the mesh (own + branches)
var _flats: Array = []
var _hw := 1.0
var _draw_rank := 0
var _join_partners: Array = []
var _join_partners_new: Array = []
var _partner_triggered := false
var _seen_points := PackedVector3Array()
var _seating := false
# editor: last build's footprint + area still to report to reshaped_hook
var _foot := Rect2()
var _dirty := Rect2()
var _dirty_ticket := 0
var _store_ticket := 0

const RESHAPE_SETTLE := 0.35   # seconds of no edits before reshaped_hook fires
const STORE_SETTLE := 1.0
static var _restack_queued := false
# no Terrain3D in the scene? func(node) -> anything with get_height / get_normal
# (and sample() -> {height, edge} to cut at its edges). unset = nothing
static var ground_fallback: Callable
# editor only, func(path, area: Rect2, first_build: bool) - area is world xz
# first build fires straight away, edits after RESHAPE_SETTLE of quiet. unset = nothing
static var reshaped_hook: Callable


func _ready() -> void:
	# not in _init(), Add Node drops what that sets
	if style == null:
		_fill_defaults()
	add_to_group(GROUP)
	if curve != null and not curve.changed.is_connected(_on_curve_edited):
		curve.changed.connect(_on_curve_edited)
	_seen_points = _curve_points()
	if not curve_changed.is_connected(_on_curve_swapped):
		curve_changed.connect(_on_curve_swapped)
	set_notify_transform(Engine.is_editor_hint())
	# deferred so Terrain3D has its data loaded
	_queue_rebuild()
	_queue_restack()


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSFORM_CHANGED and Engine.is_editor_hint():
		_queue_rebuild()
	if what == NOTIFICATION_MOVED_IN_PARENT or what == NOTIFICATION_ENTER_TREE:
		_queue_restack()
	if what == NOTIFICATION_ENTER_TREE:
		_queue_rebuild()
	elif what == NOTIFICATION_EXIT_TREE and is_branch():
		_root_path()._queue_rebuild()


## true when the parent is another TerrainPath
func is_branch() -> bool:
	return get_parent() is TerrainPath


func _root_path() -> TerrainPath:
	var r: TerrainPath = self
	while r.get_parent() is TerrainPath:
		r = r.get_parent()
	return r


func _branches() -> Array:
	var out: Array = []
	for c in get_children():
		if c is TerrainPath:
			out.append(c)
			out.append_array((c as TerrainPath)._branches())
	return out


func _queue_restack() -> void:
	if _restack_queued or not is_inside_tree():
		return
	_restack_queued = true
	_restack.call_deferred()


## render_priority from draw_order then tree order, stops overlaps flickering
func _restack() -> void:
	_restack_queued = false
	if not is_inside_tree():
		return
	var paths := get_tree().get_nodes_in_group(GROUP)
	paths.sort_custom(func(a: Node, b: Node) -> bool:
		var oa: int = a.draw_order if a is TerrainPath else 0
		var ob: int = b.draw_order if b is TerrainPath else 0
		if oa != ob:
			return oa < ob
		return a.is_greater_than(b))
	var n := paths.size()
	for i in n:
		var p := paths[i] as TerrainPath
		if p != null:
			p._draw_rank = i
			if p._mat != null:
				p._mat.render_priority = clampi(DRAW_ORDER_BASE + p._draw_rank, -128, 127)


## presets override this
func _fill_defaults() -> void:
	pass


## Path3D fires curve_changed on edits too, not just on swap
func _on_curve_swapped() -> void:
	if curve != null and not curve.changed.is_connected(_on_curve_edited):
		curve.changed.connect(_on_curve_edited)
		_seen_points = _curve_points()
	_queue_rebuild()


func _on_curve_edited() -> void:
	if Engine.is_editor_hint() and not _seating:
		_seat_points()
	_queue_rebuild()


func _curve_points() -> PackedVector3Array:
	var out := PackedVector3Array()
	if curve != null:
		for i in curve.point_count:
			out.append(curve.get_point_position(i))
	return out


## Terrain3D has no editor collision, so the Path tool drops clicked points way off.
## re-cast new/moved points along the camera ray onto the terrain
func _seat_points() -> void:
	var prev := _seen_points
	_seen_points = _curve_points()
	if curve == null or curve.point_count == 0 or not is_inside_tree():
		return
	# only when this path is selected
	var ei := Engine.get_singleton("EditorInterface")
	if ei == null or not ei.get_selection().get_selected_nodes().has(self):
		return
	var data = _terrain_data()
	var cam := _editor_camera()
	if data == null or cam == null:
		return
	_seating = true
	for i in curve.point_count:
		var p := curve.get_point_position(i)
		if prev.has(p):
			continue   # untouched
		var hit = _terrain_hit(cam, data, to_global(p))
		if hit != null:
			curve.set_point_position(i, to_local(hit))
	_seating = false
	_seen_points = _curve_points()


## viewport under the mouse, else the first with a camera
func _editor_camera() -> Camera3D:
	var ei := Engine.get_singleton("EditorInterface")
	if ei == null:
		return null
	var fallback: Camera3D = null
	for i in 4:
		var vp: SubViewport = ei.get_editor_viewport_3d(i)
		if vp == null or vp.get_camera_3d() == null:
			continue
		var box := vp.get_parent() as Control
		if box != null and box.is_visible_in_tree() \
				and box.get_global_rect().has_point(box.get_global_mouse_position()):
			return vp.get_camera_3d()
		if fallback == null:
			fallback = vp.get_camera_3d()
	return fallback


## null if already on the ground, behind the camera or a miss
static func _terrain_hit(cam: Camera3D, data: Object, wp: Vector3) -> Variant:
	var h: float = data.get_height(wp)
	if not is_nan(h) and absf(wp.y - h) < 0.05:
		return null
	if cam.is_position_behind(wp):
		return null
	var sp := cam.unproject_position(wp)
	var from := cam.project_ray_origin(sp)
	var dir := cam.project_ray_normal(sp)
	var far := minf(cam.far, 4000.0)
	var step := 0.5
	var t := 0.0
	var last := -1.0
	while t < far:
		var q := from + dir * t
		var qh: float = data.get_height(q)
		if not is_nan(qh) and q.y <= qh:
			if last < 0.0:
				return null   # camera under the ground
			var a := last
			var b := t
			for k in 16:
				var m := (a + b) * 0.5
				var mq := from + dir * m
				var mh: float = data.get_height(mq)
				if not is_nan(mh) and mq.y <= mh:
					b = m
				else:
					a = m
			var r := from + dir * b
			var rh: float = data.get_height(r)
			return Vector3(r.x, rh if not is_nan(rh) else r.y, r.z)
		last = t
		t += step
	return null


func _on_style_changed() -> void:
	if _mat != null and style != null:
		style.apply_to(_mat)
	_queue_rebuild()


func _world_footprint(flats: Array, radius: float) -> Rect2:
	var out := Rect2()
	var first := true
	for f in flats:
		var r: Rect2 = f.rect
		for c in [r.position, r.position + Vector2(r.size.x, 0.0), r.end, r.position + Vector2(0.0, r.size.y)]:
			var w := global_transform * Vector3(c.x, 0.0, c.y)
			var p := Vector2(w.x, w.z)
			out = Rect2(p, Vector2.ZERO) if first else out.expand(p)
			first = false
	return out.grow(radius + 1.0)


func _report_reshape(ticket: int) -> void:
	if ticket != _dirty_ticket or not is_inside_tree():
		return
	var dirty := _dirty
	_dirty = Rect2()
	if reshaped_hook.is_valid():
		reshaped_hook.call(self, dirty, false)


func _queue_rebuild() -> void:
	if not is_inside_tree():
		return
	if is_branch():
		_root_path()._queue_rebuild()
		if _mi != null or has_node(MESH_NAME):
			_drop_mesh.call_deferred()
		return
	if _queued:
		return
	_queued = true
	_rebuild.call_deferred()


## surface_tag under a world position, "" if off every path (footsteps etc.)
## deepest path wins, wobble/feather ignored
static func surface_at(tree: SceneTree, world_pos: Vector3) -> String:
	if tree == null:
		return ""
	var best := ""
	var best_d := 1.0
	for n in tree.get_nodes_in_group(GROUP):
		var p := n as TerrainPath
		if p == null or p.style == null or p.style.surface_tag == "":
			continue
		var d := p.edge_distance(world_pos)
		if d <= best_d:
			best_d = d
			best = p.style.surface_tag
	return best


## true once edge_distance can answer, or never will (branch, no curve)
func is_built() -> bool:
	return is_branch() or not _flats.is_empty() or not is_inside_tree() \
			or curve == null or curve.point_count < 2 or curve.get_baked_length() <= 0.01


## distance from the centre line in half-widths (<= 1 is on the path), INF before the
## first build or past a square/feathered end. `limit` lets far results come back INF
func edge_distance(world_pos: Vector3, limit := INF) -> float:
	if _flats.is_empty() or not is_inside_tree():
		return INF
	var lp := to_local(world_pos)
	lp.y = 0.0
	var square := style != null and style.end_style != TerrainPathStyle.EndStyle.ROUND
	var best := INF
	var lxz := Vector2(lp.x, lp.z)
	for f in _flats:
		if limit < INF and not (f.rect as Rect2).grow(limit * _hw).has_point(lxz):
			continue
		var flat: Curve3D = f.flat
		var flen: float = f.len
		var off := flat.get_closest_offset(lp)
		var to_p := lp - flat.sample_baked(off)
		if square and not f.closed:
			var t := _flat_tangent(flat, off, flen)
			var along := off + to_p.dot(t)
			if along < 0.0 or along > flen:
				continue
		best = minf(best, to_p.length() / _hw)
	return best


func half_width() -> float:
	var w := width if width > 0.0 else (style.default_width if style != null else 2.0)
	return maxf(w * 0.5, 0.05)


func _drop_mesh() -> void:
	var old := get_node_or_null(MESH_NAME)
	if old != null:
		old.queue_free()
	_mi = null
	_flats.clear()


func _rebuild() -> void:
	_queued = false
	if not is_inside_tree():
		return
	if is_branch():
		_drop_mesh()
		return
	if _mi == null:
		_mi = get_node_or_null(MESH_NAME) as MeshInstance3D
	if _mi == null:
		_mi = MeshInstance3D.new()
		_mi.name = MESH_NAME
		_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(_mi)
	_mi.visible = paint
	if _mat == null:
		_mat = ShaderMaterial.new()
		_mat.shader = SHADER
		_mat.render_priority = clampi(DRAW_ORDER_BASE + _draw_rank, -128, 127)
	if style != null:
		style.apply_to(_mat)
	if curve == null or curve.point_count < 2 or curve.get_baked_length() <= 0.01:
		_mi.mesh = null
		return

	var hw := half_width()
	var closed := curve.closed
	var wob := style.wobble if style != null else 0.2
	var fea := style.feather if style != null else 0.25
	var hard := style.edge_hardness if style != null else 0.6
	# how far out the mesh has to reach, mirrors fade_width / edge_fade / fringe_noise in the shader
	var soft := maxf(fea * 10.0 * (1.0 - 0.85 * hard), 0.015)
	var rim := style.rim_width if style != null else 0.2
	var reach := (1.0 + soft * 0.7 + rim + (0.08 + soft * 0.15) * 0.5) * (1.0 + wob) + 0.15
	var radius := reach * hw                     # metres
	# stones keep whole stones with their centre inside the edge
	if style != null and style.pattern == TerrainPathStyle.Pattern.STONES:
		radius += style.pattern_scale * (1.0 + style.ragged)
	# end_taper > 1 flares past the footprint
	if style != null and style.end_style == TerrainPathStyle.EndStyle.FEATHERED:
		radius *= maxf(style.end_taper, 1.0)

	# own curve + branches in local space, each flattened (y = 0) so distance is on the ground plane
	var srcs: Array = [curve]
	var src_nodes: Array = [self]
	for b in _branches():
		var bc := (b as TerrainPath).curve
		if bc == null or bc.point_count < 2:
			continue
		var xf := global_transform.affine_inverse() * (b as TerrainPath).global_transform
		var lc := Curve3D.new()
		lc.bake_interval = curve.bake_interval
		for i in bc.point_count:
			lc.add_point(xf * bc.get_point_position(i), xf.basis * bc.get_point_in(i), xf.basis * bc.get_point_out(i))
		lc.closed = bc.closed
		srcs.append(lc)
		src_nodes.append(b)
	var was_built := not _flats.is_empty()
	_flats.clear()
	_hw = hw
	var flats: Array = []
	for si in srcs.size():
		var c3 := srcs[si] as Curve3D
		var fc3 := Curve3D.new()
		fc3.bake_interval = 0.2
		for i in c3.point_count:
			var fp := c3.get_point_position(i)
			var fi := c3.get_point_in(i)
			var fo := c3.get_point_out(i)
			fc3.add_point(Vector3(fp.x, 0.0, fp.z), Vector3(fi.x, 0.0, fi.z), Vector3(fo.x, 0.0, fo.z))
		fc3.closed = c3.closed
		var fl := fc3.get_baked_length()
		if fl > 0.01:
			# end segment lengths, feathered ends fade over these
			var n := fc3.point_count
			var fade := Vector2(fc3.get_closest_offset(fc3.get_point_position(1)),
					fl - fc3.get_closest_offset(fc3.get_point_position(n - 2)))
			# xz bounds for the edge_distance limit early-out
			var rect := Rect2()
			var baked := fc3.get_baked_points()
			for bi in baked.size():
				var bp := Vector2(baked[bi].x, baked[bi].z)
				rect = Rect2(bp, Vector2.ZERO) if bi == 0 else rect.expand(bp)
			flats.append({flat = fc3, len = fl, closed = c3.closed, src = c3, node = src_nodes[si], fade = fade, rect = rect})
	_flats = flats
	# editor only: tell reshaped_hook what area changed
	if Engine.is_editor_hint() and is_inside_tree():
		var old_foot := _foot
		_foot = _world_footprint(flats, radius)
		if not was_built:
			if reshaped_hook.is_valid():
				reshaped_hook.call(self, _foot, true)
		else:
			# old + new footprint, once the dragging stops
			var dirty := _foot.merge(old_foot) if old_foot.has_area() else _foot
			_dirty = _dirty.merge(dirty) if _dirty.has_area() else dirty
			_dirty_ticket += 1
			var ticket := _dirty_ticket
			get_tree().create_timer(RESHAPE_SETTLE).timeout.connect(func(): _report_reshape(ticket))
	if flats.is_empty() or flats[0].src != curve:
		_mi.mesh = null
		return
	var flat: Curve3D = flats[0].flat
	var length: float = 0.0
	for f in flats:
		length += f.len

	# grid over the footprint, not a ribbon - those fold over on inside bends
	var area := length * radius * 2.0
	var sp := maxf(maxf(segment_length, 0.05), sqrt(area / float(MAX_GRID_VERTS)))
	# on Terrain3D match its vertex lattice (same spacing, snapped origin) or terrain
	# pokes through. whole multiples only if over budget. needs identity basis
	var terrain := _terrain_node()
	var vs: float = terrain.vertex_spacing if terrain != null else 0.0
	var aligned := vs > 0.0 and global_basis.is_equal_approx(Basis.IDENTITY)
	if aligned:
		sp = vs * maxf(1.0, ceil(sqrt(area / float(MAX_GRID_VERTS)) / vs - 0.001))
	var samples := PackedVector3Array()
	var mark_step := maxf(radius * 0.5, sp)
	for f in flats:
		var fc: Curve3D = f.flat
		var fl: float = f.len
		var dd := 0.0
		while dd < fl:
			samples.append(fc.sample_baked(dd))
			dd += mark_step
		samples.append(fc.sample_baked(fl))
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for q in samples:
		lo = Vector2(minf(lo.x, q.x), minf(lo.y, q.z))
		hi = Vector2(maxf(hi.x, q.x), maxf(hi.y, q.z))
	lo -= Vector2.ONE * (radius + sp)
	hi += Vector2.ONE * (radius + sp)
	if aligned:
		var gpos := global_position
		lo.x = floor((lo.x + gpos.x) / sp) * sp - gpos.x
		lo.y = floor((lo.y + gpos.z) / sp) * sp - gpos.z
	var nx := int(ceil((hi.x - lo.x) / sp)) + 1
	var nz := int(ceil((hi.y - lo.y) / sp)) + 1

	# coarse pass, mark vertices that could be within radius
	var vid := PackedInt32Array()
	vid.resize(nx * nz)
	vid.fill(-1)
	var mark_r := radius + mark_step * 0.75 + sp
	var cells := int(ceil(mark_r / sp))
	for q in samples:
		var cx := int(round((q.x - lo.x) / sp))
		var cz := int(round((q.z - lo.y) / sp))
		for gz in range(maxi(cz - cells, 0), mini(cz + cells + 1, nz)):
			for gx in range(maxi(cx - cells, 0), mini(cx + cells + 1, nx)):
				var ox := lo.x + gx * sp - q.x
				var oz := lo.y + gz * sp - q.z
				if ox * ox + oz * oz <= mark_r * mark_r:
					vid[gz * nx + gx] = -2

	var joins := _end_joins(flats)

	var data = _terrain_data()
	_mat.set_shader_parameter("half_width", hw)
	_set_runs(flat, closed, flats[0].len)
	# grid is the slow bit, reuse a cached mesh at runtime
	var cache_key := TerrainPathMeshCache.key(self, data, flats, joins, Rect2(lo, hi - lo)) \
			if TerrainPathMeshCache.active() else ""
	var cached := TerrainPathMeshCache.fetch(self, cache_key)
	if cached != null:
		_refresh_partners()
		cached.surface_set_material(0, _mat)
		_mi.mesh = cached
		return

	# pass 1: ground pos/normal per vertex, plus offset and vector to every curve
	var nf := flats.size()
	var b_lp := PackedVector3Array()
	var b_pos := PackedVector3Array()
	var b_norm := PackedVector3Array()
	var b_dist := PackedFloat32Array()
	var b_dist2 := PackedFloat32Array()
	var b_ci := PackedInt32Array()
	var b_ci2 := PackedInt32Array()       # -1 with one curve
	var b_edge := PackedFloat32Array()    # signed m to the ground_fallback edge
	var on_blocks := data != null and not (data is Terrain3DData) and data.has_method(&"sample")
	var b_off := PackedFloat32Array()      # [vertex * nf + curve]
	var b_tp := PackedVector3Array()       # [vertex * nf + curve]
	var inv_basis := global_basis.inverse()
	for gz in nz:
		for gx in nx:
			var k := gz * nx + gx
			if vid[k] != -2:
				continue
			var lp := Vector3(lo.x + gx * sp, 0.0, lo.y + gz * sp)
			# measured from the nearest curve
			var ci := 0
			var ci2 := -1
			var dist := INF
			var dist2 := INF
			for fi in nf:
				var fc: Curve3D = flats[fi].flat
				var o := fc.get_closest_offset(lp)
				var tp := lp - fc.sample_baked(o)
				var dl := tp.length()
				b_off.append(o)
				b_tp.append(tp)
				if dl < dist:
					dist2 = dist
					ci2 = ci if fi > 0 else -1
					dist = dl
					ci = fi
				elif dl < dist2:
					dist2 = dl
					ci2 = fi
			var csrc: Curve3D = flats[ci].src
			var coff: float = b_off[b_off.size() - nf + ci]
			var clen: float = flats[ci].len
			var gp := to_global(lp)
			if aligned:
				# get_height reads the vertex at or below, a -1e-7 error grabs the previous row
				gp.x = roundf(gp.x / vs) * vs
				gp.z = roundf(gp.z / vs) * vs
			var n := Vector3.UP
			var sl := csrc.get_baked_length()
			gp.y = to_global(csrc.sample_baked(clampf(coff / clen * sl, 0.0, sl))).y
			if data != null:
				var h: float = data.get_height(gp)
				if not is_nan(h):
					gp.y = h
					n = data.get_normal(gp)
					if not n.is_finite() or n.length() < 0.5:
						n = Vector3.UP
			var edge := 0.0
			if on_blocks:
				# keep a ring just past the edge so the shader can cut on the outline
				var smp: Dictionary = data.sample(gp)
				edge = smp["edge"]
				if edge < -sp * 1.5:
					continue
				gp.y = smp["height"]
			gp.y += lift
			vid[k] = b_lp.size()
			b_lp.append(lp)
			b_pos.append(to_local(gp))
			b_norm.append((inv_basis * n).normalized())
			b_dist.append(dist)
			b_dist2.append(dist2)
			b_ci.append(ci)
			b_ci2.append(ci2)
			b_edge.append(edge)

	# pass 2: emit quads. each takes lateral/along/end cut from ONE curve - lerping
	# between two gave phantom lines where the nearest flips, so those quads get own corners
	# primary = highest draw_order covering it (ties: parent), secondary rides in CUSTOM1
	# CUSTOM0: |lateral| nearest (half-widths), dist to 2nd nearest (99 = none), joined end flag, end segment length
	# CUSTOM1: 2nd's signed lateral (99 = none), its along, edge distance, edge valid flag
	var prio := PackedFloat32Array()
	for fi in nf:
		prio.append(float((flats[fi].node as TerrainPath).draw_order))
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var uv2s := PackedVector2Array()
	var cust := PackedFloat32Array()
	var cust1 := PackedFloat32Array()
	var out_of := {}                       # corner+curve key -> output index
	var cache := {}
	var idx := PackedInt32Array()
	var corner := PackedInt32Array([0, 0, 0, 0])
	var cover := hw * 1.05
	for gz in nz - 1:
		for gx in nx - 1:
			var q := [vid[gz * nx + gx], vid[gz * nx + gx + 1], vid[(gz + 1) * nx + gx], vid[(gz + 1) * nx + gx + 1]]
			if q[0] < 0 or q[1] < 0 or q[2] < 0 or q[3] < 0:
				continue
			if b_dist[q[0]] > radius and b_dist[q[1]] > radius and b_dist[q[2]] > radius and b_dist[q[3]] > radius:
				continue
			var cands: Array = []
			for j in 4:
				for c in [b_ci[q[j]], b_ci2[q[j]]]:
					if c >= 0 and not cands.has(c):
						cands.append(c)
			var qc := -1
			var sc := -1
			if cands.size() == 1:
				qc = cands[0]
			else:
				for c in cands:
					if _covers(q, c, nf, b_tp, cover) and (qc < 0 or _outranks(c, qc, prio)):
						qc = c
				if qc < 0:
					var best_n := 0
					for j in 4:
						var cn := 0
						for m in 4:
							if b_ci[q[m]] == b_ci[q[j]]:
								cn += 1
						if cn > best_n or (cn == best_n and b_ci[q[j]] < qc):
							best_n = cn
							qc = b_ci[q[j]]
				for c in cands:
					if c != qc and _covers(q, c, nf, b_tp, cover) and (sc < 0 or _outranks(c, sc, prio)):
						sc = c
				if sc < 0:
					var bd := INF
					for c in cands:
						if c == qc:
							continue
						var dsum := 0.0
						for j in 4:
							dsum += b_tp[q[j] * nf + c].length()
						if dsum < bd:
							bd = dsum
							sc = c
			var clen: float = flats[qc].len
			var cclosed: bool = flats[qc].closed
			var vals: Array = []
			var svals: Array = []
			for j in 4:
				vals.append(_corner_vals(q[j], qc, nf, flats, b_off, b_tp, b_lp, joins, hw, cache))
				svals.append(_corner_vals(q[j], sc, nf, flats, b_off, b_tp, b_lp, joins, hw, cache) if sc >= 0 else null)
			# closed loops: unwrap the small side (+L) across the seam
			var wrap := cclosed and _spans_seam([vals[0][0], vals[1][0], vals[2][0], vals[3][0]], clen)
			for j in 4:
				var bi: int = q[j]
				var vv: Array = vals[j]
				var v: float = vv[0]
				var key: int = (bi * nf + qc) * (nf + 1) + sc + 1
				if wrap and v < clen * 0.5:
					v += clen
					key = -1 - key
				if out_of.has(key):
					corner[j] = out_of[key]
					continue
				corner[j] = verts.size()
				out_of[key] = corner[j]
				# continuous across the flip, used for the outline
				var nc: int = b_ci[bi]
				var nv: Array = _corner_vals(bi, nc, nf, flats, b_off, b_tp, b_lp, joins, hw, cache)
				verts.append(b_pos[bi])
				norms.append(b_norm[bi])
				uvs.append(Vector2(b_dist[bi] / hw, v))
				uv2s.append(Vector2(vv[1] / hw, vv[2]))
				var fade: Vector2 = flats[qc].fade
				cust.append_array([absf(nv[1]) / hw, minf(b_dist2[bi] / hw, 99.0), vv[3], fade.x if v < clen * 0.5 else fade.y])
				if svals[j] != null:
					cust1.append_array([svals[j][1] / hw, svals[j][0], b_edge[bi], 1.0 if on_blocks else 0.0])
				else:
					cust1.append_array([99.0, 0.0, b_edge[bi], 1.0 if on_blocks else 0.0])
			# four tris round a centre, not two: Terrain3D can split the cell either way,
			# so the centre takes the higher diagonal and never dips under
			var ctr := verts.size()
			var p00 := verts[corner[0]]
			var p10 := verts[corner[1]]
			var p01 := verts[corner[2]]
			var p11 := verts[corner[3]]
			var cp := (p00 + p10 + p01 + p11) * 0.25
			cp.y = maxf((p00.y + p11.y) * 0.5, (p10.y + p01.y) * 0.5)
			verts.append(cp)
			norms.append((norms[corner[0]] + norms[corner[1]] + norms[corner[2]] + norms[corner[3]]).normalized())
			uvs.append((uvs[corner[0]] + uvs[corner[1]] + uvs[corner[2]] + uvs[corner[3]]) * 0.25)
			uv2s.append((uv2s[corner[0]] + uv2s[corner[1]] + uv2s[corner[2]] + uv2s[corner[3]]) * 0.25)
			for ch in 4:
				cust.append((cust[corner[0] * 4 + ch] + cust[corner[1] * 4 + ch]
						+ cust[corner[2] * 4 + ch] + cust[corner[3] * 4 + ch]) * 0.25)
				cust1.append((cust1[corner[0] * 4 + ch] + cust1[corner[1] * 4 + ch]
						+ cust1[corner[2] * 4 + ch] + cust1[corner[3] * 4 + ch]) * 0.25)
			idx.append_array([corner[0], corner[1], ctr, corner[1], corner[3], ctr,
					corner[3], corner[2], ctr, corner[2], corner[0], ctr])
	if idx.is_empty():
		_mi.mesh = null
		return

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_TEX_UV2] = uv2s
	arrays[Mesh.ARRAY_CUSTOM0] = cust
	arrays[Mesh.ARRAY_CUSTOM1] = cust1
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {},
			(Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT)
			| (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM1_SHIFT))
	_refresh_partners()
	if Engine.is_editor_hint():
		# editor: wait for dragging to stop
		_store_ticket += 1
		var ticket := _store_ticket
		get_tree().create_timer(STORE_SETTLE).timeout.connect(func():
			if ticket == _store_ticket and is_inside_tree():
				TerrainPathMeshCache.store(self, cache_key, mesh))
	else:
		TerrainPathMeshCache.store(self, cache_key, mesh)
	mesh.surface_set_material(0, _mat)
	_mi.mesh = mesh


## straight runs for the shader: per joint world xz, mitre normal and offset along the curve
func _set_runs(flat: Curve3D, closed: bool, length: float) -> void:
	var pts := PackedVector2Array()
	for p in flat.get_baked_points():
		pts.append(Vector2(p.x, p.z))
	if closed and pts[0].distance_to(pts[pts.size() - 1]) > 0.01:
		pts.append(pts[0])
	var tol := straight_tolerance
	var nodes := _simplify(pts, tol)
	while nodes.size() > MAX_RUNS:
		tol *= 1.5
		nodes = _simplify(pts, tol)
	var n := nodes.size()
	var packed := PackedVector4Array()
	var offs := PackedFloat32Array()
	packed.resize(MAX_RUNS)
	offs.resize(MAX_RUNS)
	for i in n:
		var p := nodes[i]
		var d_in := Vector2.ZERO
		var d_out := Vector2.ZERO
		if i > 0:
			d_in = (p - nodes[i - 1]).normalized()
		elif closed:
			d_in = (p - nodes[n - 2]).normalized()
		if i < n - 1:
			d_out = (nodes[i + 1] - p).normalized()
		elif closed:
			d_out = (nodes[1] - p).normalized()
		var m := d_in + d_out
		m = m.normalized() if m.length() > 0.001 else (d_out if d_out != Vector2.ZERO else d_in)
		var wp := to_global(Vector3(p.x, 0.0, p.y))
		var wm := global_basis * Vector3(m.x, 0.0, m.y)
		var wm2 := Vector2(wm.x, wm.z).normalized()
		packed[i] = Vector4(wp.x, wp.z, wm2.x, wm2.y)
		offs[i] = length if (closed and i == n - 1) else flat.get_closest_offset(Vector3(p.x, 0.0, p.y))
	_mat.set_shader_parameter("run_nodes", packed)
	_mat.set_shader_parameter("run_offs", offs)
	_mat.set_shader_parameter("run_count", n)
	_mat.set_shader_parameter("run_closed", closed)


## Douglas-Peucker
static func _simplify(pts: PackedVector2Array, tol: float) -> PackedVector2Array:
	var n := pts.size()
	if n < 3:
		return pts
	var keep := PackedByteArray()
	keep.resize(n)
	keep.fill(0)
	keep[0] = 1
	keep[n - 1] = 1
	var stack: Array[Vector2i] = [Vector2i(0, n - 1)]
	while not stack.is_empty():
		var r: Vector2i = stack.pop_back()
		var a := pts[r.x]
		var b := pts[r.y]
		var best := -1
		var best_d := tol
		for i in range(r.x + 1, r.y):
			var d := _point_seg_dist(pts[i], a, b)
			if d > best_d:
				best_d = d
				best = i
		if best >= 0:
			keep[best] = 1
			stack.append(Vector2i(r.x, best))
			stack.append(Vector2i(best, r.y))
	var out := PackedVector2Array()
	for i in n:
		if keep[i] == 1:
			out.append(pts[i])
	return out


static func _point_seg_dist(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var l2 := ab.length_squared()
	if l2 < 1e-8:
		return p.distance_to(a)
	return p.distance_to(a + ab * clampf((p - a).dot(ab) / l2, 0.0, 1.0))


## per flat [start, end], each null or {p, n, partner}: joint midpoint + outward mitre normal
## both paths get the same plane so they butt without a seam
func _end_joins(flats: Array) -> Array:
	var out: Array = []
	_join_partners_new = []
	var members: Array = []
	for f in flats:
		members.append(f.node)
	var feathered := style != null and style.end_style == TerrainPathStyle.EndStyle.FEATHERED
	for f in flats:
		var ends: Array = [null, null]
		out.append(ends)
		if f.closed or feathered or not is_inside_tree():
			continue
		var flat: Curve3D = f.flat
		var length: float = f.len
		for e in 2:
			var ep := flat.sample_baked(0.0 if e == 0 else length)
			var t := _flat_tangent(flat, 0.0 if e == 0 else length, length)
			var w_end := to_global(ep)
			var w_out := global_basis * (-t if e == 0 else t)
			w_out.y = 0.0
			var best_d := JOIN_TOLERANCE
			for n in get_tree().get_nodes_in_group(GROUP):
				var q := n as TerrainPath
				if q == null or q == f.node or q.curve == null \
						or q.curve.closed or q.curve.point_count < 2:
					continue
				var qs := q._root_path().style
				if qs != null and qs.end_style == TerrainPathStyle.EndStyle.FEATHERED:
					continue   # feathered blends by overlap
				var ql := q.curve.get_baked_length()
				if ql <= 0.01:
					continue
				for qe in 2:
					var qd := 0.0 if qe == 0 else ql
					var qp := q.to_global(q.curve.sample_baked(qd))
					var gap := Vector2(qp.x - w_end.x, qp.z - w_end.z).length()
					if gap >= best_d:
						continue
					var qa := q.to_global(q.curve.sample_baked(clampf(qd - 0.25, 0.0, ql)))
					var qb := q.to_global(q.curve.sample_baked(clampf(qd + 0.25, 0.0, ql)))
					var q_in := (qb - qa) if qe == 0 else (qa - qb)
					q_in.y = 0.0
					var nw := w_out.normalized() + q_in.normalized()
					if nw.length() < 0.2:
						continue   # folds back, no usable mitre
					var lp := to_local((w_end + qp) * 0.5)
					var ln := global_basis.inverse() * nw
					ln.y = 0.0
					best_d = gap
					ends[e] = {p = Vector3(lp.x, 0.0, lp.z), n = ln.normalized(), partner = q}
			if ends[e] != null and not members.has(ends[e].partner):
				_join_partners_new.append(ends[e].partner)
	return out


## editor: a moved end re-cuts the partner it left and the one it reached
## (a rebuild a partner asked for doesn't pass on, or they ping-pong)
func _refresh_partners() -> void:
	var was_partner := _partner_triggered
	_partner_triggered = false
	var old := _join_partners
	_join_partners = _join_partners_new.duplicate()
	if not Engine.is_editor_hint() or was_partner:
		return
	for q in old + _join_partners:
		if is_instance_valid(q) and q.is_inside_tree():
			(q as TerrainPath)._queue_partner_rebuild()


func _queue_partner_rebuild() -> void:
	if not _queued:
		_partner_triggered = true
	_queue_rebuild()


## [v, lateral, over, joined] for a grid corner against curve c
func _corner_vals(bi: int, c: int, nf: int, flats: Array, b_off: PackedFloat32Array,
		b_tp: PackedVector3Array, b_lp: PackedVector3Array, joins: Array, hw: float, cache: Dictionary) -> Array:
	var key := bi * nf + c
	if cache.has(key):
		return cache[key]
	var cf: Curve3D = flats[c].flat
	var clen: float = flats[c].len
	var cclosed: bool = flats[c].closed
	var off: float = b_off[key]
	var to_p: Vector3 = b_tp[key]
	var tang := _flat_tangent(cf, off, clen)
	var lateral := _lateral(to_p, tang, off, clen, cclosed)
	# past an end add the overshoot so patterns carry straight on
	var v := off + (0.0 if cclosed else to_p.dot(tang))
	# signed, clamping at 0 gives a stair-stepped cut
	var over := -1000.0 if cclosed else maxf(-v, v - clen)
	# joined ends cut along the shared mitre
	var joined := 0.0
	if not cclosed:
		var je: int = 0 if v < clen * 0.5 else 1
		var dend := v if je == 0 else clen - v
		var jn = joins[c][je]
		if jn != null and dend < minf(clen * 0.5, hw * 4.0):
			over = (b_lp[bi] - jn.p).dot(jn.n)
			joined = 1.0
	var r := [v, lateral, over, joined]
	cache[key] = r
	return r


static func _covers(q: Array, c: int, nf: int, b_tp: PackedVector3Array, cover: float) -> bool:
	for j in 4:
		if b_tp[int(q[j]) * nf + c].length() <= cover:
			return true
	return false


static func _outranks(a: int, b: int, prio: PackedFloat32Array) -> bool:
	return prio[a] > prio[b] or (prio[a] == prio[b] and a < b)


## signed sideways distance. true distance along the run (projecting on the averaged
## tangent notches edge lines at sharp corners), plain projection past an open end
static func _lateral(to_p: Vector3, tang: Vector3, off: float, length: float, closed: bool) -> float:
	var proj := to_p.dot(tang.cross(Vector3.UP))
	if not closed and (off <= 0.001 or off >= length - 0.001):
		return proj
	return signf(proj) * to_p.length() if proj != 0.0 else 0.0


func _flat_tangent(c: Curve3D, d: float, length: float) -> Vector3:
	var a := c.sample_baked(clampf(d - 0.25, 0.0, length))
	var b := c.sample_baked(clampf(d + 0.25, 0.0, length))
	var t := b - a
	t.y = 0.0
	return t.normalized() if t.length() > 0.0001 else Vector3.FORWARD


func _spans_seam(offs: Array, length: float) -> bool:
	return offs.max() - offs.min() > length * 0.5


func _snap_points() -> void:
	var data = _terrain_data()
	if curve == null or data == null:
		return
	for i in curve.point_count:
		var p := curve.get_point_position(i)
		var wp := to_global(p)
		var h: float = data.get_height(wp)
		if is_nan(h):
			continue
		curve.set_point_position(i, Vector3(p.x, to_local(Vector3(wp.x, h, wp.z)).y, p.z))


## Terrain3D data, else ground_fallback, else null
func _terrain_data() -> Object:
	var t := _terrain_node()
	if t != null:
		return t.get_data()
	return ground_fallback.call(self) if ground_fallback.is_valid() else null


func _terrain_node() -> Node:
	var root: Node = null
	if Engine.is_editor_hint():
		root = get_tree().edited_scene_root
	if root == null:
		root = owner if owner != null else get_tree().current_scene
	if root == null:
		return null
	for n in root.find_children("*", "Terrain3D", true, false):
		return n
	# a level nested in a bigger world may have its own Terrain3D stripped, use the
	# nearest ancestor's, else it drops to the ground_fallback ground and nothing builds
	var a := root.get_parent()
	while a != null:
		for c in a.get_children():
			if c is Terrain3D:
				return c
		a = a.get_parent()
	return null
