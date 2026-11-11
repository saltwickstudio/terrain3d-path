// baked version of terrain_path.gdshader - path_baker.gd renders it top-down into tiles once, this just samples them
// albedo_tiles is premultiplied, normal_tiles is n * 0.5 + 0.5, tile_index is (layer + 1) / 255 and 0 = nothing baked
shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, diffuse_burley, specular_disabled;

uniform sampler2DArray albedo_tiles : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform sampler2DArray normal_tiles : filter_linear_mipmap, repeat_disable;
uniform sampler2D tile_index : filter_nearest, repeat_disable;
uniform vec2 origin = vec2(0.0);   // world xz of tile 0,0 min corner
uniform float tile_m = 32.0;        // metres per tile
uniform ivec2 tiles = ivec2(1);
uniform float depth_pull = 0.04;

varying vec3 v_world;

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec4 vp = MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	float dist = length(vp.xyz);
	vp.xyz -= (vp.xyz / max(dist, 0.001)) * (depth_pull + dist * 0.0025);
	POSITION = PROJECTION_MATRIX * vp;
}

void fragment() {
	vec2 t = (v_world.xz - origin) / tile_m;
	ivec2 ti = clamp(ivec2(floor(t)), ivec2(0), tiles - 1);
	float layer = texelFetch(tile_index, ti, 0).r * 255.0 - 1.0;
	vec3 uvl = vec3(t - vec2(ti), max(layer, 0.0));
	// textureGrad off the continuous coord - no mip jumps at seams
	vec2 gx = dFdx(t);
	vec2 gy = dFdy(t);
	vec4 a = textureGrad(albedo_tiles, uvl, gx, gy);
	vec3 n = textureGrad(normal_tiles, uvl, gx, gy).xyz * 2.0 - 1.0;
	ALBEDO = a.rgb / max(a.a, 0.001);
	ROUGHNESS = 1.0;
	NORMAL = normalize((VIEW_MATRIX * vec4(normalize(n), 0.0)).xyz);
	ALPHA = clamp(a.a, 0.0, 1.0) * step(0.0, layer);
}

void light() {
	// half-lambert, same as the live shader
	float ndl = dot(NORMAL, LIGHT) * 0.5 + 0.5;
	float ramp = smoothstep(0.2, 0.85, ndl);
	DIFFUSE_LIGHT += ALBEDO * LIGHT_COLOR * ATTENUATION * ramp;
}
