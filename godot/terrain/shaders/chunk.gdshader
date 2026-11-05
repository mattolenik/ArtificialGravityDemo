// A touched chunk of the voxel box (chunk_mesh.gd): its surface-nets mesh in station space, the material id
// per vertex in COLOR.r (id / 255) and the loose share in COLOR.g, with the tile shader's colour, pile and
// speckle rules, lit by the light bar as the tiles are and by the headlamp as an ordinary light. Both sides
// are drawn: a tunnel is seen from inside.
shader_type spatial;
render_mode cull_disabled;

varying vec2 theta_z;

#include "res://terrain/shaders/light_bar.gdshaderinc"

// Albedo by material id, from materials.tres.
uniform vec4 material_color[4] : source_color;
uniform float dtheta;
// Station-local z of row 0.
uniform float z0;
uniform int n_theta;
// The hull radius and the box's band: the mesh is complete only between a voxel over the box's floor and a
// voxel under its ceiling, and the ground tile draws the rest, so the fragments outside the band go.
uniform float R = 1e9;
uniform float box_bottom = -1e9;
uniform float box_top = 1e9;

// The normal's component toward the axis: 1 on a flat floor, -1 on a roof.
varying float up;
// The vertex's height over the hull.
varying float h_v;


void vertex() {
	// Cyl.theta_of: 0 straight below the axis, growing spinward.
	theta_z = vec2(atan(VERTEX.x, -VERTEX.y), VERTEX.z);
	vec3 up_local = normalize(vec3(-VERTEX.x, -VERTEX.y, 0.0));
	up = dot(NORMAL, up_local);
	h_v = R - length(VERTEX.xy);
	bar_up = (VIEW_MATRIX * vec4(mat3(MODEL_MATRIX) * up_local, 0.0)).xyz;
}

// Value in [0, 1] per integer cell (tile.gdshader's).
float hash(ivec2 p) {
	uint h = (uint(p.x) * 73856093u) ^ (uint(p.y) * 19349663u);
	h = (h ^ (h >> 13u)) * 1274126177u;
	return float(h >> 16u) / 65535.0;
}

void fragment() {
	if (h_v >= box_top || h_v < box_bottom) {
		discard;
	}
	int id = clamp(int(round(COLOR.r * 255.0)), 0, 3);
	bool pile = COLOR.g > 0.5;
	id = pile ? 0 : id;
	float th = theta_z.x < 0.0 ? theta_z.x + TAU : theta_z.x;
	ivec2 g = ivec2(int(floor(th / dtheta)) % n_theta, int(floor(theta_z.y - z0)));
	ALBEDO = material_color[id].rgb * (pile ? 0.75 : 1.0) * mix(0.55, 1.0, smoothstep(0.5, 1.0, up))
			* (1.0 + (pile ? 0.3 : 0.08) * (hash(g) - 0.5));
	ROUGHNESS = pile ? 1.0 : 0.95;
}
