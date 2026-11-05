// Ground of one 128-cell tile of a terrain window, bent onto the inside of the cylinder.
shader_type spatial;

#include "res://terrain/shaders/cylinder_tile.gdshaderinc"
#include "res://terrain/shaders/light_bar.gdshaderinc"

// Material id / 255 (0 dirt, 1 clay, 2 rock, 3 rock face, coloured as rock).
uniform sampler2D material_tex : filter_nearest;
// Albedo by material id, from materials.tres.
uniform vec4 material_color[4] : source_color;
// Cells around the circumference, to wrap the speckle's cell index at theta = 0.
uniform int n_theta;
// Pore water held, 0 dry to 1 full.
uniform sampler2D saturation_tex : filter_nearest;

varying vec2 local_cell;
// The normal's component toward the axis: 1 on flat ground.
varying float up;
// 1 under water, 0 on dry ground.
varying float wet;
// The vertex's texels: loose dirt, m, and saturation, 0..1.
varying float loose_v;
varying float sat_v;
// Cells to the nearest chunk drawn by its mesh (cylinder_tile.gdshaderinc's chunk_dist), and the vertex's
// ground height, for the box's band.
varying float chunk_d;
varying float h_v;

void vertex() {
	ivec2 k = grid_cell(VERTEX);
	local_cell = vec2(k);
	vec2 p = theta_z_of(VERTEX.x, VERTEX.z);
	theta_z = p;
	float h = ground_of(k);
	wet = height_of(water_tex, k) > h + 0.05 ? 1.0 : 0.0;
	loose_v = height_of(loose_tex, k);
	sat_v = texelFetch(saturation_tex, window_texel(k), 0).r;
	// Central differences: a cell spans (R - h) dtheta cell m across and cell m along.
	float sx = (ground_of(k + ivec2(1, 0)) - ground_of(k - ivec2(1, 0))) / (2.0 * (R - h) * dtheta * cell);
	float sz = (ground_of(k + ivec2(0, 1)) - ground_of(k - ivec2(0, 1))) / (2.0 * cell);
	vec3 n = normalize(vec3(-sx, 1.0, -sz));
	up = n.y;
	NORMAL = unbend_normal(VERTEX.x, n);
	bar_up = (VIEW_MATRIX * vec4(mat3(MODEL_MATRIX) * unbend_normal(VERTEX.x, vec3(0.0, 1.0, 0.0)), 0.0)).xyz;
	chunk_d = chunk_dist(p);
	h_v = h;
	float sink = in_hole(p, 0.0) ? 1.0 : (chunk_d < 2.0 ? box_band(h) : 0.0);
	VERTEX = bend(VERTEX.x, VERTEX.z, h - 0.25 * cell * sink);
}

// Value in [0, 1] per integer cell.
float hash(ivec2 p) {
	uint h = (uint(p.x) * 73856093u) ^ (uint(p.y) * 19349663u);
	h = (h ^ (h >> 13u)) * 1274126177u;
	return float(h >> 16u) / 65535.0;
}

void fragment() {
	if (in_hole(theta_z, 1.0) || (chunk_d < 1.0 && box_band(h_v) > 0.0)) {
		discard;
	}
	ivec2 k = ivec2(round(local_cell));
	int id = clamp(int(round(texelFetch(material_tex, window_texel(k), 0).r * 255.0)), 0, 3);
	// A pile of loose dirt: dirt's colour, darker, rougher and more speckled than the ground under it.
	bool pile = loose_v > 0.02;
	id = pile ? 0 : id;
	// A speckle per window cell, keyed to the global cell so it matches across tiles.
	ivec2 g = ivec2(int(round(tile_theta / (dtheta * cell))), int(round(tile_z / cell))) - 64 + k;
	int around = n_theta / int(cell);
	g.x = (g.x + around) % around;
	// Wet dirt darkens fully (40 %) by half saturation: a spill's soak tops out near 0.4, so its halo still reads.
	float damp = min(sat_v * 2.0, 1.0);
	ALBEDO = material_color[id].rgb * (pile ? 0.75 : 1.0) * mix(1.0, 0.6, damp) * mix(0.55, 1.0, smoothstep(0.5, 1.0, up))
			* mix(1.0, 0.7, wet) * (1.0 + (pile ? 0.3 : 0.08) * (hash(g) - 0.5));
	ROUGHNESS = pile ? 1.0 : 0.95;
}
