#[compute]
#version 450

// The collider bake: one invocation per output sample of an n x n heightfield patch (257 for the big patch,
// 65 for the edit patch), in 8 x 8 groups. The patch is the tangent frame at the centre of cell `center` (X
// spinward, Y toward the axis, Z axial, origin on the hull); output texel (i, j), mid = (n - 1) / 2, is the
// height above that plane at x = i - mid, z = j - mid m. Row j is the 1 m cell row center.y + j - mid. Its
// ground samples along theta, at the cell centres center.x + k for |k| <= half_n, come from the window
// (surface + loose, the ground a body stands on) where their tile is resident and from the bilinear macro
// surface elsewhere. Each maps into the patch frame as (x, y) = ((R - h) sin phi, R - (R - h) cos phi),
// phi = k dtheta, and y is resampled onto x as Cyl.bake_row does: linear along the polyline of mapped
// samples, the highest y where it folds back, the end sample past either end.
//
// Which k to scan (decision 10). Heights lie in [0, h_max], so for phi >= 0 a mapped sample's x lies in
// [(R - h_max) sin phi, R sin phi]. The segment k -> k + 1 covers x >= 0 only if its larger end reaches x,
// R sin((k + 1) dtheta) >= x, so k >= asin(x / R) / dtheta - 1; and only if its smaller end is at most x,
// (R - h_max) sin(k dtheta) <= x, so k + 1 <= asin(x / (R - h_max)) / dtheta + 1. The scan runs k from
// floor(asin(x / R) / dtheta) - 1 to ceil(asin(x / (R - h_max)) / dtheta) + 1, one sample of slack each
// way for float rounding, mirrored for x < 0 and clamped to +-half_n: about 100 samples at the edge of the
// big patch, 50 on average, 25 at the edge of the edit patch.
//
// A hole: where (hole_half >= 0) the sample's covering cell, the start of its highest segment, lies within
// hole_half cells of hole_cell along both axes (theta the short way round), the output is NaN, which Jolt
// reads as no ground (decision 9); the edit patch fills it.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0, r32f) uniform restrict readonly image2D w_surface;  // the window, m above the hull
layout(set = 0, binding = 1) uniform sampler2D m_surface;  // the macro surface; texelFetch only
layout(set = 0, binding = 2, r32f) uniform restrict writeonly image2D o_patch;
layout(set = 0, binding = 3, r32f) uniform restrict readonly image2D w_loose;  // the window's loose dirt, m
layout(set = 0, binding = 4, r8) uniform restrict readonly image2D chunk_mask;  // the window's chunks drawn by their box meshes, a byte per 16 m chunk slot

layout(push_constant, std430) uniform Params {
	ivec2 center;      // centre cell (theta index wrapped, z index)
	ivec2 first_tile;  // first tile of the window's wanted set (theta wrapped, z)
	int n_theta;       // 1 m cells around
	int tiles_around;  // unused: slots divides it, and surface() needs only slots
	int slots;         // window tiles per axis
	int half_n;        // samples either side of the centre: enough to reach x = +-mid m at the highest ground
	float dtheta;
	float radius;
	float macro_cell;  // m per macro texel
	int n;             // samples per side
	ivec2 hole_cell;   // centre cell of the hole (theta wrapped, z)
	int hole_half;     // the hole's half width in cells; -1 for no hole
	float h_max;       // the highest ground, h_sea + h_mtn
	float box_top;     // the voxel box's top, m: a chunk's mesh is the ground only under it
	float pad1, pad2, pad3;
} pc;  // 80 bytes

const int TILE = 128;
const float NONE = -1e30;

// Floor modulo; GLSL's % is undefined for negative operands.
int wrap(int a, int n) {
	return a - n * int(floor(float(a) / float(n)));
}

// Macro texel t with theta wrapped and z clamped; t.x is within one texel of [0, size.x), so a select wraps it.
float macro(ivec2 t, ivec2 size) {
	int x = t.x < 0 ? t.x + size.x : (t.x >= size.x ? t.x - size.x : t.x);
	return texelFetch(m_surface, ivec2(x, clamp(t.y, 0, size.y - 1)), 0).r;
}

// Per invocation, for its row: whether the row lies in the window, its texel row there, and the texel column
// of the window's first cell. Set once in main, so the loop does no division.
bool along;
int ty;
int tx0;

// Ground height at cell (center.x + k, j), theta wrapped: the window's surface + loose if its tile is
// resident, else the macro surface bilinear at the cell centre, as MacroMaps.sample. |k| <= half_n < n_theta,
// so one add or subtract wraps the column. The window holds the slots * TILE cells from its first tile's on,
// from texel column tx0 on and wrapping at slots * TILE (tile t sits in slot t mod slots, and slots divides
// tiles_around).
float surface(int k, int j) {
	int i = pc.center.x + k;
	i += i < 0 ? pc.n_theta : 0;
	i -= i >= pc.n_theta ? pc.n_theta : 0;
	int span = pc.slots * TILE;
	int d = i - pc.first_tile.x * TILE;
	d += d < 0 ? pc.n_theta : 0;
	if (along && d < span) {
		int tx = tx0 + d;
		ivec2 texel = ivec2(tx >= span ? tx - span : tx, ty);
		return imageLoad(w_surface, texel).r + imageLoad(w_loose, texel).r;
	}
	ivec2 size = textureSize(m_surface, 0);
	vec2 m = (vec2(i, j) + 0.5) / pc.macro_cell - 0.5;
	m.y = clamp(m.y, 0.0, float(size.y - 1));
	ivec2 t = ivec2(floor(m));
	vec2 f = m - vec2(t);
	return mix(mix(macro(t, size), macro(t + ivec2(1, 0), size), f.x),
			mix(macro(t + ivec2(0, 1), size), macro(t + ivec2(1, 1), size), f.x), f.y);
}

// Sample k of a row mapped into the patch frame.
vec2 mapped(int k, int row) {
	float h = surface(k, row);
	float phi = float(k) * pc.dtheta;
	float r = pc.radius - h;
	float s = sin(0.5 * phi);
	// R - r cos(phi) written as h + 2 r sin^2(phi / 2), which keeps its precision in float.
	return vec2(r * sin(phi), h + 2.0 * r * s * s);
}

void main() {
	ivec2 ij = ivec2(gl_GlobalInvocationID.xy);
	if (ij.x >= pc.n || ij.y >= pc.n) {
		return;
	}
	int mid = (pc.n - 1) / 2;
	float x = float(ij.x - mid);
	int row = pc.center.y + ij.y - mid;
	along = row >= 0 && row / TILE - pc.first_tile.y >= 0 && row / TILE - pc.first_tile.y < pc.slots;
	ty = along ? (row / TILE % pc.slots) * TILE + row % TILE : 0;
	tx0 = pc.first_tile.x % pc.slots * TILE;
	int near = int(floor(asin(min(abs(x) / pc.radius, 1.0)) / pc.dtheta)) - 1;
	int far = int(ceil(asin(min(abs(x) / (pc.radius - pc.h_max), 1.0)) / pc.dtheta)) + 1;
	int k_lo = clamp(x >= 0.0 ? near : -far, -pc.half_n, pc.half_n);
	int k_hi = clamp(x >= 0.0 ? far : -near, -pc.half_n, pc.half_n);
	float best = NONE;
	int best_k = k_lo;
	vec2 first = mapped(k_lo, row);
	vec2 prev = first;
	for (int k = k_lo; k < k_hi; k++) {
		vec2 p = mapped(k + 1, row);
		if (x >= min(prev.x, p.x) && x <= max(prev.x, p.x)) {
			// A vertical segment covers its x with both endpoints.
			float y = prev.x == p.x ? max(prev.y, p.y) : mix(prev.y, p.y, (x - prev.x) / (p.x - prev.x));
			if (y > best) {
				best = y;
				best_k = k;
			}
		}
		prev = p;
	}
	if (best == NONE) {
		// Only past the ends: the polyline covers [first.x, last.x] without gaps.
		best = (x >= 0.0 ? prev : first).y;
	}
	int half_around = pc.n_theta / 2;
	if (pc.hole_half >= 0
			&& abs(wrap(pc.center.x + best_k - pc.hole_cell.x + half_around, pc.n_theta) - half_around) <= pc.hole_half
			&& abs(row - pc.hole_cell.y) <= pc.hole_half) {
		best = uintBitsToFloat(0x7fc00000u);  // NaN: a hole
	}
	// A touched chunk of the voxel box with its mesh landed: NaN as well, its trimesh is the ground there
	// (the tunnels design).
	if (!isnan(best) && row >= 0 && surface(best_k, row) < pc.box_top) {
		ivec2 cc = ivec2(wrap(pc.center.x + best_k, pc.n_theta), row) / 16;
		if (imageLoad(chunk_mask, cc % imageSize(chunk_mask)).r > 0.5) {
			best = uintBitsToFloat(0x7fc00000u);
		}
	}
	imageStore(o_patch, ij, vec4(best));
}
