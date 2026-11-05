// Shared by tile.gdshader and water.gdshader. The mesh is a 129 x 129 grid with VERTEX.xz in [-64, 64],
// one unit per window cell (`cell` m), about the tile centre. Every tile of a window is drawn in one
// frame, the node transform all its tiles share: origin on the hull at the window's middle grid point,
// X spinward, Y toward the axis, Z axial; tile_offset puts the tile in it. Vertex k = VERTEX.xz + 64
// reads window texel slot_origin + k and is drawn at that cell's centre, half a cell past the grid point,
// so the +64 edge reads and sits on the next tile's first texel, at bit for bit the same position;
// heights are bent onto the cylinder of radius R. A
// coarser level gives way inside `hole`, where a finer level draws: its water is discarded there, and
// its ground reaches one of its cells under the finer level's edge, sunk a quarter cell, so no crack
// opens between the two levels where their heights differ.

uniform sampler2D surface_tex : filter_nearest;
uniform sampler2D loose_tex : filter_nearest;
uniform sampler2D water_tex : filter_nearest;
uniform sampler2D depth_tex : filter_nearest;  // water_depth: the sheet of spilled water on the ground, m
uniform float R;
uniform float dtheta;  // angle of one 1 m cell around the axis
uniform float cell = 1.0;  // window cell size in m: 1 for the main window, 8 for the far ring's
uniform float height_scale = 1.0;
uniform int window_size;
// (theta, z) of the centre and the half extents, rad and m, of the area a finer level draws. Zero half
// extents (the default) discard nothing.
uniform vec4 hole;
// The voxel box's chunks drawn by their meshes (the tunnels design): a byte per 16 m chunk slot of the
// window (chunk mod 32 along each axis), the station-local z of row 0, the box's band (a chunk's mesh is
// complete only between a voxel over the box's floor and a voxel under its ceiling: the tile draws the ground
// outside that band, meeting the mesh on its planes) and the chunks around the circumference. Unset (black)
// for the far ring.
uniform sampler2D chunk_mask : hint_default_black, filter_nearest;
uniform float z0 = 0.0;
uniform float box_bottom = -1e9;
uniform float box_top = 1e9;
uniform int n_chunks = 1;

// Station-local (theta, z) of the fragment, for the hole.
varying vec2 theta_z;

// Angle and axial position of the tile centre.
instance uniform float tile_theta;
instance uniform float tile_z;
// The tile centre's offset in window cells (theta, z) from the origin of the frame it is drawn in.
instance uniform ivec2 tile_offset;
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

// The ground at local cell k: the surface with its loose dirt on top.
float ground_of(ivec2 k) {
	return height_of(surface_tex, k) + height_of(loose_tex, k);
}

// Local cell of a vertex of the grid mesh.
ivec2 grid_cell(vec3 v) {
	return ivec2(round(v.xz)) + 64;
}

// Grid point (x, zz) of the tile in window cells from the frame's origin. Summed as integers, so tiles
// sharing an edge feed the bend the very same numbers whatever the compiler does with the float maths.
vec2 framed(float x, float zz) {
	return vec2(ivec2(round(vec2(x, zz))) + tile_offset);
}

// The centre of the cell at grid point (x, zz), at height h above the hull, in the frame.
// R - r cos(a) is written as h + 2 r sin^2(a / 2) to avoid cancellation in float.
vec3 bend(float x, float zz, float h) {
	vec2 g = framed(x, zz);
	float a = (g.x + 0.5) * cell * dtheta;
	float r = R - h;
	float s = sin(0.5 * a);
	return vec3(r * sin(a), h + 2.0 * r * s * s, (g.y + 0.5) * cell);
}

// Station-local (theta, z) of that cell centre.
vec2 theta_z_of(float x, float zz) {
	return vec2(tile_theta, tile_z) + (vec2(x, zz) + 0.5) * cell * vec2(dtheta, 1.0);
}

// Whether a station-local (theta, z) lies inside `hole` shrunk by `margin` window cells, theta wrapped.
bool in_hole(vec2 p, float margin) {
	vec2 d = p - hole.xy;
	d.x -= TAU * round(d.x / TAU);
	vec2 h = hole.zw - margin * cell * vec2(dtheta, 1.0);
	return abs(d.x) < h.x && abs(d.y) < h.y;
}

// A normal given in the frame of the cell centre at grid point x, rotated into the frame.
vec3 unbend_normal(float x, vec3 n) {
	float a = (framed(x, 0.0).x + 0.5) * cell * dtheta;
	return vec3(n.x * cos(a) - n.y * sin(a), n.x * sin(a) + n.y * cos(a), n.z);
}

// How far inside the box's band a ground height h lies, 0 at and beyond its planes to 1 a metre in: the
// ground tile sinks and gives way to a chunk's mesh by this much.
float box_band(float h) {
	return clamp(min(h - box_bottom, box_top - h), 0.0, 1.0);
}

// The signed Chebyshev distance in cells from station-local (theta, z) p to the nearest drawn chunk of the
// voxel box (negative inside one), over the nine chunks around p's; 1e9 with none. The ground tile sinks a
// quarter cell within 2 cells of a chunk and is discarded within 1, inside the box's band (box_band): the
// chunk's mesh reaches 2 cells past it, over the sunk ring.
float chunk_dist(vec2 p) {
	vec2 cf = vec2(p.x / (dtheta * 16.0), (p.y - z0) / 16.0);
	ivec2 c = ivec2(floor(cf));
	ivec2 ms = textureSize(chunk_mask, 0);
	float best = 1e9;
	for (int dy = -1; dy <= 1; dy++) {
		for (int dx = -1; dx <= 1; dx++) {
			ivec2 n = c + ivec2(dx, dy);
			if (n.y < 0) {
				continue;
			}
			ivec2 w = ivec2((n.x % n_chunks + n_chunks) % n_chunks, n.y);
			if (texelFetch(chunk_mask, w % ms, 0).r < 0.5) {
				continue;
			}
			vec2 l = (cf - vec2(n)) * 16.0;
			vec2 e = max(-l, l - 16.0);
			best = min(best, max(e.x, e.y));
		}
	}
	return best;
}
