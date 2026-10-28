// Water of one 128-cell tile of a terrain window: rivers follow their profile, lakes and the sea are flat.
shader_type spatial;
// Two-sided, so the surface also shows from the bed.
render_mode cull_disabled;

#include "res://terrain/shaders/cylinder_tile.gdshaderinc"
#include "res://terrain/shaders/light_bar.gdshaderinc"

// Water depth, m; -1 at dry vertices so the shoreline falls between a wet and a dry vertex.
varying float depth;

void vertex() {
	ivec2 k = grid_cell(VERTEX);
	theta_z = theta_z_of(VERTEX.x, VERTEX.z);
	float s = height_of(surface_tex, k);
	float w = height_of(water_tex, k);
	depth = w > 0.0 ? w - s : -1.0;
	NORMAL = unbend_normal(VERTEX.x, vec3(0.0, 1.0, 0.0));
	bar_up = (VIEW_MATRIX * vec4(mat3(MODEL_MATRIX) * NORMAL, 0.0)).xyz;
	// Dry vertices tuck 1 m under the ground, so shoreline triangles dive out of sight.
	VERTEX = bend(VERTEX.x, VERTEX.z, w > 0.0 ? w : s - 1.0);
}

void fragment() {
	if (depth <= 0.05 || in_hole(theta_z, 0.0)) {
		discard;
	}
	ALBEDO = mix(vec3(0.1, 0.45, 0.4), vec3(0.02, 0.1, 0.18), clamp(depth / 30.0, 0.0, 1.0));
	ALPHA = 0.6;
	ROUGHNESS = 0.1;
}
