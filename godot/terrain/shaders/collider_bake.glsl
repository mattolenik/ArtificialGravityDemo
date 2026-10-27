#[compute]
#version 450

// The collider bake: one row of the 257 x 257 heightfield patch per invocation (5 groups of 64 for 257
// rows). The patch is the tangent frame at the centre of cell `center` (X spinward, Y toward the axis,
// Z axial, origin on the hull); output texel (i, j) is the height above that plane at x = i - 128,
// z = j - 128 m. Row j is the 1 m cell row center.y + j - 128. Its surface samples along theta, at the
// cell centres center.x + k for |k| <= half_n, come from the window where their tile is resident and
// from the bilinear macro surface elsewhere. Each maps into the patch frame as
// (x, y) = ((R - h) sin phi, R - (R - h) cos phi), phi = k dtheta, and y is resampled onto x = i - 128
// as Cyl.bake_row does: linear along the polyline of mapped samples, the highest y where it folds back,
// the nearest end sample past either end.

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, r32f) uniform restrict readonly image2D w_surface;  // the window, m above the hull
layout(set = 0, binding = 1) uniform sampler2D m_surface;  // the macro surface; texelFetch only
layout(set = 0, binding = 2, r32f) uniform restrict writeonly image2D o_patch;

layout(push_constant, std430) uniform Params {
	ivec2 center;      // centre cell (theta index wrapped, z index)
	ivec2 first_tile;  // first tile of the window's wanted set (theta wrapped, z)
	int n_theta;       // 1 m cells around
	int tiles_around;
	int slots;         // window tiles per axis
	int half_n;        // samples either side of the centre: enough to reach x = +-128 m at the highest ground
	float dtheta;
	float radius;
	float macro_cell;  // m per macro texel
	float pad;         // to 48 bytes
} pc;

const int N = 257;
const int MID = 128;
const int TILE = 128;
const float NONE = -1e30;

// Floor modulo; GLSL's % is undefined for negative operands.
int wrap(int a, int n) {
	return a - n * int(floor(float(a) / float(n)));
}

// Macro texel t with theta wrapped and z clamped.
float macro(ivec2 t, ivec2 size) {
	return texelFetch(m_surface, ivec2(wrap(t.x, size.x), clamp(t.y, 0, size.y - 1)), 0).r;
}

// Surface height at cell (i, j), i wrapped: the window texel if its tile is resident, else the macro
// surface bilinear at the cell centre, as MacroMaps.sample.
float surface(int i, int j) {
	i = wrap(i, pc.n_theta);
	bool across = wrap(i / TILE - pc.first_tile.x, pc.tiles_around) < pc.slots;
	bool along = j >= 0 && j / TILE - pc.first_tile.y >= 0 && j / TILE - pc.first_tile.y < pc.slots;
	if (across && along) {
		ivec2 c = ivec2(i, j);
		return imageLoad(w_surface, (c / TILE % pc.slots) * TILE + c % TILE).r;
	}
	ivec2 size = textureSize(m_surface, 0);
	vec2 m = (vec2(i, j) + 0.5) / pc.macro_cell - 0.5;
	m.y = clamp(m.y, 0.0, float(size.y - 1));
	ivec2 t = ivec2(floor(m));
	vec2 f = m - vec2(t);
	return mix(mix(macro(t, size), macro(t + ivec2(1, 0), size), f.x),
			mix(macro(t + ivec2(0, 1), size), macro(t + ivec2(1, 1), size), f.x), f.y);
}

void main() {
	int j = int(gl_GlobalInvocationID.x);
	if (j >= N) {
		return;
	}
	int row = pc.center.y + j - MID;
	float best[N];
	for (int i = 0; i < N; i++) {
		best[i] = NONE;
	}
	vec2 prev = vec2(0.0);
	vec2 lo = vec2(1e30, 0.0);   // the leftmost mapped sample (first of equals)
	vec2 hi = vec2(-1e30, 0.0);  // the rightmost
	for (int k = -pc.half_n; k <= pc.half_n; k++) {
		float h = surface(pc.center.x + k, row);
		float phi = float(k) * pc.dtheta;
		float r = pc.radius - h;
		float s = sin(0.5 * phi);
		// R - r cos(phi) written as h + 2 r sin^2(phi / 2), which keeps its precision in float.
		vec2 p = vec2(r * sin(phi), h + 2.0 * r * s * s);
		lo = p.x < lo.x ? p : lo;
		hi = p.x > hi.x ? p : hi;
		if (k > -pc.half_n) {
			// The segment prev -> p covers the output columns whose x lies in [min x, max x].
			int a = max(int(ceil(min(prev.x, p.x))) + MID, 0);
			int b = min(int(floor(max(prev.x, p.x))) + MID, N - 1);
			for (int i = a; i <= b; i++) {
				float x = float(i - MID);
				// A vertical segment covers its x with both endpoints.
				float y = prev.x == p.x ? max(prev.y, p.y) : mix(prev.y, p.y, (x - prev.x) / (p.x - prev.x));
				best[i] = max(best[i], y);
			}
		}
		prev = p;
	}
	for (int i = 0; i < N; i++) {
		// The polyline covers [lo.x, hi.x] without gaps, so an uncovered column lies past one end.
		float y = best[i] != NONE ? best[i] : (float(i - MID) < lo.x ? lo.y : hi.y);
		imageStore(o_patch, ivec2(i, j), vec4(y));
	}
}
