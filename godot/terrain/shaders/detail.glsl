#[compute]
#version 450

// The detail pass: fills one 128 x 128 tile of the window from the 32 m macro maps (one invocation per
// window cell, one dispatch of 16 x 16 groups per tile). Deterministic from the macro maps, the seed and
// the tile index. Heights are metres above the hull.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// Macro maps, texel (theta cell, z cell) with row 0 at z = -length / 2. Read with texelFetch only.
layout(set = 0, binding = 0) uniform sampler2D m_surface;
layout(set = 0, binding = 1) uniform sampler2D m_bedrock;
layout(set = 0, binding = 2) uniform sampler2D m_clay_bottom;
layout(set = 0, binding = 3) uniform sampler2D m_clay_top;
layout(set = 0, binding = 4) uniform sampler2D m_water;
layout(set = 0, binding = 5) uniform sampler2D m_region;  // id / 255: 0 sea, 1 flat, 2 hill, 3 mountain, 4 island
layout(set = 0, binding = 6) uniform sampler2D m_cliff;   // 1 in a cliff band
layout(set = 0, binding = 7) uniform sampler2D m_river;   // distance to the nearest river cell (m), its width (m), its surface (m)
layout(set = 0, binding = 8) uniform sampler2D m_flow;    // flow_dir / 255: 1..8 the downstream neighbour, see DIR

layout(set = 1, binding = 0, r32f) uniform restrict writeonly image2D o_surface;
layout(set = 1, binding = 1, r32f) uniform restrict writeonly image2D o_bedrock;
layout(set = 1, binding = 2, r32f) uniform restrict writeonly image2D o_clay_bottom;
layout(set = 1, binding = 3, r32f) uniform restrict writeonly image2D o_clay_top;
layout(set = 1, binding = 4, r32f) uniform restrict writeonly image2D o_water;
layout(set = 1, binding = 5, r8) uniform restrict writeonly image2D o_material;
layout(set = 1, binding = 6, r8) uniform restrict writeonly image2D o_compaction;
layout(set = 1, binding = 7, r8) uniform restrict writeonly image2D o_saturation;

layout(push_constant, std430) uniform Params {
	ivec2 tile;            // tile index (theta, z), theta already wrapped
	ivec2 origin;          // the tile's first texel in the window
	int n_theta;           // 1 m cells around
	int seed;
	float cell;            // window cell size in m: 1, or 8 for the far ring
	float dtheta;          // angle of one 1 m cell
	float radius;
	float h_sea;
	float h_max;           // h_sea + h_mtn
	float macro_cell;      // m per macro texel
	float bank_distance;
	float bank_slope_tan;
	vec2 pad;              // to 64 bytes: Godot wants push constants in multiples of 16
} pc;

const float CLIFF_BAND = 4.0;  // m: width of a sharpened cliff face
const float LAKE_CARVE = 8.0;  // m: how far a lake cell's centre is lowered below its level
const float AMP[5] = float[](1.5, 1.5, 4.0, 8.0, 4.0);  // detail noise amplitude in m by region
// flow_dir 1..8 -> neighbour offset.
const ivec2 DIR[8] = ivec2[](ivec2(1, 0), ivec2(1, 1), ivec2(0, 1), ivec2(-1, 1), ivec2(-1, 0), ivec2(-1, -1), ivec2(0, -1), ivec2(1, -1));
const ivec2 CORNER[4] = ivec2[](ivec2(0, 0), ivec2(0, 1), ivec2(1, 0), ivec2(1, 1));

ivec2 msize;  // macro map size

// Floor modulo; GLSL's % is undefined for negative operands.
int wrap(int a, int n) {
	return a - n * int(floor(float(a) / float(n)));
}

// Macro texel t with theta wrapped and z clamped.
vec4 fetch(sampler2D s, ivec2 t) {
	return texelFetch(s, ivec2(wrap(t.x, msize.x), clamp(t.y, 0, msize.y - 1)), 0);
}

// A bilinear footprint: lower-left texel t and weights (across, up the left column, up the right
// column). A pair of texels whose higher one is a cliff cell (a cliff cell is the top of its 10-60 m
// jump) interpolates with a smoothstep over CLIFF_BAND at their shared boundary instead of the 32 m
// ramp, so the jump becomes a near-vertical face. The across weight blends the two rows' choices by
// height so the surface stays continuous where the choice changes.
struct Foot {
	ivec2 t;
	vec3 w;
};

// Corner values of the texels at t + CORNER[k].
vec4 corners(sampler2D s, ivec2 t, int channel) {
	vec4 v;
	for (int k = 0; k < 4; k++) {
		v[k] = fetch(s, t + CORNER[k])[channel];
	}
	return v;
}

// The weight across a pair, sharpened when the higher texel of the pair is a cliff cell.
float sharp(float f, vec4 h, vec4 c, int lo, int hi) {
	float b = 0.5 * CLIFF_BAND / pc.macro_cell;
	bool face = (h[lo] >= h[hi] ? c[lo] : c[hi]) > 0.5;
	return face ? smoothstep(0.5 - b, 0.5 + b, f) : f;
}

Foot foot(vec2 m) {
	m.y = clamp(m.y, 0.0, float(msize.y - 1));
	ivec2 t = ivec2(floor(m));
	vec2 f = m - vec2(t);
	vec4 h = corners(m_surface, t, 0);
	vec4 c = corners(m_cliff, t, 0);
	float across = mix(sharp(f.x, h, c, 0, 2), sharp(f.x, h, c, 1, 3), f.y);
	return Foot(t, vec3(across, sharp(f.y, h, c, 0, 1), sharp(f.y, h, c, 2, 3)));
}

// Corner values in CORNER order.
float blend(Foot p, vec4 v) {
	return mix(mix(v.x, v.y, p.w.y), mix(v.z, v.w, p.w.z), p.w.x);
}

// Plain bilinear with theta wrapped and z clamped, as MacroMaps.sample on the CPU.
float bilinear(sampler2D s, vec2 m) {
	m.y = clamp(m.y, 0.0, float(msize.y - 1));
	ivec2 t = ivec2(floor(m));
	vec2 f = m - vec2(t);
	return blend(Foot(t, f.xyy), corners(s, t, 0));
}

float interp(sampler2D s, Foot p) {
	return blend(p, corners(s, p.t, 0));
}

uint hash(uint x) {
	x ^= x >> 16;
	x *= 0x7feb352du;
	x ^= x >> 15;
	x *= 0x846ca68bu;
	x ^= x >> 16;
	return x;
}

float lattice(int i, int j, int octave) {
	uint h = hash(uint(i) ^ hash(uint(j) ^ hash(uint(octave) ^ hash(uint(pc.seed)))));
	return float(h) * (2.0 / 4294967295.0) - 1.0;
}

// Fractal value noise in [-1, 1] at u (1 m cells: theta index, z index), octaves of 32 down to 1 m
// wavelength, stopping at the window's cell, each weighted by its wavelength. Lattice columns wrap at
// n_theta / wavelength, so the field is periodic in theta with no seam. Normalised by all six weights,
// so a coarse window carries the same large octaves as the 1 m one.
float detail_noise(vec2 u) {
	float sum = 0.0;
	for (int o = 0; o < 6; o++) {
		int s = 32 >> o;
		if (float(s) < pc.cell) {
			break;
		}
		vec2 q = u / float(s);
		ivec2 k = ivec2(floor(q));
		vec2 f = q - vec2(k);
		f = f * f * (3.0 - 2.0 * f);
		int n = pc.n_theta / s;
		int x0 = wrap(k.x, n);
		int x1 = wrap(k.x + 1, n);
		float v = mix(mix(lattice(x0, k.y, o), lattice(x1, k.y, o), f.x),
				mix(lattice(x0, k.y + 1, o), lattice(x1, k.y + 1, o), f.x), f.y);
		sum += v * float(s) / 32.0;
	}
	return sum / 1.96875;
}

// River channels at m (macro texel coordinates). The centreline runs from each river cell's centre to
// its flow_dir neighbour's, searched over the 5 x 5 texels around m (every segment within 48 m).
// Returns ground lowered to the channel: within half a width, level - (w / 8)(1 - (2d / w)^2); banks
// blended to `ground` out to 1.5 widths and held under the bank slope within bank_distance of the
// water. `edge` is the distance from the nearest water's edge (the river texture's estimate beyond
// the search), `water` the river's surface where m is in a channel, else 0.
float rivers(vec2 m, Foot p, float ground, out float edge, out float water) {
	edge = max(interp(m_river, p) - 0.5 * blend(p, corners(m_river, p.t, 1)), 0.0);
	water = 0.0;
	ivec2 near = ivec2(floor(m + 0.5));
	for (int dy = -2; dy <= 2; dy++) {
		for (int dx = -2; dx <= 2; dx++) {
			ivec2 c = near + ivec2(dx, dy);
			if (c.y < 0 || c.y >= msize.y) {
				continue;
			}
			vec4 r = fetch(m_river, c);
			int f = int(fetch(m_flow, c).r * 255.0 + 0.5);
			if (r.x != 0.0 || r.y <= 0.0 || f < 1 || f > 8) {
				continue;  // not a river cell
			}
			vec2 ab = vec2(DIR[f - 1]);
			float t = clamp(dot(m - vec2(c), ab) / dot(ab, ab), 0.0, 1.0);
			float d = length(m - vec2(c) - t * ab) * pc.macro_cell;
			float w = r.y;
			float down = fetch(m_water, c + DIR[f - 1]).r;
			float level = mix(r.z, down > 0.0 ? down : r.z, t);
			float e = d - 0.5 * w;
			edge = min(edge, max(e, 0.0));
			float h;
			if (e < 0.0) {
				h = level - w / 8.0 * (1.0 - (2.0 * d / w) * (2.0 * d / w));
				water = max(water, level);
			} else {
				h = mix(level, ground, smoothstep(0.5 * w, 1.5 * w, d));
				h = min(h, level + pc.bank_slope_tan * e + 10.0 * max(e - pc.bank_distance, 0.0));
			}
			ground = min(ground, h);
		}
	}
	return ground;
}

float region_amp(Foot p) {
	vec4 v = corners(m_region, p.t, 0);
	vec4 a;
	for (int k = 0; k < 4; k++) {
		a[k] = AMP[clamp(int(v[k] * 255.0 + 0.5), 0, 4)];
	}
	return blend(p, a);
}

void main() {
	msize = textureSize(m_surface, 0);
	ivec2 local = ivec2(gl_GlobalInvocationID.xy);
	ivec2 g = pc.tile * 128 + local;
	vec2 u = (vec2(g) + 0.5) * pc.cell;   // cell centre in 1 m cells (theta index, z index)
	vec2 m = u / pc.macro_cell - 0.5;     // macro texel coordinates, texel centres at integers
	Foot p = foot(m);
	float s = interp(m_surface, p);
	float b = interp(m_bedrock, p);
	float cb = interp(m_clay_bottom, p);
	float ct = interp(m_clay_top, p);

	// Macro slope: the plain bilinear surface over half a macro cell either side, with the true width of
	// a theta cell at height s. Smooth at 32 m, so the noise fades across a whole jump, not in a rim.
	float gx = (bilinear(m_surface, m + vec2(0.5, 0.0)) - bilinear(m_surface, m - vec2(0.5, 0.0)))
			/ (pc.macro_cell * pc.dtheta * (pc.radius - s));
	float gz = (bilinear(m_surface, m + vec2(0.0, 0.5)) - bilinear(m_surface, m - vec2(0.0, 0.5))) / pc.macro_cell;
	float slope = length(vec2(gx, gz));

	// Lakes: water cells that are neither sea nor on a river path. lam is their bilinear share here.
	vec4 lake;
	float level = 0.0;
	for (int k = 0; k < 4; k++) {
		ivec2 t = p.t + CORNER[k];
		float ws = fetch(m_water, t).r;
		bool is_lake = ws > 0.0 && fetch(m_region, t).r > 0.0 && fetch(m_river, t).r > 0.0;
		lake[k] = is_lake ? 1.0 : 0.0;
		level = is_lake ? max(level, ws) : level;
	}
	float lam = blend(p, lake);

	// Detail noise.
	float edge, water;
	rivers(m, p, s, edge, water);
	float exposed = clamp(1.0 - (s - b), 0.0, 1.0);  // 1 on bare rock, 0 under 1 m of cover
	float a = region_amp(p) * (1.0 + 2.0 * exposed);
	a *= mix(1.0, 0.1, smoothstep(tan(radians(45.0)), tan(radians(55.0)), slope));
	a *= 1.0 - min(1.0, pc.bank_distance / max(edge, 1e-3));
	a *= 1.0 - lam;
	a = min(a, max(s - pc.h_sea, 0.0));  // never pushes land under sea level; none on the sea floor
	float n = a * detail_noise(u);

	// Rivers, then lakes (at least 1 m deep), then the sea.
	float h = rivers(m, p, s + n, edge, water);
	h -= LAKE_CARVE * lam;
	if (lam > 0.0 && h < level) {
		h = min(h, level - 1.0);
		water = max(water, level);
	}
	if (h < pc.h_sea) {
		water = max(water, pc.h_sea);
	}
	h = clamp(h, 0.0, pc.h_max);

	// Strata follow 0.3 of the noise, all of it on bare rock so rock stays at the surface; a lens cut
	// away entirely collapses onto the bedrock.
	float nb = n * (0.3 + 0.7 * exposed);
	float bt = clamp(b + nb, 0.0, h);
	float cbt = cb + nb;
	float ctt = ct + nb;
	if (cbt >= h) {
		cbt = bt;
		ctt = bt;
	}
	cbt = clamp(cbt, bt, h);
	ctt = clamp(ctt, cbt, h);
	float material = bt >= h - 0.01 ? 2.0 : (ctt >= h - 0.01 ? 1.0 : 0.0);

	ivec2 o = pc.origin + local;
	imageStore(o_surface, o, vec4(h));
	imageStore(o_bedrock, o, vec4(bt));
	imageStore(o_clay_bottom, o, vec4(cbt));
	imageStore(o_clay_top, o, vec4(ctt));
	imageStore(o_water, o, vec4(water));
	imageStore(o_material, o, vec4(material / 255.0));
	imageStore(o_compaction, o, vec4(0.0));
	imageStore(o_saturation, o, vec4(0.0));
}
