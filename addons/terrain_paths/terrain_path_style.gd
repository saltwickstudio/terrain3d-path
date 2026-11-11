@tool
@icon("res://addons/terrain_paths/icons/terrain_path_style.svg")
class_name TerrainPathStyle
extends Resource
## look of one kind of path, presets in presets/*.tres
## every field is a uniform on terrain_path.gdshader so edits show live

enum Pattern { MUD, GRAVEL, PAVED, ROAD, TEXTURE, STONES }
enum EndStyle { ROUND, SQUARE, FEATHERED }

@export var pattern: Pattern = Pattern.MUD:
	set(v):
		pattern = v
		emit_changed()
## metres, a path can override
@export var default_width := 2.0:
	set(v):
		default_width = v
		emit_changed()

## free text for your own footsteps / grip code, see TerrainPath.surface_at()
@export var surface_tag := "":
	set(v):
		surface_tag = v
		emit_changed()

@export_group("Colours")
@export var base_color := Color(0.56, 0.45, 0.31):
	set(v):
		base_color = v
		emit_changed()
## worn centre line, 0 alpha = off
@export var wear_color := Color(0.66, 0.56, 0.41, 0.6):
	set(v):
		wear_color = v
		emit_changed()
@export var pattern_color := Color(0.42, 0.32, 0.21):
	set(v):
		pattern_color = v
		emit_changed()
@export var pattern_color_2 := Color(0.7, 0.6, 0.45):
	set(v):
		pattern_color_2 = v
		emit_changed()
## band where the path meets the grass
@export var rim_color := Color(0.36, 0.3, 0.17):
	set(v):
		rim_color = v
		emit_changed()

## fraction of half-width, uses the main edge wobble / feather
@export_range(0.05, 1.0) var wear_width := 0.4:
	set(v):
		wear_width = v
		emit_changed()

@export_group("Edges")
## fraction of half-width, 0 = no rim
@export_range(0.0, 0.6) var rim_width := 0.18:
	set(v):
		rim_width = v
		emit_changed()
@export_range(0.0, 1.0) var feather := 0.25:
	set(v):
		feather = v
		emit_changed()
## 0 = soft airbrush, 1 = crisp cartoon cut
@export_range(0.0, 1.0) var edge_hardness := 0.6:
	set(v):
		edge_hardness = v
		emit_changed()
## fraction of half-width
@export_range(0.0, 0.6) var wobble := 0.22:
	set(v):
		wobble = v
		emit_changed()
## metres, bigger = lazier bulges
@export_range(0.2, 10.0) var wobble_scale := 2.2:
	set(v):
		wobble_scale = v
		emit_changed()
## small bites out of the edge on top of the wobble
@export_range(0.0, 0.5) var ragged := 0.12:
	set(v):
		ragged = v
		emit_changed()

@export_group("Pattern")
## feature size in metres (puddle / pebble / slab length)
@export_range(0.05, 4.0) var pattern_scale := 1.4:
	set(v):
		pattern_scale = v
		emit_changed()
@export_range(0.0, 1.0) var pattern_amount := 0.55:
	set(v):
		pattern_amount = v
		emit_changed()
## low frequency blotching so long runs don't look flat
@export_range(0.0, 1.0) var mottle := 0.35:
	set(v):
		mottle = v
		emit_changed()

## TEXTURE pattern, RGB = colour, A = height for the bump
@export var surface_texture: Texture2D:
	set(v):
		surface_texture = v
		emit_changed()
## metres per repeat
@export_range(0.25, 10.0, 0.05) var texture_tile := 2.0:
	set(v):
		texture_tile = v
		emit_changed()

## STONES: fraction of stone size
@export_range(0.0, 0.5, 0.01) var stone_gap := 0.12:
	set(v):
		stone_gap = v
		emit_changed()
## 0 = sharp slabs, 1 = round pebbles
@export_range(0.0, 1.0) var stone_roundness := 0.45:
	set(v):
		stone_roundness = v
		emit_changed()
## 0 = terrain shows through the gaps, 1 = solid pattern_color
@export_range(0.0, 1.0) var gap_opacity := 0.0:
	set(v):
		gap_opacity = v
		emit_changed()

## metres
@export_range(0.0, 0.3, 0.005) var stone_height := 0.06:
	set(v):
		stone_height = v
		emit_changed()
## chamfer width (m), drawn in pattern_color_2
@export_range(0.0, 0.2, 0.005) var stone_bevel := 0.05:
	set(v):
		stone_bevel = v
		emit_changed()
@export_range(0.0, 1.0) var stone_roughness := 0.5:
	set(v):
		stone_roughness = v
		emit_changed()
@export_range(0.0, 1.0) var stone_shadow := 0.35:
	set(v):
		stone_shadow = v
		emit_changed()
@export_range(0.0, 0.3, 0.005) var stone_shadow_width := 0.08:
	set(v):
		stone_shadow_width = v
		emit_changed()

## procedural normal map, 0 = flat paint
@export_range(0.0, 4.0) var bump_strength := 1.0:
	set(v):
		bump_strength = v
		emit_changed()

## FEATHERED fades out over the last segment with noise breakup, for blending into
## terrain or another path - never mitre-joins
@export var end_style: EndStyle = EndStyle.ROUND:
	set(v):
		end_style = v
		emit_changed()
## FEATHERED: noise patch size (m)
@export_range(0.1, 5.0, 0.05) var end_patch_size := 1.0:
	set(v):
		end_patch_size = v
		emit_changed()
@export_range(0.0, 1.0) var end_breakup := 0.7:
	set(v):
		end_breakup = v
		emit_changed()
@export_range(0.0, 1.0) var end_softness := 0.3:
	set(v):
		end_softness = v
		emit_changed()
## also thin the opacity toward the tip
@export_range(0.0, 1.0) var end_opacity_fade := 0.0:
	set(v):
		end_opacity_fade = v
		emit_changed()
## fade length as a multiple of the end segment, 1 = last two points
@export_range(0.1, 4.0, 0.05) var end_spread := 1.0:
	set(v):
		end_spread = v
		emit_changed()
## tip width multiplier, below 1 narrows to a point
@export_range(0.0, 3.0, 0.05) var end_taper := 1.0:
	set(v):
		end_taper = v
		emit_changed()
@export_range(0.0, 0.9) var end_fade_start := 0.0:
	set(v):
		end_fade_start = v
		emit_changed()
@export_group("Edging")
## raised kerb blocks along both edges, replaces the rim
@export var edging := false:
	set(v):
		edging = v
		emit_changed()
@export_range(0.05, 1.0, 0.01) var edging_width := 0.22:
	set(v):
		edging_width = v
		emit_changed()
@export_range(0.1, 3.0, 0.05) var edging_block_length := 0.9:
	set(v):
		edging_block_length = v
		emit_changed()
@export var edging_color := Color(0.55, 0.53, 0.5):
	set(v):
		edging_color = v
		emit_changed()

@export_group("Road Markings")
## centre line (dashed or solid) plus optional edge lines
@export var markings := false:
	set(v):
		markings = v
		emit_changed()
@export var line_color := Color(0.93, 0.92, 0.86, 0.9):
	set(v):
		line_color = v
		emit_changed()
@export_range(0.03, 0.5, 0.01) var line_width := 0.12:
	set(v):
		line_width = v
		emit_changed()
@export_range(0.2, 12.0, 0.1) var dash_length := 3.0:
	set(v):
		dash_length = v
		emit_changed()
## 0 = solid line
@export_range(0.0, 20.0, 0.1) var dash_gap := 6.0:
	set(v):
		dash_gap = v
		emit_changed()
## 0 = no edge lines
@export_range(0.0, 2.0, 0.01) var edge_line_inset := 0.3:
	set(v):
		edge_line_inset = v
		emit_changed()
## rounds the corner where a branch meets its parent
@export_range(0.0, 15.0, 0.1) var junction_radius := 0.0:
	set(v):
		junction_radius = v
		emit_changed()


func apply_to(mat: ShaderMaterial) -> void:
	mat.set_shader_parameter("pattern", int(pattern))
	mat.set_shader_parameter("base_color", base_color)
	mat.set_shader_parameter("wear_color", wear_color)
	mat.set_shader_parameter("pattern_color", pattern_color)
	mat.set_shader_parameter("pattern_color_2", pattern_color_2)
	mat.set_shader_parameter("rim_color", rim_color)
	mat.set_shader_parameter("rim_width", rim_width)
	mat.set_shader_parameter("wear_width", wear_width)
	mat.set_shader_parameter("feather", feather)
	mat.set_shader_parameter("edge_hardness", edge_hardness)
	mat.set_shader_parameter("wobble", wobble)
	mat.set_shader_parameter("wobble_scale", wobble_scale)
	mat.set_shader_parameter("ragged", ragged)
	mat.set_shader_parameter("pattern_scale", pattern_scale)
	mat.set_shader_parameter("pattern_amount", pattern_amount)
	mat.set_shader_parameter("mottle", mottle)
	mat.set_shader_parameter("bump_strength", bump_strength)
	mat.set_shader_parameter("surface_texture", surface_texture)
	mat.set_shader_parameter("texture_tile", texture_tile)
	mat.set_shader_parameter("stone_gap", stone_gap)
	mat.set_shader_parameter("stone_roundness", stone_roundness)
	mat.set_shader_parameter("gap_opacity", gap_opacity)
	mat.set_shader_parameter("stone_height", stone_height)
	mat.set_shader_parameter("stone_bevel", stone_bevel)
	mat.set_shader_parameter("stone_roughness", stone_roughness)
	mat.set_shader_parameter("stone_shadow", stone_shadow)
	mat.set_shader_parameter("stone_shadow_width", stone_shadow_width)
	mat.set_shader_parameter("square_ends", end_style == EndStyle.SQUARE)
	mat.set_shader_parameter("feather_ends", end_style == EndStyle.FEATHERED)
	mat.set_shader_parameter("end_patch_size", end_patch_size)
	mat.set_shader_parameter("end_breakup", end_breakup)
	mat.set_shader_parameter("end_softness", end_softness)
	mat.set_shader_parameter("end_fade_start", end_fade_start)
	mat.set_shader_parameter("end_opacity_fade", end_opacity_fade)
	mat.set_shader_parameter("end_spread", end_spread)
	mat.set_shader_parameter("end_taper", end_taper)
	mat.set_shader_parameter("edging", edging)
	mat.set_shader_parameter("edging_width", edging_width)
	mat.set_shader_parameter("edging_block_length", edging_block_length)
	mat.set_shader_parameter("edging_color", edging_color)
	mat.set_shader_parameter("markings", markings)
	mat.set_shader_parameter("line_color", line_color)
	mat.set_shader_parameter("line_width", line_width)
	mat.set_shader_parameter("dash_length", dash_length)
	mat.set_shader_parameter("dash_gap", dash_gap)
	mat.set_shader_parameter("edge_line_inset", edge_line_inset)
	mat.set_shader_parameter("junction_radius", junction_radius)


const PRESET_DIR := "res://addons/terrain_paths/presets/"


## fresh deep copy each call, the path owns it
static func from_preset(preset_name: String) -> TerrainPathStyle:
	var src := load(PRESET_DIR + preset_name + ".tres") as TerrainPathStyle
	if src == null:
		push_warning("TerrainPathStyle: missing preset '%s'" % preset_name)
		return TerrainPathStyle.new()
	return src.duplicate(true) as TerrainPathStyle


static func woodland_mud() -> TerrainPathStyle:
	return from_preset("woodland_mud")


static func country_gravel() -> TerrainPathStyle:
	return from_preset("country_gravel")


## small setts, kerbed
static func city_paved() -> TerrainPathStyle:
	return from_preset("city_paved")


static func city_slabs() -> TerrainPathStyle:
	return from_preset("city_slabs")


## TEXTURE pattern
static func cobbles() -> TerrainPathStyle:
	return from_preset("cobbles")


## STONES pattern
static func stones() -> TerrainPathStyle:
	return from_preset("stones")


static func road() -> TerrainPathStyle:
	return from_preset("road")
