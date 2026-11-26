extends SceneTree
# builds the example terrain data and grass texture. run once:
# godot --headless --path . --script res://example/gen_terrain.gd

const SPACING := 0.5
const REGION := 256


func _init() -> void:
	var tex := _grass_texture()
	tex.save_png("res://example/grass.png")

	var terrain := Terrain3D.new()
	terrain.vertex_spacing = SPACING
	terrain.region_size = REGION
	root.add_child(terrain)
	await process_frame

	var half := REGION * SPACING
	var n := int(half * 2.0 / SPACING)
	var noise := FastNoiseLite.new()
	noise.seed = 7
	noise.frequency = 0.012
	noise.fractal_octaves = 3
	var hmap := Image.create(n, n, false, Image.FORMAT_RF)
	var ctrl := Image.create(n, n, false, Image.FORMAT_RF)
	var col := Image.create(n, n, false, Image.FORMAT_RGBA8)
	var ctrl_val := Color(_control(0), 0, 0, 1)
	for x in n:
		for y in n:
			var w := Vector2(x, y) * SPACING - Vector2(half, half)
			var h := noise.get_noise_2dv(w) * 6.0 + 3.0
			# flatter round the middle so there's room to work
			h = lerpf(h * 0.3, h, clampf(w.length() / 40.0, 0.0, 1.0))
			hmap.set_pixel(x, y, Color(h, 0, 0, 1))
			ctrl.set_pixel(x, y, ctrl_val)
			var t := clampf(0.5 + h / 10.0, 0.0, 1.0)
			col.set_pixel(x, y, Color(0.85 + 0.15 * t, 0.9 + 0.1 * t, 0.8 + 0.1 * t, 0.5))
	terrain.data.import_images([hmap, ctrl, col], Vector3(-half, 0, -half), 0.0, 1.0)
	DirAccess.make_dir_recursive_absolute("res://example/terrain_data")
	terrain.data.save_directory("res://example/terrain_data")
	print("terrain saved")
	quit()


func _control(id: int) -> float:
	return Terrain3DUtil.as_float(Terrain3DUtil.enc_base(id) | Terrain3DUtil.enc_overlay(id))


func _grass_texture() -> Image:
	var size := 512
	var noise := FastNoiseLite.new()
	noise.frequency = 0.05
	var fine := FastNoiseLite.new()
	fine.seed = 3
	fine.frequency = 0.35
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var a := Color(0.30, 0.52, 0.20)
	var b := Color(0.42, 0.62, 0.26)
	var big := noise.get_seamless_image(size, size)
	var small := fine.get_seamless_image(size, size)
	for x in size:
		for y in size:
			var t := big.get_pixel(x, y).r * 0.6 + small.get_pixel(x, y).r * 0.4
			var c := a.lerp(b, t)
			c.a = small.get_pixel(x, y).r
			img.set_pixel(x, y, c)
	img.generate_mipmaps()
	return img
