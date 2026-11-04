#[compute]
#version 450

// The sheet-water simulation (TerrainSim; the terrain slice 3 plan, decisions 2, 3 and 9; the loose-dirt half
// retired to the voxel box by the tunnels design, box_sand.glsl): one fixed 1/60 s step is one compute list
// of a flux dispatch per active tile, a barrier, and an apply dispatch per active tile. By mode:
// 0 flux: each cell of `tile` writes what it sends each of its four edge neighbours (DIR4 order) as volumes,
//   a thickness times its own area (R - s) dtheta by 1 m: sheet water (flow_rate of the drop in water
//   surface, over the ground surface + loose as the box packs it each frame) to flux_water, and on soak
//   ticks one pore-water quantum per neighbour it wets to flux_pore. Outflows are capped at what the cell
//   holds, so nothing goes negative.
// 1 apply: each cell adds what its four neighbours send it and subtracts what it sends, over its own area,
//   soaks one quantum of its sheet into its column on soak ticks, and stores the result.
//
// Conservation (decision 2): a volume leaves a cell only as a flux entry that exactly one neighbour adds (the
// same float), no cell is written by two invocations, and the apply pass stores every change however small
// (move_eps gates only the activity flag), so the window's water volume is conserved to float rounding and
// the settling tail does not leak. A flux toward a cell in an inactive tile, a blocked cell (the obstacle),
// or a cell off the window or the station is never written: the water stays where it is.
// A reservoir cell (static water_surface over the ground) sends no sheet water and absorbs what reaches it
// or was spilled on it, counted in stats[slots * slots] in units of 1e-6 m^3. A cell whose ground lies under
// the lowest level among its reservoir neighbours joins them: its water_surface becomes that level (static
// and bottomless, the level never moving), one cell a step, the neighbour's tile active or not; its sheet is
// absorbed the step after. The lowest level, so a sloped river never floods its bank downstream at an
// upstream level. The flux pass carries the level as a negative entry toward one reservoir neighbour, which
// that neighbour ignores. Pore water moves and soaks in whole quanta of capacity / 255 m of depth, which
// the saturation byte holds exactly.
//
// The neighbour rule (decision 3): an applied cell that moved more than move_eps (or changed its saturation)
// sets bit 0 of its slot in `stats`, and one on a tile edge or corner also sets bit 1 of the slot of every
// neighbour across it, diagonals included, so a tile that could not receive (inactive, refused above) is
// activated by TerrainSim a couple of frames later and the flow resumes into it.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0, r32f) uniform restrict image2D w_surface;
layout(set = 0, binding = 1, r32f) uniform restrict image2D w_bedrock;
layout(set = 0, binding = 2, r32f) uniform restrict image2D w_clay_bottom;
layout(set = 0, binding = 3, r32f) uniform restrict image2D w_clay_top;
layout(set = 0, binding = 4, r32f) uniform restrict image2D w_water;
layout(set = 0, binding = 5, r8) uniform restrict image2D w_material;
layout(set = 0, binding = 6, r8) uniform restrict image2D w_compaction;
layout(set = 0, binding = 7, r8) uniform restrict image2D w_saturation;
layout(set = 0, binding = 8, r8) uniform restrict image2D w_mask;
layout(set = 0, binding = 9, r32f) uniform restrict image2D w_loose;
layout(set = 0, binding = 10, r32f) uniform restrict image2D w_depth;
// Per texel, what the cell sends each neighbour in DIR4 order: water in m^3, pore quanta as bytes.
layout(set = 0, binding = 11, rgba32f) uniform restrict image2D flux_water;
layout(set = 0, binding = 12, rgba8) uniform restrict image2D flux_pore;
// One activity word per window slot (slot y * slots + x), then the reservoirs' absorbed water (EditLayer's).
layout(set = 0, binding = 13, std430) restrict buffer Stats { uint stats[]; };

layout(push_constant, std430) uniform Params {
	ivec2 tile;             // the tile stepped (theta wrapped, z)
	ivec2 first_tile;       // first tile of the window's wanted set (theta wrapped, z)
	int n_theta;            // 1 m cells around
	int slots;              // window tiles per axis
	int mode;               // 0 flux, 1 apply
	int soak_tick;          // 1 on a soak and wetting step
	uvec2 active_mask;      // bit s.y * slots + s.x for every active tile's slot s, the low word first
	ivec2 obstacle;         // nothing moves into a cell within obstacle_radius cells of it
	int obstacle_radius;    // cells; negative: no obstacle
	float dtheta;           // rad per cell around
	float R;                // hull radius in m
	float flow_rate;        // share of the water surface drop moved per step
	float capacity[4];      // m of water a saturated column holds, per top material
	float wetting;          // dirt's wetting distance in m
	float move_eps;         // the smallest change in m that flags activity
	float pad0, pad1;       // to 96 bytes
} pc;

const int TILE = 128;
// The edge neighbours; the opposite of k is (k + 2) % 4. Even k step across (theta), odd k along (z).
const ivec2 DIR4[4] = ivec2[4](ivec2(1, 0), ivec2(0, 1), ivec2(-1, 0), ivec2(0, -1));
// The diagonal neighbours, for the neighbour rule's wake.
const ivec2 DIAG[4] = ivec2[4](ivec2(1, 1), ivec2(-1, 1), ivec2(-1, -1), ivec2(1, -1));

// Floor modulo; GLSL's % is undefined for negative operands.
int wrap(int a, int n) {
	return a - n * int(floor(float(a) / float(n)));
}

// Texel t of cell c (theta wrapped), false if its tile is not in the window: edit.glsl's residency test.
// Tile t sits in slot t mod slots. Rows off the station lie outside the window's tiles.
bool texel(ivec2 c, out ivec2 t) {
	int ty = c.y / TILE - pc.first_tile.y;
	int d = c.x - pc.first_tile.x * TILE;
	d += d < 0 ? pc.n_theta : 0;
	if (c.y < 0 || ty < 0 || ty >= pc.slots || d >= pc.slots * TILE) {
		return false;
	}
	t = (c / TILE % pc.slots) * TILE + c % TILE;
	return true;
}

uint byte(float unorm) {
	return uint(round(unorm * 255.0));
}

// Cell c + d, theta wrapped.
ivec2 offset(ivec2 c, ivec2 d) {
	ivec2 n = c + d;
	return ivec2(wrap(n.x, pc.n_theta), n.y);
}

// Cell c's edge neighbour k, theta wrapped.
ivec2 neighbour(ivec2 c, int k) {
	return offset(c, DIR4[k]);
}

// Component k of v, without a dynamic vector index.
float pick(vec4 v, int k) {
	return k == 0 ? v.x : (k == 1 ? v.y : (k == 2 ? v.z : v.w));
}

// The stats word of the slot holding texel t.
int slot_word(ivec2 t) {
	return (t.y / TILE) * pc.slots + t.x / TILE;
}

// Whether the tile in texel t's slot is active, its bit in active_mask (`active` is a reserved word).
bool tile_active(ivec2 t) {
	uint bit = uint(slot_word(t));
	return ((bit < 32u ? pc.active_mask.x >> bit : pc.active_mask.y >> (bit - 32u)) & 1u) != 0u;
}

// Whether cell c is within obstacle_radius cells of `obstacle`, theta the short way round: nothing moves
// into it. Never when obstacle_radius is negative.
bool blocked(ivec2 c) {
	if (pc.obstacle_radius < 0) {
		return false;
	}
	int half_n = pc.n_theta / 2;
	ivec2 d = ivec2(wrap(c.x - pc.obstacle.x + half_n, pc.n_theta) - half_n, c.y - pc.obstacle.y);
	return d.x * d.x + d.y * d.y <= pc.obstacle_radius * pc.obstacle_radius;
}

// Whether a column's top holds pore water as dirt does: loose dirt on it, or a dirt top.
bool dirt_topped(float loose, uint mat) {
	return loose > 0.01 || mat == 0u;
}

// Whether static water stands over the ground H: a river or lake cell.
bool reservoir(float ws, float H) {
	return ws > H + 1e-3;
}

// Sets bit 1 of the slot of cell c + d when that neighbour lies in another tile (c is texel g of its own)
// that is in the window.
void wake(ivec2 c, ivec2 g, ivec2 d) {
	ivec2 gn = g + d;
	ivec2 tn;
	if ((gn.x < 0 || gn.y < 0 || gn.x >= TILE || gn.y >= TILE) && texel(offset(c, d), tn)) {
		atomicOr(stats[slot_word(tn)], 2u);
	}
}

void flux(ivec2 c, ivec2 t, ivec2 g) {
	float s = imageLoad(w_surface, t).r;
	float L = imageLoad(w_loose, t).r;
	float d = imageLoad(w_depth, t).r;
	float sat = imageLoad(w_saturation, t).r;
	uint mat = byte(imageLoad(w_material, t).r);
	float ws = imageLoad(w_water, t).r;
	float H = s + L;
	bool res = reservoir(ws, H);
	float a = (pc.R - s) * pc.dtheta;
	float W = res ? ws : H + d;
	float out_w[4] = float[4](0.0, 0.0, 0.0, 0.0);
	float pore[4] = float[4](0.0, 0.0, 0.0, 0.0);
	uint given = 0u;
	uint q = byte(sat);
	// The lowest level among the reservoir neighbours (1e30: none) and the direction of one at it.
	float level = 1e30;
	int level_k = -1;
	for (int k = 0; k < 4; k++) {
		ivec2 n = neighbour(c, k);
		ivec2 tn;
		if (!texel(n, tn) || blocked(n)) {
			continue;
		}
		float s_n = imageLoad(w_surface, tn).r;
		float l_n = imageLoad(w_loose, tn).r;
		uint mat_n = byte(imageLoad(w_material, tn).r);
		float h_n = s_n + l_n;
		float ws_n = imageLoad(w_water, tn).r;
		bool res_n = reservoir(ws_n, h_n);
		if (res_n && ws_n < level) {
			level = ws_n;
			level_k = k;
		}
		if (!tile_active(tn)) {
			continue;
		}
		// The edge distance: the mean of the two widths across, 1 m along.
		float w = k % 2 == 0 ? 0.5 * ((pc.R - s) + (pc.R - s_n)) * pc.dtheta : 1.0;
		float w_n = res_n ? ws_n : h_n + imageLoad(w_depth, tn).r;
		float df = W - w_n;
		if (df > 0.0 && !res) {
			out_w[k] = pc.flow_rate * df;
		}
		// Lateral wetting: a quantum to a dirt-topped neighbour drier than the taper w / wetting allows,
		// at most as many as the cell holds. Decided from old state, so both sides agree.
		int drier = int(q) - int(byte(imageLoad(w_saturation, tn).r));
		if (pc.soak_tick != 0 && dirt_topped(L, mat) && dirt_topped(l_n, mat_n) && given < q
				&& float(drier) > w / pc.wetting * 255.0 + 1.0) {
			pore[k] = 1.0;
			given += 1u;
		}
	}
	float tw = out_w[0] + out_w[1] + out_w[2] + out_w[3];
	for (int k = 0; k < 4; k++) {
		if (tw > d) {
			out_w[k] *= d / tw;
		}
	}
	vec4 ow = vec4(out_w[0], out_w[1], out_w[2], out_w[3]) * a;
	if (!res && level_k >= 0 && H + 1e-3 < level) {
		// Joining the reservoirs: the level rides toward one of them in place of any send (the sheet here is
		// absorbed once this is one).
		ow = mix(ow, vec4(-level), equal(ivec4(0, 1, 2, 3), ivec4(level_k)));
	}
	imageStore(flux_water, t, ow);
	imageStore(flux_pore, t, vec4(pore[0], pore[1], pore[2], pore[3]) / 255.0);
}

void apply(ivec2 c, ivec2 t, ivec2 g) {
	float s = imageLoad(w_surface, t).r;
	float L = imageLoad(w_loose, t).r;
	float d = imageLoad(w_depth, t).r;
	uint q = byte(imageLoad(w_saturation, t).r);
	uint mat = byte(imageLoad(w_material, t).r);
	float a = (pc.R - s) * pc.dtheta;
	bool res = reservoir(imageLoad(w_water, t).r, s + L);
	vec4 own_w = imageLoad(flux_water, t);
	// A negative entry is the level this cell joins (the flux pass's rule), not a send.
	float level = -min(min(own_w.x, own_w.y), min(own_w.z, own_w.w));
	own_w = max(own_w, vec4(0.0));
	uvec4 own_p = uvec4(round(imageLoad(flux_pore, t) * 255.0));
	float in_w = 0.0;
	int in_p = 0;
	for (int k = 0; k < 4; k++) {
		int j = (k + 2) % 4;
		ivec2 tn;
		if (!texel(neighbour(c, k), tn) || !tile_active(tn)) {
			continue;
		}
		// A neighbour's level entry toward this reservoir is not an inflow.
		in_w += max(pick(imageLoad(flux_water, tn), j), 0.0);
		in_p += int(byte(pick(imageLoad(flux_pore, tn), j)));
	}
	float d_kept = d;
	if (res) {
		// A lake absorbs what flows in and what was spilled on it.
		float taken = in_w + d * a;
		if (taken > 0.0) {
			atomicAdd(stats[pc.slots * pc.slots], uint(round(taken * 1e6)));
		}
		in_w = 0.0;
		d_kept = 0.0;
	}
	float d2 = max(d_kept + (in_w - (own_w.x + own_w.y + own_w.z + own_w.w)) / a, 0.0);
	int q2 = int(q) + in_p - int(own_p.x + own_p.y + own_p.z + own_p.w);
	if (pc.soak_tick != 0) {
		// One quantum of the sheet into the column, while it holds water and is not saturated.
		float cap = pc.capacity[dirt_topped(L, mat) ? 0 : min(int(mat), 3)];
		float qm = cap / 255.0;
		if (cap > 0.0 && d2 >= qm && q2 < 255) {
			q2 += 1;
			d2 -= qm;
		}
	}
	bool joins = level > 0.0 && !res;
	if (joins) {
		imageStore(w_water, t, vec4(level));
	}
	// Every change, however small, is stored: conservation.
	if (d2 != d || q2 != int(q) || joins) {
		imageStore(w_depth, t, vec4(d2));
		imageStore(w_saturation, t, vec4(float(q2) / 255.0));
		imageStore(w_mask, t, vec4(1.0));
	}
	// The activity gate only; a cell that joined counts, its neighbours may follow next step.
	if (abs(d2 - d) > pc.move_eps || q2 != int(q) || joins) {
		atomicOr(stats[slot_word(t)], 1u);
		for (int k = 0; k < 4; k++) {
			wake(c, g, DIR4[k]);
			wake(c, g, DIAG[k]);
		}
	}
}

void main() {
	ivec2 g = ivec2(gl_GlobalInvocationID.xy);
	ivec2 c = pc.tile * TILE + g;
	ivec2 t = (pc.tile % pc.slots) * TILE + g;
	if (pc.mode == 0) {
		flux(c, t, g);
	} else {
		apply(c, t, g);
	}
}
