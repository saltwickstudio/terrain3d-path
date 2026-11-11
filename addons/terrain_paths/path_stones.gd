@tool
extends RefCounted
# procedural flagstones for PathScatter when it has no tile scenes
# voronoi cells off a jittered grid, inset for the gap, extruded with a bevelled top

const DEPTH := 0.1   # sides run this far below ground so slopes never show a bottom edge
const SHADES := 6

var size := 0.4
var gap := 0.03
var height := 0.1
var height_jitter := 0.03
var bevel := 0.04
var roundness := 1
var jitter := 0.7
var colour := Color(0.54, 0.57, 0.62)
var colour_jitter := 0.08
var seed := 1

var _mats: Array[Material] = []


## stones whose seed lands inside rect, flat (no bending). used for loose pebbles
func patch(rect: Rect2) -> Array:
	var out: Array = []
	for j in range(floori(rect.position.y / size) - 1, ceili(rect.end.y / size) + 1):
		for i in range(floori(rect.position.x / size) - 1, ceili(rect.end.x / size) + 1):
			var s := seed_at(i, j)
			if not rect.has_point(s):
				continue
			var others := PackedVector2Array()
			for dj in range(-2, 3):
				for di in range(-2, 3):
					if di != 0 or dj != 0:
						others.append(seed_at(i + di, j + dj))
			var poly := cell(s, others)
			if poly.size() >= 3:
				out.append(stone(poly, i, j))
	return out


## grid seed (i, j), jittered. x across, y along
func seed_at(i: int, j: int) -> Vector2:
	var r := _rng(i, j, 0)
	return Vector2(i + 0.5 + (r.randf() - 0.5) * jitter, j + 0.5 + (r.randf() - 0.5) * jitter) * size


## voronoi cell of s against its neighbours, pulled in by half the gap and rounded
func cell(s: Vector2, others: PackedVector2Array) -> PackedVector2Array:
	var h := size * 2.0
	var poly := PackedVector2Array([s + Vector2(-h, -h), s + Vector2(h, -h), s + Vector2(h, h), s + Vector2(-h, h)])
	for o in others:
		var d := o - s
		var dist := d.length()
		if dist < 0.0001:
			continue
		poly = _clip(poly, s, d / dist, dist * 0.5 - gap * 0.5)
		if poly.size() < 3:
			return poly
	for k in roundness:
		poly = _chaikin(poly)
	return poly


## mesh for one cell, centred on it: {v, n, uv, i, centre, radius, outline, material}
func stone(poly: PackedVector2Array, i: int, j: int) -> Dictionary:
	_make_mats()
	var r := _rng(i, j, 7)
	var c := Vector2.ZERO
	for p in poly:
		c += p
	c /= poly.size()
	var area := 0.0
	for k in poly.size():
		area += poly[k].cross(poly[(k + 1) % poly.size()])
	if area < 0.0:
		poly.reverse()
	# inner radius
	var rad := INF
	for k in poly.size():
		var e := (poly[(k + 1) % poly.size()] - poly[k]).normalized()
		rad = minf(rad, absf((c - poly[k]).cross(e)))

	var h := height + r.randf_range(-height_jitter, height_jitter)
	var shrink := maxf(0.3, 1.0 - bevel / maxf(rad * 1.3, 0.001))
	var v := PackedVector3Array()
	var n := PackedVector3Array()
	var ii := PackedInt32Array()
	var top := Vector3(0.0, h, 0.0)
	var outline := PackedVector2Array()
	for k in poly.size():
		var a := poly[k] - c
		var b := poly[(k + 1) % poly.size()] - c
		outline.append(a)
		var e := b - a
		var out2 := Vector2(e.y, -e.x).normalized()
		var side := Vector3(out2.x, 0.0, out2.y)
		var a0 := Vector3(a.x, -DEPTH, a.y)
		var b0 := Vector3(b.x, -DEPTH, b.y)
		var a1 := Vector3(a.x, h - bevel, a.y)
		var b1 := Vector3(b.x, h - bevel, b.y)
		var a2 := Vector3(a.x * shrink, h, a.y * shrink)
		var b2 := Vector3(b.x * shrink, h, b.y * shrink)
		_quad(v, n, ii, a0, b0, b1, a1, side)
		_quad(v, n, ii, a1, b1, b2, a2, (side + Vector3.UP).normalized())
		_tri(v, n, ii, a2, b2, top, Vector3.UP)
	var uv := PackedVector2Array()
	uv.resize(v.size())
	return {"v": v, "n": n, "uv": uv, "i": ii, "centre": c, "radius": rad, "outline": outline,
			"material": _mats[r.randi() % _mats.size()]}


func _rng(i: int, j: int, salt: int) -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = hash([i, j, seed, salt])
	return r


# sutherland-hodgman, keep the side where (p - s).dir <= limit
func _clip(poly: PackedVector2Array, s: Vector2, dir: Vector2, limit: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	for k in poly.size():
		var a := poly[k]
		var b := poly[(k + 1) % poly.size()]
		var da := (a - s).dot(dir) - limit
		var db := (b - s).dot(dir) - limit
		if da <= 0.0:
			out.append(a)
		if (da <= 0.0) != (db <= 0.0):
			out.append(a.lerp(b, da / (da - db)))
	return out


func _chaikin(poly: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for k in poly.size():
		var a := poly[k]
		var b := poly[(k + 1) % poly.size()]
		out.append(a.lerp(b, 0.25))
		out.append(a.lerp(b, 0.75))
	return out


func _quad(v: PackedVector3Array, n: PackedVector3Array, ii: PackedInt32Array,
		a: Vector3, b: Vector3, c: Vector3, d: Vector3, nrm: Vector3) -> void:
	_tri(v, n, ii, a, b, c, nrm)
	_tri(v, n, ii, a, c, d, nrm)


# godot wants clockwise front faces, so flip if the winding faces the normal
func _tri(v: PackedVector3Array, n: PackedVector3Array, ii: PackedInt32Array,
		a: Vector3, b: Vector3, c: Vector3, nrm: Vector3) -> void:
	if (b - a).cross(c - a).dot(nrm) > 0.0:
		var t := b
		b = c
		c = t
	for p in [a, b, c]:
		ii.append(v.size())
		v.append(p)
		n.append(nrm)


func _make_mats() -> void:
	if not _mats.is_empty():
		return
	for k in SHADES:
		var m := StandardMaterial3D.new()
		var t := lerpf(-colour_jitter, colour_jitter, k / float(SHADES - 1))
		m.albedo_color = colour.lightened(t) if t > 0.0 else colour.darkened(-t)
		m.roughness = 1.0
		_mats.append(m)
