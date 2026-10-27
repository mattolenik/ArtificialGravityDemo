// Ground of one 128-cell tile of a terrain window, bent onto the inside of the cylinder.
shader_type spatial;

#include "res://terrain/shaders/cylinder_tile.gdshaderinc"

// Material id / 255 (0 dirt, 1 clay, 2 rock).
uniform sampler2D material_tex : filter_nearest;
// Albedo by material id, from materials.tres.
uniform vec4 material_color[3] : source_color;
// Cells around the circumference, to wrap the speckle's cell index at theta = 0.
uniform int n_theta;

varying vec2 local_cell;
// The normal's component toward the axis: 1 on flat ground.
varying float up;
// 1 under water, 0 on dry ground.
varying float wet;

void vertex() {
	ivec2 k = grid_cell(VERTEX);
	local_cell = vec2(k);
	vec2 p = theta_z_of(VERTEX.x, VERTEX.z);
	theta_z = p;
	float h = height_of(surface_tex, k);
	wet = height_of(water_tex, k) > h + 0.05 ? 1.0 : 0.0;
	// Central differences: a cell spans (R - h) dtheta cell m across and cell m along.
	float sx = (height_of(surface_tex, k + ivec2(1, 0)) - height_of(surface_tex, k - ivec2(1, 0))) / (2.0 * (R - h) * dtheta * cell);
	float sz = (height_of(surface_tex, k + ivec2(0, 1)) - height_of(surface_tex, k - ivec2(0, 1))) / (2.0 * cell);
	vec3 n = normalize(vec3(-sx, 1.0, -sz));
	up = n.y;
	NORMAL = unbend_normal(VERTEX.x, n);
	VERTEX = bend(VERTEX.x, VERTEX.z, in_hole(p, 0.0) ? h - 0.25 * cell : h);
}

// Value in [0, 1] per integer cell.
float hash(ivec2 p) {
	uint h = (uint(p.x) * 73856093u) ^ (uint(p.y) * 19349663u);
	h = (h ^ (h >> 13u)) * 1274126177u;
	return float(h >> 16u) / 65535.0;
}

void fragment() {
	if (in_hole(theta_z, 1.0)) {
		discard;
	}
	ivec2 k = ivec2(round(local_cell));
	int id = clamp(int(round(texelFetch(material_tex, window_texel(k), 0).r * 255.0)), 0, 2);
	// A little speckle per window cell, keyed to the global cell so it matches across tiles.
	ivec2 g = ivec2(int(round(tile_theta / (dtheta * cell))), int(round(tile_z / cell))) - 64 + k;
	int around = n_theta / int(cell);
	g.x = (g.x + around) % around;
	ALBEDO = material_color[id].rgb * mix(0.55, 1.0, smoothstep(0.5, 1.0, up)) * mix(1.0, 0.7, wet) * (0.96 + 0.08 * hash(g));
	ROUGHNESS = 0.95;
}
