// Shared by tile.gdshader and water.gdshader. The mesh is a 129 x 129 grid at 1 m with VERTEX.xz in
// [-64, 64], drawn in the tile node's frame: origin on the hull at the tile centre, X spinward, Y toward
// the axis, Z axial. Vertex k = VERTEX.xz + 64 reads window texel slot_origin + k and is drawn at that
// cell's centre, half a cell past the grid point, so the +64 edge reads and sits on the next tile's first
// texel; heights are bent onto the cylinder of radius R.

uniform sampler2D surface_tex : filter_nearest;
uniform sampler2D water_tex : filter_nearest;
uniform float R;
uniform float dtheta;  // angle of one cell around the axis
uniform float dz = 1.0;  // cell length along the axis, m
uniform float height_scale = 1.0;
uniform int window_size;

// Angle and axial position of the tile centre.
instance uniform float tile_theta;
instance uniform float tile_z;
// The tile's first texel in the window.
instance uniform ivec2 slot_origin;
// Per axis: -1 on the window's low outer edge, +1 on its high outer edge, 0 inside. Edge tiles clamp to
// their own texels there instead of wrapping onto the window's opposite side.
instance uniform ivec2 clamp_edge;

// Window texel of local cell k (0..128, and one more either side for normals).
ivec2 window_texel(ivec2 k) {
	ivec2 lo = ivec2(-1) + max(-clamp_edge, ivec2(0));
	ivec2 hi = ivec2(129) - 2 * max(clamp_edge, ivec2(0));
	return (slot_origin + clamp(k, lo, hi) + window_size) % window_size;
}

float height_of(sampler2D tex, ivec2 k) {
	return texelFetch(tex, window_texel(k), 0).r * height_scale;
}

// Local cell of a vertex of the grid mesh.
ivec2 grid_cell(vec3 v) {
	return ivec2(round(v.xz)) + 64;
}

// The centre of the cell at grid point (x, zz), at height h above the hull, in the tile's frame.
// R - r cos(a) is written as h + 2 r sin^2(a / 2) to avoid cancellation in float.
vec3 bend(float x, float zz, float h) {
	float a = (x + 0.5) * dtheta;
	float r = R - h;
	float s = sin(0.5 * a);
	return vec3(r * sin(a), h + 2.0 * r * s * s, (zz + 0.5) * dz);
}

// A normal given in the frame of the cell centre at grid point x, rotated into the tile's frame.
vec3 unbend_normal(float x, vec3 n) {
	float a = (x + 0.5) * dtheta;
	return vec3(n.x * cos(a) - n.y * sin(a), n.x * sin(a) + n.y * cos(a), n.z);
}
