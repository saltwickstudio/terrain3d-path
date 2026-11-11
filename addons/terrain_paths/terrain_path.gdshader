// mesh is a terrain-hugging grid, shader cuts the path out of it
// UV.x = dist from path in half-widths (radial at the ends), UV2.x = same but signed, UV.y = metres along
// depth_draw_never so post outlines skip it, verts pulled toward camera to beat far terrain LODs
shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, diffuse_burley, specular_disabled;

uniform int pattern = 0; // 0 MUD, 1 GRAVEL, 2 PAVED, 3 ROAD, 4 TEXTURE, 5 STONES
// rgb = colour, a = height. texture_tile = metres per repeat
uniform sampler2D surface_texture : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform float texture_tile = 2.0;
uniform vec4 base_color : source_color = vec4(0.56, 0.45, 0.31, 1.0);
uniform vec4 wear_color : source_color = vec4(0.66, 0.56, 0.41, 0.6);
uniform vec4 pattern_color : source_color = vec4(0.42, 0.32, 0.21, 1.0);
uniform vec4 pattern_color_2 : source_color = vec4(0.7, 0.6, 0.45, 1.0);
uniform vec4 rim_color : source_color = vec4(0.36, 0.3, 0.17, 1.0);
uniform float rim_width = 0.18;
uniform float wear_width = 0.4;
uniform float feather = 0.25;
uniform float edge_hardness = 0.6;
uniform float wobble = 0.22;
uniform float wobble_scale = 2.2;
uniform float ragged = 0.12;
uniform float pattern_scale = 1.4;
uniform float pattern_amount = 0.55;
uniform float mottle = 0.35;
uniform float bump_strength = 1.0;
uniform float stone_gap = 0.12;       // fraction of a stone
uniform float stone_roundness = 0.45; // 0 slabs, 1 pebbles
uniform float gap_opacity = 0.0;      // 0 = terrain shows through the gaps
uniform float stone_height = 0.06;    // m, drives the side face
uniform float stone_bevel = 0.05;    // m
uniform float stone_roughness = 0.5;
uniform float stone_shadow = 0.35;
uniform float stone_shadow_width = 0.08; // m
uniform bool square_ends = false;
uniform bool feather_ends = false;   // dissolve over the end segment (CUSTOM0.w)
uniform float end_patch_size = 1.0;  // m
uniform float end_breakup = 0.7;     // 0 smooth gradient, 1 all noise
uniform float end_softness = 0.3;
uniform float end_opacity_fade = 0.0;
uniform float end_spread = 1.0;      // x end segment length
uniform float end_taper = 1.0;       // tip width x path width
uniform float end_fade_start = 0.0;
uniform bool edging = false;
uniform float edging_width = 0.25;
uniform vec4 edging_color : source_color = vec4(0.55, 0.53, 0.5, 1.0);
uniform float edging_block_length = 0.9;
// centre line (solid at dash_gap 0) + edge lines
uniform bool markings = false;
uniform vec4 line_color : source_color = vec4(0.93, 0.92, 0.86, 0.9);
uniform float line_width = 0.12;
uniform float dash_length = 3.0;
uniform float dash_gap = 6.0;
uniform float edge_line_inset = 0.3;
// fillet radius (m) where a branch meets its parent
uniform float junction_radius = 0.0;

// set per path from script
uniform float half_width = 1.0;
uniform float depth_pull = 0.04;
uniform float opacity = 1.0;
// per joint: xz + mitre normal, offs = distance along the curve
uniform vec4 run_nodes[128];
uniform float run_offs[128];
uniform int run_count = 0;
uniform bool run_closed = false;

varying vec3 v_world;
varying vec4 v_custom1;  // xy = 2nd curve lateral (99 = none) + distance along, z = inset from a block edge, w = z in use
varying vec4 v_custom;   // CUSTOM0: |lateral|, 2nd curve dist, joined end, end seg length

// hash without sine, Dave Hoskins (shadertoy 4djSRW)
float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

vec2 hash22(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.xx + p3.yz) * p3.zy);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash12(i), hash12(i + vec2(1.0, 0.0)), u.x),
			mix(hash12(i + vec2(0.0, 1.0)), hash12(i + vec2(1.0, 1.0)), u.x), u.y);
}

float fbm(vec2 p) {
	float a = 0.5;
	float s = 0.0;
	for (int i = 0; i < 3; i++) {
		s += vnoise(p) * a;
		p = p * 2.03 + vec2(17.1, 9.7);
		a *= 0.5;
	}
	return s / 0.875;
}

// x = F1, y = F2 - F1, zw = cell id
vec4 voronoi(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	float f1 = 8.0;
	float f2 = 8.0;
	vec2 id = vec2(0.0);
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			vec2 g = vec2(float(x), float(y));
			vec2 o = hash22(i + g) * 0.8 + 0.1;
			float d = length(g + o - f);
			if (d < f1) {
				f2 = f1;
				f1 = d;
				id = i + g;
			} else if (d < f2) {
				f2 = d;
			}
		}
	}
	return vec4(f1, f2 - f1, id);
}

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_custom = CUSTOM0;
	v_custom1 = CUSTOM1;
	vec4 vp = MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	float dist = length(vp.xyz);
	vp.xyz -= (vp.xyz / max(dist, 0.001)) * (depth_pull + dist * 0.0025);
	POSITION = PROJECTION_MATRIX * vp;
}

// x = coverage, y = tone hash, z = dome height
vec3 pebbles(vec2 p, float density) {
	vec3 best = vec3(0.0, 0.0, 0.0);
	vec2 i = floor(p);
	vec2 f = fract(p);
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			vec2 g = vec2(float(x), float(y));
			vec2 id = i + g;
			if (hash12(id + 91.7) > density) {
				continue;
			}
			vec2 o = hash22(id);
			float ang = hash12(id + 4.3) * 6.2832;
			vec2 d = g + o - f;
			d = mat2(vec2(cos(ang), sin(ang)), vec2(-sin(ang), cos(ang))) * d;
			d.y *= 1.0 + hash12(id + 8.1) * 0.9;            // ovals
			float r = mix(0.28, 0.55, hash12(id + 2.9));
			float k = 1.0 - length(d) / r;
			if (k > best.x) {
				best = vec3(k, hash12(id + 5.5), sqrt(max(k, 0.0)) * r);
			}
		}
	}
	return vec3(smoothstep(0.0, 0.12, best.x), best.y, best.z);
}

// voronoi slabs, loosely after KayKit's path tiles
// x = dist into the stone (< 0 in the gap), y = tone hash, zw = centre. all in stone units
// edge is a smooth min over the bisectors, that's what rounds the corners
vec4 stones(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 mg = vec2(0.0);
	vec2 mr = vec2(0.0);
	float md = 8.0;
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			vec2 g = vec2(float(x), float(y));
			vec2 r = g + hash22(i + g) * 0.85 + 0.075 - f;
			float d = dot(r, r);
			if (d < md) {
				md = d;
				mr = r;
				mg = g;
			}
		}
	}
	float k = mix(0.004, 0.1, stone_roundness);
	float acc = 0.0;
	for (int y = -2; y <= 2; y++) {
		for (int x = -2; x <= 2; x++) {
			vec2 g = mg + vec2(float(x), float(y));
			vec2 r = g + hash22(i + g) * 0.85 + 0.075 - f;
			vec2 dr = r - mr;
			if (dot(dr, dr) > 1e-5) {
				acc += exp(-dot(0.5 * (mr + r), normalize(dr)) / k);
			}
		}
	}
	vec2 id = i + mg;
	float edge = -k * log(max(acc, 1e-12));
	float gap = stone_gap * 0.5 * (0.6 + 0.8 * hash12(id + 13.1));
	edge += (vnoise(p * 4.0 + id * 3.7) - 0.5) * 0.025;   // wonky sides
	return vec4(edge - gap, hash12(id + 5.5), p + mr);
}

// x = lateral, y = along, z = dist to nearest mitre (1e3 = none), w = run index
// each run owns the wedge between its mitre planes, v is just a hint for which to test
vec4 run_coords(vec2 xz, float v, float s) {
	if (run_count < 2) {
		return vec4(s * half_width, v, 1e3, 0.0);
	}
	int lo = 0;
	int hi = run_count - 2;
	for (int it = 0; it < 8; it++) {
		if (lo < hi) {
			int mid = (lo + hi + 1) / 2;
			if (run_offs[mid] <= v) {
				lo = mid;
			} else {
				hi = mid - 1;
			}
		}
	}
	vec4 best = vec4(0.0);
	float best_l = 1e9;
	vec4 hint = vec4(0.0);
	for (int j = -2; j <= 2; j++) {
		int k = clamp(lo + j, 0, run_count - 2);
		vec4 a = run_nodes[k];
		vec4 b = run_nodes[k + 1];
		vec2 d = normalize(b.xy - a.xy);
		vec2 rel = xz - a.xy;
		float s0 = dot(rel, a.zw);
		float s1 = dot(b.xy - xz, b.zw);
		float lat = dot(rel, vec2(-d.y, d.x));
		// open ends never get cut
		bool first = k == 0 && !run_closed;
		bool last = k == run_count - 2 && !run_closed;
		vec4 c = vec4(lat, run_offs[k] + dot(rel, d), min(first ? 1e3 : s0, last ? 1e3 : s1), float(k));
		if (j == 0) {
			hint = c;
		}
		if ((s0 >= 0.0 || first) && (s1 > 0.0 || last) && abs(lat) < best_l) {
			best_l = abs(lat);
			best = c;
		}
	}
	return best_l < 1e8 ? best : hint;
}

// two polished tracks per lane
float tyre_tracks(float lat) {
	float lane = half_width * 0.5;
	float track = min(abs(lat - (lane - 0.8)), abs(lat - (lane + 0.8)));
	return 1.0 - smoothstep(0.2, 0.45, track);
}

float centre_line(float lat, float v, float lw) {
	float laa = max(fwidth(lat), 0.002);
	float c = 1.0 - smoothstep(lw - laa, lw + laa, abs(lat));
	if (dash_gap > 0.0) {
		float per = dash_length + dash_gap;
		float t = mod(v, per);
		// > 0 inside a dash
		float dv = t < dash_length ? min(t, dash_length - t) : -min(t - dash_length, per - t);
		float vaa = max(fwidth(v), 0.002);
		c *= smoothstep(-vaa, vaa, dv);
	}
	return c;
}

// polynomial smin
float smin(float a, float b, float k) {
	float h = max(k - abs(a - b), 0.0) / max(k, 1e-4);
	return min(a, b) - h * h * k * 0.25;
}

float seg_dist(vec2 p, vec2 a, vec2 b) {
	vec2 pa = p - a;
	vec2 ba = b - a;
	return length(pa - ba * clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0));
}

// no marks on the slab bevel
float bevel_mask(float m) {
	return smoothstep(0.1, 0.16, m);
}

// rgb = colour, a = height ~0..1 (feeds the bump)
vec4 surface(vec2 xz, float s, float v, vec4 rc) {
	vec3 col = base_color.rgb;
	float h = 0.5;
	float ps = max(pattern_scale, 0.05);
	if (pattern == 0) {
		// MUD - puddle blotches, leaf flecks
		float p = fbm(xz / ps);
		float puddle = smoothstep(0.6, 0.63, p);
		col = mix(col, pattern_color.rgb, puddle * pattern_amount);
		vec2 cell = floor(xz / 0.35);
		vec2 fl = fract(xz / 0.35) - hash22(cell) * 0.6 - 0.2;
		float fleck = step(0.88, hash12(cell + 3.1)) * step(length(fl * vec2(1.0, 1.8)), 0.13);
		col = mix(col, pattern_color_2.rgb, fleck * pattern_amount);
		h = 0.5 + (fbm(xz * 0.6 + 5.0) - 0.5) * 0.5 - smoothstep(0.45, 0.75, p) * 0.25;   // lumps + puddle dips
	} else if (pattern == 1) {
		// GRAVEL - two sparse pebble layers over grit, avoids a visible cell grid
		float grit = vnoise(xz / ps * 2.7);
		col = mix(col, mix(pattern_color.rgb, pattern_color_2.rgb, step(0.5, grit)), 0.25 * pattern_amount);
		h = 0.35 + grit * 0.1;
		vec3 big = pebbles(xz / ps + vec2(3.1, 7.7), 0.55);
		vec3 small = pebbles(xz / (ps * 0.5) + vec2(-11.0, 2.0), 0.7);
		vec3 t1 = big.y < 0.35 ? pattern_color_2.rgb : (big.y < 0.7 ? mix(col, pattern_color.rgb, 0.6) : col * 1.08);
		vec3 t2 = small.y < 0.5 ? pattern_color.rgb : pattern_color_2.rgb;
		col = mix(col, t2, small.x * pattern_amount);
		col = mix(col, t1, big.x * pattern_amount);
		// only the odd big one gets height, all of them looks noisy
		h = mix(h, 0.3 + big.z * 1.4, big.x * step(0.6, big.y));
	} else if (pattern == 4) {
		// TEXTURE - sampled in path space (rc.xy) so it follows the curve
		vec4 t = texture(surface_texture, rc.xy / max(texture_tile, 0.05));
		col = t.rgb;
		h = t.a;
	} else if (pattern == 5) {
		// STONES - done in fragment(), flat here so no bump
		h = 0.5;
	} else if (pattern == 3) {
		// ROAD - speckle fades out sub-pixel, tyre tracks are in fragment()
		vec2 gq = xz / ps * 22.0;
		float fine = 1.0 - smoothstep(0.35, 1.0, length(fwidth(gq)));
		float g = vnoise(gq);
		float g2 = vnoise(gq * 2.3 + 31.0);
		col = mix(col, pattern_color_2.rgb, smoothstep(0.72, 0.9, g) * pattern_amount * 0.6 * fine);
		col = mix(col, pattern_color.rgb, smoothstep(0.3, 0.12, g2) * pattern_amount * 0.7 * fine);
		float repair = smoothstep(0.66, 0.68, fbm(xz / (ps * 7.0) + 13.0));
		col = mix(col, pattern_color.rgb, repair * pattern_amount * 0.6);
		h = 0.5 + (g - 0.5) * 0.15 * fine - repair * 0.04;
	} else {
		// PAVED - uneven rows, random bond, laid per run (rc) so slabs stay square round bends
		vec2 q = rc.xy / ps;
		q += (vec2(vnoise(q * 1.3), vnoise(q * 1.3 + 17.0)) - 0.5) * 0.12;   // wobble
		float row = floor(q.y) + rc.w * 1000.0;   // new tones per run so mitres show
		float fy = fract(q.y);
		float slab_w = mix(0.9, 1.8, hash12(vec2(row, 3.0)));
		q.x = q.x / slab_w + hash12(vec2(row, 9.0));
		vec2 id = vec2(floor(q.x), row);
		vec2 f = vec2(fract(q.x), fy);
		float h1 = hash12(id);
		float h2 = hash12(id + 7.0);
		vec3 stone = h1 < 0.45 ? col : (h1 < 0.8 ? pattern_color_2.rgb : mix(col, pattern_color.rgb, 0.35));
		col = mix(col, stone, pattern_amount);
		col *= 0.94 + (vnoise(xz * 3.0 + id) - 0.5) * 0.12;               // weathering
		float m = min(min(f.x, 1.0 - f.x) * slab_w * 1.3, min(f.y, 1.0 - f.y));
		m = min(m, rc.z / ps);   // mitre is a mortar line too
		// smoothstep widened to >= 1px via fwidth, stops far mortar crawling
		float aa = max(fwidth(m), 0.001);
		float mortar = 1.0 - smoothstep(0.042 - max(0.0125, aa), 0.042 + max(0.0125, aa), m + (vnoise(xz * 9.0) - 0.5) * 0.02);
		// marks on ~1 brick in 6, all rolled per brick
		// md = dist to mark edge (< 0 inside), feeds a crisp tint and a soft groove in the height
		float md = 1.0;
		float mark_mask = 0.0;
		float h3 = hash12(id + 13.0);
		vec2 fs = vec2(f.x * slab_w, f.y);                       // slab-local
		vec2 c0 = vec2(mix(0.2, slab_w - 0.3, hash12(id + 21.0)), mix(0.22, 0.72, hash12(id + 22.0)));
		if (h3 > 0.94) {
			// 1-3 dots
			for (int k = 0; k < 3; k++) {
				float fk = float(k);
				if (k == 0 || hash12(id + 30.0 + fk) > 0.45) {
					vec2 o = (hash22(id + 40.0 + fk) - 0.5) * vec2(0.22, 0.18) * min(fk, 1.0);
					float rad = mix(0.016, 0.036, hash12(id + 50.0 + fk));
					md = min(md, length(fs - c0 - o) - rad);
				}
			}
			mark_mask = bevel_mask(m);
		} else if (h3 > 0.89) {
			// 1-3 dashes, slight tilt
			float ang = (hash12(id + 60.0) - 0.5) * 0.7;
			vec2 dir = vec2(cos(ang), sin(ang));
			vec2 nrm = vec2(-dir.y, dir.x);
			for (int k = 0; k < 3; k++) {
				float fk = float(k);
				if (k == 0 || hash12(id + 61.0 + fk) > 0.4) {
					float len = mix(0.06, 0.2, hash12(id + 62.0 + fk));
					vec2 st = c0 + nrm * fk * mix(0.06, 0.1, hash12(id + 63.0 + fk))
							+ dir * (hash12(id + 64.0 + fk) - 0.5) * 0.08;
					md = min(md, seg_dist(fs, st, st + dir * len) - 0.016);
				}
			}
			mark_mask = bevel_mask(m);
		} else if (h3 > 0.84) {
			// crack - starts at an edge, 2-3 kinked segments, allowed onto the bevel
			float edge_pick = hash12(id + 25.0);
			vec2 e0;
			vec2 inward;
			if (edge_pick < 0.3) {
				e0 = vec2(mix(0.15, slab_w - 0.15, hash12(id + 26.0)), 1.02); inward = vec2(0.0, -1.0);
			} else if (edge_pick < 0.6) {
				e0 = vec2(mix(0.15, slab_w - 0.15, hash12(id + 26.0)), -0.02); inward = vec2(0.0, 1.0);
			} else if (edge_pick < 0.8) {
				e0 = vec2(-0.02, mix(0.2, 0.8, hash12(id + 26.0))); inward = vec2(1.0, 0.0);
			} else {
				e0 = vec2(slab_w + 0.02, mix(0.2, 0.8, hash12(id + 26.0))); inward = vec2(-1.0, 0.0);
			}
			vec2 side = vec2(-inward.y, inward.x);
			float total = mix(0.18, 0.5, hash12(id + 27.0));
			vec2 p0 = e0;
			float best = 1.0;
			for (int k = 0; k < 3; k++) {
				float fk = float(k);
				if (k < 2 || hash12(id + 70.0) > 0.5) {
					vec2 p1 = p0 + inward * total * mix(0.25, 0.5, hash12(id + 71.0 + fk))
							+ side * (hash12(id + 72.0 + fk) - 0.5) * 0.2;
					best = min(best, seg_dist(fs, p0, p1));
					p0 = p1;
				}
			}
			md = best - 0.018;
			mark_mask = smoothstep(0.025, 0.04, m);
		}
		float mark = (1.0 - smoothstep(-max(0.004, aa), max(0.004, aa), md)) * mark_mask;          // tint
		float groove = (1.0 - smoothstep(-0.03, 0.05, md)) * mark_mask;      // height
		groove = groove * groove * (3.0 - 2.0 * groove);
		float sunk = step(0.9, h2);
		col = mix(col, col * 0.85, sunk);
		col = mix(col, pattern_color.rgb, mortar * pattern_amount);
		// mostly height, tint kept faint so they don't look painted
		col = mix(col, col * 0.93, mark);
		float bevel = smoothstep(0.03, 0.16, m);
		h = mix(0.15, 0.6 + (h1 - 0.5) * 0.12 - sunk * 0.12, bevel) - groove * 0.05;
	}
	return vec4(col, h);
}

// edge multiplier, 1 = nominal. keyed on world xz - distance-along jumps on the inside of a bend and streaks
float edge_shape(vec2 xz, float seed) {
	float w = (vnoise(xz / max(wobble_scale, 0.01) + seed) - 0.5) * 2.0 * wobble;
	float bite = smoothstep(0.55, 0.95, vnoise(xz / max(wobble_scale * 0.18, 0.01) + 40.0 + seed));
	return max(1.0 + w - bite * ragged, 0.2);
}

// two scales, amplitude follows the fade width
float fringe_noise(vec2 xz, float seed, float soft) {
	float n = (fbm(xz * 0.7 + seed) - 0.5) * 0.6 + (fbm(xz * 4.0 + seed + 11.0) - 0.5) * 0.4;
	return n * (0.08 + soft * 0.15);
}

// ~-1..1, warped clumps (~1 m) + tufts (~20 cm)
float dissolve_noise(vec2 xz, float seed) {
	vec2 p = xz + (vec2(vnoise(xz * 1.3 + seed), vnoise(xz * 1.3 + seed + 7.0)) - 0.5) * 0.7;
	float broad = fbm(p * 1.1 + seed) - 0.5;
	float mid = fbm(xz * 3.5 + seed + 19.0) - 0.5;   // unwarped, otherwise it streaks
	return clamp(broad * 3.0 + mid * 2.2, -1.0, 1.0);
}

// 0 at fade start, 1 at the end point. over = metres past the end
float end_progress(float over, float seg) {
	float fl = max(seg * end_spread, 0.1);
	float g = clamp((over + fl) / fl, 0.0, 1.0);
	return clamp((g - end_fade_start) / max(1.0 - end_fade_start, 0.05), 0.0, 1.0);
}

// in half-widths, hardness never fully cancels a big feather
float fade_width() {
	return max(feather * 10.0 * (1.0 - 0.85 * edge_hardness), 0.015);
}

// 1 inside, 0 outside. straddles the edge 30/70
float edge_fade(float d, float soft) {
	float t = smoothstep(max(1.0 - soft * 0.3, 0.35), 1.0 + soft * 0.7, d);
	return 1.0 - t * t * (3.0 - 2.0 * t);
}

// run coords only for paving and kerbs
vec4 laid_coords(vec2 xz, float v, float s) {
	if (pattern == 2 || edging) {
		return run_coords(xz, v, s);
	}
	return vec4(s * half_width, v, 1e3, 0.0);
}

// full height field for the bump, sampled at world offsets - dFdx/dFdy is per 2x2 quad and stair-steps slab bevels
float relief(vec2 xz, float s, float v, float dk) {
	vec4 rc = laid_coords(xz, v, s);
	float h = surface(xz, s, v, rc).a;
	if (edging) {
		float kw = clamp(edging_width / half_width, 0.02, 0.9);
		float t = (dk - (1.0 - kw)) / kw;
		float kerb = step(0.0, t) * step(t, 1.0);
		float bl = max(edging_block_length, 0.05);
		float bv = rc.y / bl;
		float jd = min(min(fract(bv), 1.0 - fract(bv)) * bl, rc.z);
		float joint = 1.0 - smoothstep(0.015, 0.03, jd);
		float bevel = smoothstep(0.0, 0.18, t) * smoothstep(1.0, 0.82, t);
		h = mix(h, 1.1 - joint * 0.3, kerb * bevel);
		h = mix(h, 0.4, smoothstep(0.995, 1.0, dk));
	}
	return h;
}

void fragment() {
	float r = UV.x;
	float s = UV2.x;
	float v = UV.y;
	float over = UV2.y;      // m past the end, < 0 inside
	vec2 xz = v_world.xz;
	// joined ends always cut on the mitre
	bool cut_end = square_ends || v_custom.z > 0.5;
	if (cut_end || feather_ends) {
		r = v_custom.x;      // lateral only
	}
	// fillet - smin with the 2nd road (99 = none)
	float jk = junction_radius / max(half_width, 0.01);
	r = smin(r, v_custom.y, jk);
	if (feather_ends) {
		float tg = end_progress(over, v_custom.w);
		r /= max(mix(1.0, end_taper, tg * tg * (3.0 - 2.0 * tg)), 0.02);
	}
	// kerbs run straight, no meander
	float edge = edging ? 1.0 : edge_shape(xz, 0.0);
	float soft = fade_width();
	float dk = r / edge;     // no fringe - kerbs and hard lines use this
	float dd = dk + fringe_noise(xz, 0.0, soft);

	// stones cut their own edge below
	float alpha = pattern == 5 ? 1.0 : edge_fade(dd, soft);
	float outside_kerb = 0.0;
	if (edging) {
		// hard boundary, only a worn band in rim colour bleeds past it
		float kaa = max(fwidth(dk), 0.002);              // AA
		float inner = 1.0 - smoothstep(1.0 - kaa, 1.0, dk);
		// noise scales with feather so zero feather = nothing past the kerb
		float out_d = max(dk - 1.0, 0.0) + (fbm(xz * 2.5 + 7.0) - 0.5) * soft * 0.4;
		float worn = rim_color.a * (1.0 - smoothstep(0.0, soft * 0.7, out_d)) * smoothstep(0.0, 0.05, feather);
		worn *= 1.0 - inner;
		alpha = inner + worn;
		outside_kerb = 1.0 - inner;
	}
	if (cut_end) {
		alpha *= 1.0 - smoothstep(0.0, max(fwidth(over), 0.005), over);   // stop line
	}
	float paint_keep = 1.0;
	if (feather_ends) {
		// noise threshold sweeps along the end segment, finishes at the end point
		// paint wears away first
		float g = end_progress(over, v_custom.w);
		// threshold runs past the noise clamp (+-1) + softness so nothing is touched before the fade
		float n = dissolve_noise(xz / max(end_patch_size, 0.05), 41.0);
		float es = mix(0.04, 0.8, end_softness);
		float span = 1.0 + es;
		float keep = smoothstep(-es, es, n - mix(-span, span, g));
		keep = mix(1.0 - g, keep, end_breakup);
		alpha *= keep * smoothstep(1.0, 0.8, g) * mix(1.0, 1.0 - g, end_opacity_fade);             // gone at the end point
		paint_keep = smoothstep(-es, es, n - mix(-span, span, min(g * 1.8, 1.0)));
	}

	vec4 rc = laid_coords(xz, v, s);
	vec4 surf = surface(xz, s, v, rc);
	vec3 col = surf.rgb;
	vec3 stone_n = vec3(0.0);   // world normal for light(), 0 = leave NORMAL
	if (pattern == 5) {
		// STONES - fake depth, parallax along the view ray: top at xz + V.xz * h / V.y
		// top there = top face, else footprint here = side face, else gap
		// shoulder and sides get real normals for light()
		float ps5 = max(pattern_scale, 0.05);
		vec3 vdir = normalize(CAMERA_POSITION_WORLD - v_world);
		vec2 par = vdir.xz / max(vdir.y, 0.2) * stone_height;
		vec2 qt = (xz + par) / ps5;
		vec4 top = stones(qt);
		vec4 foot = stones(xz / ps5);
		float dt = top.x * ps5;              // m
		float df = foot.x * ps5;             // m
		float aa = max(fwidth(dt), 0.002);
		float is_top = smoothstep(-aa, aa, dt);
		float is_foot = smoothstep(-aa, aa, df);
		// outward = down the distance field slope
		const float SE = 0.01;
		vec2 gd = vec2(stones(qt + vec2(SE, 0.0)).x - top.x, stones(qt + vec2(0.0, SE)).x - top.x);
		vec2 out_dir = length(gd) > 1e-6 ? -normalize(gd) : vec2(0.0);
		vec3 base_n = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
		vec2 wq = xz + par;
		float rough = fbm(wq * 6.0 + top.zw * 13.0) - 0.5;
		vec2 rn = vec2(vnoise(wq * 9.0 + 3.1), vnoise(wq * 9.0 + 7.7)) - 0.5;
		// top: tone, mottle, shoulder tips toward the rim
		vec3 topc = base_color.rgb * (1.0 + (top.y - 0.5) * 0.08 * pattern_amount + rough * 0.07 * stone_roughness);
		float sh = smoothstep(0.0, stone_bevel * 1.8, dt);
		sh = sh * sh * (3.0 - 2.0 * sh);
		topc = mix(pattern_color_2.rgb, topc, mix(0.5, 1.0, sh));
		vec3 n_top = normalize(vec3(0.0, 1.0, 0.0) + vec3(out_dir.x, 0.0, out_dir.y) * (1.0 - sh) * 1.4
				+ vec3(rn.x, 0.0, rn.y) * 0.25 * stone_roughness);
		vec3 sidec = pattern_color_2.rgb * mix(0.82, 0.95, smoothstep(0.0, stone_height, df));
		vec3 n_side = normalize(vec3(out_dir.x, 0.0, out_dir.y) + vec3(0.0, 0.35, 0.0));
		// keep a stone if its centre is inside, never slice one in half
		// r is a distance field so slope is exactly 1 / half_width, only the direction needs derivatives
		mat2 m_sx = mat2(dFdx(xz), dFdy(xz));
		vec2 gr = vec2(0.0);
		if (abs(determinant(m_sx)) > 1e-12) {
			vec2 g = inverse(transpose(m_sx)) * vec2(dFdx(r), dFdy(r));
			gr = length(g) > 1e-6 ? normalize(g) / max(half_width, 0.01) : vec2(0.0);
		}
		vec2 c_top = top.zw * ps5;           // world xz, parallax only moves the lookup
		vec2 c_ft = foot.zw * ps5;
		float keep_top = step(r + dot(gr, c_top - xz), (1.0 + (top.y - 0.5) * ragged * 2.0) * edge_shape(c_top, 0.0));
		float keep_ft = step(r + dot(gr, c_ft - xz), (1.0 + (foot.y - 0.5) * ragged * 2.0) * edge_shape(c_ft, 0.0));
		// kerb is the edge - stones cut against its inner face
		float in_kerb = 1.0;
		if (edging) {
			float k_in = 1.0 - clamp(edging_width / half_width, 0.02, 0.9);
			float kaa = max(fwidth(dk), 0.002);
			in_kerb = 1.0 - smoothstep(k_in - kaa, k_in, dk);
			keep_top = in_kerb;
			keep_ft = in_kerb;
		}
		float t_on = is_top * keep_top;
		float f_on = is_foot * keep_ft * (1.0 - t_on);
		float cov = t_on + f_on;
		// contact shadow
		float near = keep_ft * (1.0 - smoothstep(0.0, stone_shadow_width, -df));
		float shade = near * stone_shadow * (1.0 - cov);
		vec3 groundc = vec3(0.03, 0.05, 0.04);
		col = topc * t_on + sidec * f_on + (pattern_color.rgb * gap_opacity) * (1.0 - cov);
		vec3 n_mix = normalize(n_top * t_on + n_side * f_on + base_n * (1.0 - cov) + vec3(0.0, 1e-4, 0.0));
		// sub-pixel stones settle to a mean, no shimmer
		float far = smoothstep(0.2, 0.6, length(fwidth(xz / ps5)));
		cov = mix(cov, (1.0 - stone_gap) * step(dk, 1.0), far);
		shade *= 1.0 - far;
		col = mix(col, base_color.rgb * 0.95, far);
		n_mix = normalize(mix(n_mix, base_n, far));
		float gap_a = max(gap_opacity * edge_fade(dd, soft), shade);
		vec3 gapc = mix(groundc, pattern_color.rgb, gap_opacity * edge_fade(dd, soft) / max(gap_a, 1e-4));
		float a_out = cov + gap_a * (1.0 - cov);
		col = (col * cov + gapc * gap_a * (1.0 - cov)) / max(a_out, 1e-4);
		stone_n = mix(n_mix, base_n, (1.0 - cov) * (1.0 - step(0.001, gap_a)));
		alpha *= mix(1.0, a_out, in_kerb);
		stone_n = mix(base_n, stone_n, in_kerb);
	}

	// low-freq mottle
	float m = fbm(xz / 5.0 + 3.7);
	col *= mix(1.0, 0.88, smoothstep(0.52, 0.56, m) * mottle);
	col *= mix(1.0, 1.06, smoothstep(0.30, 0.26, m) * mottle);

	// worn centre line, own edge_shape seed so it doesn't track the outer edge
	float ww = max(wear_width, 0.01);
	float wsoft = soft * 0.6;
	float wd = r / (ww * edge_shape(xz, 61.0)) + fringe_noise(xz, 23.0, wsoft);
	float wear = edge_fade(wd, wsoft);
	col = mix(col, wear_color.rgb, wear * wear_color.a);

	// markings - primary road (s, v) runs through a junction, secondary (v_custom1) stops at it
	bool has2 = v_custom1.x < 50.0;
	float outside1 = has2 ? smoothstep(1.0, 1.0 + max(fwidth(s), 0.002), abs(s)) : 0.0;
	if (pattern == 3) {
		float tr = tyre_tracks(abs(s) * half_width);
		if (has2) {
			tr = mix(tr, tyre_tracks(abs(v_custom1.x) * half_width), outside1);
		}
		col *= 1.0 - tr * 0.07;
	}
	if (markings) {
		float lw = line_width * 0.5;
		float paint = centre_line(s * half_width, v, lw);
		if (has2) {
			paint = max(paint, centre_line(v_custom1.x * half_width, v_custom1.y, lw) * outside1);
		}
		if (edge_line_inset > 0.0) {
			// edge lines follow the smin of both roads
			float e = smin(v_custom.x, v_custom.y, jk) * half_width;
			float eaa = max(fwidth(e), 0.002);
			float off = half_width - edge_line_inset;
			paint = max(paint, 1.0 - smoothstep(lw - eaa, lw + eaa, abs(e - off)));
		}
		paint *= line_color.a * (0.85 + 0.15 * vnoise(xz * 5.0)) * paint_keep;
		col = mix(col, line_color.rgb, paint);
	}

	if (rim_width > 0.0 && !edging) {   // kerb replaces it
		// rim colour all the way out through the feather
		float rim_soft = clamp(soft * 0.25, 0.01, 0.3);
		float rim_in = smoothstep(1.0 - rim_width - rim_soft, 1.0 - rim_width + rim_soft, dd);
		float rim = rim_in;
		col = mix(col, rim_color.rgb, rim * rim_color.a);
	}

	// kerb blocks - bevel in the bump, lit top, shadow just inside
	if (edging) {
		float kw = clamp(edging_width / half_width, 0.02, 0.9);
		float t = (dk - (1.0 - kw)) / kw;                 // 0 inner, 1 outer
		float kerb = step(0.0, t) * step(t, 1.0);
		float bl = max(edging_block_length, 0.05);
		float bv = rc.y / bl;
		float side_seed = s >= 0.0 ? 1.0 : -1.0;
		float tone = hash12(vec2(floor(bv) + rc.w * 1000.0, side_seed));
		float jd = min(min(fract(bv), 1.0 - fract(bv)) * bl, rc.z);
		float jaa = max(fwidth(jd), 0.001);
		float joint = 1.0 - smoothstep(0.022 - max(0.0075, jaa), 0.022 + max(0.0075, jaa), jd);
		vec3 kc = edging_color.rgb * (0.92 + tone * 0.14);
		kc = mix(kc, kc * 0.6, joint);
		float bevel = smoothstep(0.0, 0.18, t) * smoothstep(1.0, 0.82, t);
		kc *= 0.9 + bevel * 0.18;                        // darker chamfers
		col = mix(col, kc, kerb);
		float shadow = smoothstep(-0.12, 0.0, t) * (1.0 - kerb);
		col *= 1.0 - shadow * 0.3 * (1.0 - step(1.0, t));
		// worn verge, flat in relief()
		col = mix(col, rim_color.rgb, outside_kerb);
	}

	ALBEDO = col;
	ROUGHNESS = 1.0;

	// bump - finite differences of relief() at +-EPS in world space, path coords at the offsets via screen jacobian
	float bump = bump_strength * (1.0 - smoothstep(15.0, 40.0, length(VERTEX)));
	// fade out when the pattern goes sub-pixel
	bump *= 1.0 - smoothstep(0.08, 0.25, length(fwidth(xz / max(pattern_scale, 0.05))));
	bump *= smoothstep(0.25, 0.95, alpha);
	if (bump > 0.001) {
		const float EPS = 0.006;
		mat2 m_sx = mat2(dFdx(xz), dFdy(xz));          // screen delta to world xz
		vec3 q_dx = vec3(dFdx(s), dFdx(v), dFdx(dk));
		vec3 q_dy = vec3(dFdy(s), dFdy(v), dFdy(dk));
		if (abs(determinant(m_sx)) > 1e-12) {
			mat2 inv = inverse(m_sx);
			vec2 wx = inv * vec2(EPS, 0.0);
			vec2 wz = inv * vec2(0.0, EPS);
			vec3 qx = q_dx * wx.x + q_dy * wx.y;
			vec3 qz = q_dx * wz.x + q_dy * wz.y;
			float h0 = relief(xz, s, v, dk);
			float hx = relief(xz + vec2(EPS, 0.0), s + qx.x, v + qx.y, dk + qx.z);
			float hz = relief(xz + vec2(0.0, EPS), s + qz.x, v + qz.y, dk + qz.z);
			vec2 g = vec2(hx - h0, hz - h0) / EPS * pattern_scale * 0.25;
			vec3 gv = (VIEW_MATRIX * vec4(g.x, 0.0, g.y, 0.0)).xyz;
			NORMAL = normalize(NORMAL - gv * bump);
		}
	}
	if (pattern == 5 && dot(stone_n, stone_n) > 0.5) {
		NORMAL = normalize((VIEW_MATRIX * vec4(stone_n, 0.0)).xyz);
	}
	// clips to the block outline
	float on_top = mix(1.0, smoothstep(0.0, 0.03, v_custom1.z), v_custom1.w);
	ALPHA = clamp(alpha, 0.0, 1.0) * opacity * on_top;
}

void light() {
	// soft half-lambert, matches the terrain
	float ndl = dot(NORMAL, LIGHT) * 0.5 + 0.5;
	float ramp = smoothstep(0.2, 0.85, ndl);
	DIFFUSE_LIGHT += ALBEDO * LIGHT_COLOR * ATTENUATION * ramp;
}
