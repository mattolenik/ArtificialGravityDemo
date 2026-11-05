// The whole station at 32 m, from the w x h macro maps: a PlaneMesh of (w + 1) x (h + 2) vertices at
// unit spacing, VERTEX.xz = grid point (i, j) - (w / 2, (h - 1) / 2), wrapped once around the cylinder
// in station space. Vertex (i, j) sits at macro cell centre (i, j); column w repeats column 0, and rows
// -1 and h repeat the end rows at the station ends. Standing water shows as a flat tinted surface.
// Inside either finer window the mesh gives way: it reaches one of its cells under the window's edge,
// sunk to a quarter cell under the ground, so no crack opens between the levels, and is discarded
// beyond that.
shader_type spatial;

uniform sampler2D surface_tex : filter_nearest;
uniform sampler2D water_tex : filter_nearest;
uniform sampler2D bedrock_tex : filter_nearest;
// Albedo by material id, from materials.tres: dirt where there is cover, rock where bedrock is bare.
uniform vec4 material_color[5] : source_color;
uniform float R;
uniform float macro_dtheta;  // angle of one macro cell
uniform float macro_cell;  // m along the axis
uniform float station_length;
// (theta, z) of the centre and the half extents, rad and m, of the 8 m and the 1 m windows.
uniform vec4 hole_far;
uniform vec4 hole_near;

varying vec2 theta_z;

#include "res://terrain/shaders/light_bar.gdshaderinc"

// The normal's component toward the axis: 1 on flat ground.
varying float up;
// Water depth in m, at most 0 on dry ground.
varying float depth;
// 1 where bedrock is within 1 m of the surface.
varying float rock;

// Macro texel k, theta wrapped (k.x >= -n.x) and z clamped.
float fetch(sampler2D t, ivec2 k) {
	ivec2 n = textureSize(t, 0);
	return texelFetch(t, ivec2((k.x + n.x) % n.x, clamp(k.y, 0, n.y - 1)), 0).r;
}

// Whether a station-local (theta, z) lies inside either window, each shrunk by `margin` macro cells,
// theta wrapped.
bool in_hole(vec2 p, float margin) {
	vec2 shrink = margin * vec2(macro_dtheta, macro_cell);
	vec2 d = p - hole_far.xy;
	d.x -= TAU * round(d.x / TAU);
	vec2 e = p - hole_near.xy;
	e.x -= TAU * round(e.x / TAU);
	return all(lessThan(abs(d), hole_far.zw - shrink)) || all(lessThan(abs(e), hole_near.zw - shrink));
}

void vertex() {
	ivec2 size = textureSize(surface_tex, 0);
	ivec2 k = ivec2(round(VERTEX.xz + vec2(float(size.x), float(size.y - 1)) / 2.0));
	float h = fetch(surface_tex, k);
	float w = fetch(water_tex, k);
	depth = w - h;
	rock = fetch(bedrock_tex, k) >= h - 1.0 ? 1.0 : 0.0;
	float sx = (fetch(surface_tex, k + ivec2(1, 0)) - fetch(surface_tex, k - ivec2(1, 0))) / (2.0 * (R - h) * macro_dtheta);
	float sz = (fetch(surface_tex, k + ivec2(0, 1)) - fetch(surface_tex, k - ivec2(0, 1))) / (2.0 * macro_cell);
	vec3 n = depth > 0.05 ? vec3(0.0, 1.0, 0.0) : normalize(vec3(-sx, 1.0, -sz));
	up = n.y;
	float theta = (float(k.x) + 0.5) * macro_dtheta;
	float z = clamp((float(k.y) + 0.5) * macro_cell, 0.0, station_length) - station_length / 2.0;
	vec2 p = vec2(theta, z);
	theta_z = p;
	// The cell centre's frame: X spinward, Y toward the axis.
	vec3 spinward = vec3(cos(theta), sin(theta), 0.0);
	vec3 toward_axis = vec3(-sin(theta), cos(theta), 0.0);
	float r = R - (in_hole(p, 0.0) ? h - 0.25 * macro_cell : max(h, w));
	VERTEX = vec3(r * sin(theta), -r * cos(theta), z);
	NORMAL = n.x * spinward + n.y * toward_axis + vec3(0.0, 0.0, n.z);
	bar_up = (VIEW_MATRIX * vec4(mat3(MODEL_MATRIX) * toward_axis, 0.0)).xyz;
}

void fragment() {
	if (in_hole(theta_z, 1.0)) {
		discard;
	}
	if (depth > 0.05) {
		ALBEDO = mix(vec3(0.1, 0.45, 0.4), vec3(0.02, 0.1, 0.18), clamp(depth / 30.0, 0.0, 1.0));
		ROUGHNESS = 0.1;
	} else {
		ALBEDO = mix(material_color[0].rgb, material_color[2].rgb, rock) * mix(0.55, 1.0, smoothstep(0.5, 1.0, up));
		ROUGHNESS = 0.95;
	}
}
