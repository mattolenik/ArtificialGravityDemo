#[compute]
#version 450

// The edit layer (EditLayer, decisions 1 to 4 of the terrain edits plan; the tool stamps of the slice 3 plan,
// decisions 5, 6, 9 and 12), by mode (EditLayer.MODE_*):
// 0 raise: a disc of `radius` cells around `cell` raised or lowered by dh with a parabolic falloff, in the
//   live window; strata are cut by min on the way down and dirt is added on the way up; edit_mask set;
//   loose and water_depth left as they are.
// 1 pack: tile `tile` of the window copied into slot `slot` of `down`, one blob per tile; unedited cells zero.
// 2 apply: the blob in `up` copied over tile `tile` where its mask is set.
// 3 bore, 4 deposit, 5 push, 6 tamp, 7 spill: the tool stamps, each over the box of its reach around `cell`
//   (radius; radius + 1 for the push) and on the resident cells of the disc of `radius` around it; see each
//   function. Volumes are on the true cell areas, (R - s) dtheta by 1 m, so a deposit, spill or push
//   conserves its volume.
// 8 scoop: the shovel, on the resident cells of the disc of `radius` around `cell`, loose first, then the
//   solid ground with the swell; see scoop.
// Every stamp mode flags the slot of each cell it changes in `stats` (bit 0: TerrainSim's activity), and so
// does apply for a cell whose blob holds loose dirt or water, so a pile re-entering the window resumes while
// a plain edited tile does not wake the simulation.
// A blob cell (i, j) is eight uints at (j * 128 + i) * 8: the five heights' float bits, then
// material | compaction << 8 | saturation << 16 | mask << 24, each byte round(unorm * 255), then loose's and
// water_depth's float bits.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer Up { uint up[]; };
layout(set = 0, binding = 1, std430) restrict writeonly buffer Down { uint down[]; };
layout(set = 0, binding = 2, r32f) uniform restrict image2D w_surface;
layout(set = 0, binding = 3, r32f) uniform restrict image2D w_bedrock;
layout(set = 0, binding = 4, r32f) uniform restrict image2D w_clay_bottom;
layout(set = 0, binding = 5, r32f) uniform restrict image2D w_clay_top;
layout(set = 0, binding = 6, r32f) uniform restrict image2D w_water;
layout(set = 0, binding = 7, r8) uniform restrict image2D w_material;
layout(set = 0, binding = 8, r8) uniform restrict image2D w_compaction;
layout(set = 0, binding = 9, r8) uniform restrict image2D w_saturation;
layout(set = 0, binding = 10, r8) uniform restrict image2D w_mask;
layout(set = 0, binding = 11, r32f) uniform restrict image2D w_loose;
layout(set = 0, binding = 12, r32f) uniform restrict image2D w_depth;
// A bore tick: m^3 cut or lifted in units of 1e-6, then 1 when it pumped; a scoop: loose-equivalent m^3 taken,
// in units of 1e-6. Cleared before each counted stamp.
layout(set = 0, binding = 13, std430) restrict buffer Counter { uint counter[2]; };
// One activity word per window slot (slot y * slots + x), then TerrainSim's absorbed water.
layout(set = 0, binding = 14, std430) restrict buffer Stats { uint stats[]; };

layout(push_constant, std430) uniform Params {
	ivec2 cell;           // stamp centre (theta index wrapped, z index)
	ivec2 first_tile;     // first tile of the window's wanted set (theta wrapped, z)
	ivec2 tile;           // the tile packed or applied (theta wrapped, z)
	int n_theta;          // 1 m cells around
	int slots;            // window tiles per axis
	int mode;             // EditLayer.MODE_*
	int radius;           // stamp radius in cells
	int slot;             // pack: the slot of `down`; bore, deposit, spill, scoop: the disc's cell count
	int obstacle_radius;  // cells; negative: no obstacle
	ivec2 dir;            // push: the axis step toward the cell ahead
	ivec2 obstacle;       // the obstacle's centre cell
	float dh;             // raise: m at the centre; bore: the step in m; deposit, spill, scoop: m^3; push: the share; tamp: the step
	float limit;          // bore: the pump's m^3 per tick; push: the cap in m per cell; tamp, scoop: the swell
	float h_max;          // the highest ground, h_sea + h_mtn
	float R;              // hull radius in m
	float dtheta;         // rad per cell around
	float pad0, pad1, pad2;  // to 96 bytes
} pc;

const int TILE = 128;

// Floor modulo; GLSL's % is undefined for negative operands.
int wrap(int a, int n) {
	return a - n * int(floor(float(a) / float(n)));
}

// Texel t of cell c (theta wrapped), false if its tile is not in the window: the residency test of
// collider_bake.glsl. Tile t sits in slot t mod slots.
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

// The cell at offset d from `cell`, theta wrapped.
ivec2 at(ivec2 d) {
	return ivec2(wrap(pc.cell.x + d.x, pc.n_theta), pc.cell.y + d.y);
}

// Whether offset d from `cell` lies in the disc of `radius`; in integers, so EditLayer.disc_cells counts the
// same cells.
bool in_disc(ivec2 d) {
	return d.x * d.x + d.y * d.y <= pc.radius * pc.radius;
}

// Texel t of invocation g's cell, for a stamp whose box is its disc's (reach = radius); false outside the
// disc or the window.
bool disc_texel(ivec2 g, out ivec2 t) {
	ivec2 d = g - pc.radius;
	return in_disc(d) && texel(at(d), t);
}

// Whether cell c is within obstacle_radius cells of `obstacle`, theta the short way round: nothing is moved
// into it. Never when obstacle_radius is negative.
bool blocked(ivec2 c) {
	if (pc.obstacle_radius < 0) {
		return false;
	}
	int half_n = pc.n_theta / 2;
	ivec2 d = ivec2(wrap(c.x - pc.obstacle.x + half_n, pc.n_theta) - half_n, c.y - pc.obstacle.y);
	return d.x * d.x + d.y * d.y <= pc.obstacle_radius * pc.obstacle_radius;
}

// Marks the slot of texel t active (TerrainSim reads and clears the stats in a frame that ran a sim list or
// follows a stamp or an apply since the last readback).
void flag(ivec2 t) {
	atomicOr(stats[(t.y / TILE) * pc.slots + t.x / TILE], 1u);
}

// The area in m^2 of a cell whose surface is s m over the hull: (R - s) dtheta across, 1 m along.
float area(float s) {
	return (pc.R - s) * pc.dtheta;
}

// The top material by the strata at surface s: rock, clay or dirt. Edited strata are real, so never 3 (the
// detail pass's rock face).
float top_material(float s, float bt, float ct) {
	return bt >= s - 0.01 ? 2.0 : (ct >= s - 0.01 ? 1.0 : 0.0);
}

// 3 bore, one auger tick. The centre cell decides for the whole disc: wet when the static water stands over
// its ground or a sheet over 1 cm deep lies on it. Dry, each cell's surface drops by dh, stopping at
// bedrock_top, the clay cut down with it, and the annulus cut (the product form, exact in float32) is added
// to counter[0]. Wet, each cell lifts its share limit / slot of the tick's water, whole from a reservoir cell
// (static water over its ground), at most what it holds from a sheet; counter[0] gets what was lifted and
// counter[1] is set. Every invocation reads the centre before any stores to it, which holds within one
// workgroup only: radius at most 3.
void bore(ivec2 g) {
	ivec2 tc;
	bool wet = false;
	if (texel(pc.cell, tc)) {
		float ground = imageLoad(w_surface, tc).r + imageLoad(w_loose, tc).r;
		wet = imageLoad(w_water, tc).r > ground + 1e-3 || imageLoad(w_depth, tc).r > 0.01;
	}
	memoryBarrierImage();
	barrier();
	ivec2 t;
	if (!disc_texel(g, t)) {
		return;
	}
	float s = imageLoad(w_surface, t).r;
	if (wet) {
		float lifted = pc.limit / float(pc.slot);
		if (imageLoad(w_water, t).r <= s + imageLoad(w_loose, t).r + 1e-3) {
			float depth = imageLoad(w_depth, t).r;
			lifted = min(depth * area(s), lifted);
			imageStore(w_depth, t, vec4(max(depth - lifted / area(s), 0.0)));
		}
		atomicAdd(counter[0], uint(round(lifted * 1e6)));
		atomicMax(counter[1], 1u);
	} else {
		float bt = imageLoad(w_bedrock, t).r;
		float cut = max(min(pc.dh, s - bt), 0.0);
		// float32 stores s - cut rounded to 2^-15 m near 400 m, so the surfaces trail the counter by about
		// 0.02 % over a bore (tool_run); s - s2 cannot recover the stored cut, fast math folds it to cut.
		float s2 = s - cut;
		float ct = min(imageLoad(w_clay_top, t).r, s2);
		imageStore(w_surface, t, vec4(s2));
		imageStore(w_clay_bottom, t, vec4(min(imageLoad(w_clay_bottom, t).r, s2)));
		imageStore(w_clay_top, t, vec4(ct));
		imageStore(w_material, t, vec4(top_material(s2, bt, ct) / 255.0));
		atomicAdd(counter[0], uint(round(0.5 * pc.dtheta * cut * (2.0 * (pc.R - s) + cut) * 1e6)));
	}
	imageStore(w_mask, t, vec4(1.0));
	flag(t);
}

// 4 deposit and 7 spill: dh m^3 spread evenly over the disc's `slot` cells, as fresh loose dirt (compaction
// 0) or as sheet water, each cell's share over its own area.
void deposit(ivec2 g) {
	ivec2 t;
	if (!disc_texel(g, t)) {
		return;
	}
	float added = pc.dh / float(pc.slot) / area(imageLoad(w_surface, t).r);
	if (pc.mode == 4) {
		imageStore(w_loose, t, vec4(imageLoad(w_loose, t).r + added));
		imageStore(w_compaction, t, vec4(0.0));
	} else {
		imageStore(w_depth, t, vec4(imageLoad(w_depth, t).r + added));
	}
	imageStore(w_mask, t, vec4(1.0));
	flag(t);
}

// The loose thickness in m a push moves out of the cell at offset d from `cell` into the cell ahead:
// min(dh * loose, limit) when the cell is in the disc and resident and the cell ahead is resident and not
// blocked, else 0. The cell's own invocation and the one ahead of it both call this with the same d on the
// same state, so they agree bit for bit.
float push_out(ivec2 d) {
	ivec2 t;
	ivec2 ta;
	if (!in_disc(d) || !texel(at(d), t) || !texel(at(d + pc.dir), ta) || blocked(at(d + pc.dir))) {
		return 0.0;
	}
	return min(pc.dh * imageLoad(w_loose, t).r, pc.limit);
}

// 5 push, a gather over the box of radius + 1, so no two invocations write one cell: each cell keeps its
// loose less what it sends ahead, plus what the cell behind sends it, that volume over its own area. Every
// invocation reads before any stores, which holds within one workgroup only: radius at most 2. A cell that
// does not change (bare ground) is neither stored, masked nor flagged.
void push(ivec2 g) {
	ivec2 d = g - (pc.radius + 1);
	ivec2 t;
	ivec2 tb;
	bool resident = texel(at(d), t);
	float loose = 0.0;
	float next = 0.0;
	if (resident) {
		loose = imageLoad(w_loose, t).r;
		next = loose - push_out(d);
		float back = push_out(d - pc.dir);
		if (back > 0.0 && texel(at(d - pc.dir), tb)) {
			next += back * area(imageLoad(w_surface, tb).r) / area(imageLoad(w_surface, t).r);
		}
	}
	memoryBarrierImage();
	barrier();
	if (resident && next != loose) {
		imageStore(w_loose, t, vec4(next));
		imageStore(w_mask, t, vec4(1.0));
		flag(t);
	}
}

// 6 tamp, a landing: the disc's cells holding loose dirt (over 1 mm) gain dh of compaction; one that reaches
// 1 folds, its loose joining the solid surface shrunk by the swell `limit` (up to h_max), its top dirt, its
// loose and compaction 0.
void tamp(ivec2 g) {
	ivec2 t;
	if (!disc_texel(g, t)) {
		return;
	}
	float loose = imageLoad(w_loose, t).r;
	if (loose <= 1e-3) {
		return;
	}
	float k = imageLoad(w_compaction, t).r + pc.dh;
	if (k >= 1.0 - 1e-3) {
		imageStore(w_surface, t, vec4(min(imageLoad(w_surface, t).r + loose / pc.limit, pc.h_max)));
		imageStore(w_material, t, vec4(0.0));
		imageStore(w_loose, t, vec4(0.0));
		k = 0.0;
	}
	imageStore(w_compaction, t, vec4(k));
	imageStore(w_mask, t, vec4(1.0));
	flag(t);
}

// 8 scoop, the shovel: each cell of the disc takes its share dh / slot m^3 (loose-equivalent), from its loose
// first, then the rest from the solid ground under it, the depth that share over the swell `limit` fills on the
// cell's area, stopping at bedrock_top (a rock-floored cell cuts nothing), the clay cut down with it and the
// material by the strata. counter[0] gets the loose taken plus the annulus cut (the bore's product form) times
// the swell. Water is left as it is; a cell that changed is masked and flagged. Each invocation reads and
// writes only its own cell, so any radius.
void scoop(ivec2 g) {
	ivec2 t;
	if (!disc_texel(g, t)) {
		return;
	}
	float share = pc.dh / float(pc.slot);
	float s = imageLoad(w_surface, t).r;
	float a = area(s);
	float loose = imageLoad(w_loose, t).r;
	float tl = min(loose, share / a);
	float got = tl * a;
	float rem = share - got;
	float cut = 0.0;
	if (rem > 1e-9) {
		float bt = imageLoad(w_bedrock, t).r;
		cut = min(rem / pc.limit / a, max(s - bt, 0.0));
		if (cut > 0.0) {
			float s2 = s - cut;
			float ct = min(imageLoad(w_clay_top, t).r, s2);
			imageStore(w_surface, t, vec4(s2));
			imageStore(w_clay_bottom, t, vec4(min(imageLoad(w_clay_bottom, t).r, s2)));
			imageStore(w_clay_top, t, vec4(ct));
			imageStore(w_material, t, vec4(top_material(s2, bt, ct) / 255.0));
			got += 0.5 * pc.dtheta * cut * (2.0 * (pc.R - s) + cut) * pc.limit;
		}
	}
	atomicAdd(counter[0], uint(round(got * 1e6)));
	if (tl <= 0.0 && cut <= 0.0) {
		return;
	}
	if (tl > 0.0) {
		imageStore(w_loose, t, vec4(loose - tl));
	}
	imageStore(w_mask, t, vec4(1.0));
	flag(t);
}

void main() {
	ivec2 g = ivec2(gl_GlobalInvocationID.xy);
	// pc.mode is uniform, so every invocation of a bore or push reaches its barrier.
	if (pc.mode == 3) {
		bore(g);
		return;
	}
	if (pc.mode == 4 || pc.mode == 7) {
		deposit(g);
		return;
	}
	if (pc.mode == 5) {
		push(g);
		return;
	}
	if (pc.mode == 6) {
		tamp(g);
		return;
	}
	if (pc.mode == 8) {
		scoop(g);
		return;
	}
	if (pc.mode == 0) {
		// The disc lies in the box around cell; the residency test drops rows off the station.
		ivec2 d = g - pc.radius;
		float dist = length(vec2(d));
		ivec2 t;
		if (dist > float(pc.radius) || !texel(at(d), t)) {
			return;
		}
		float q = dist / max(float(pc.radius), 1.0);
		float s = clamp(imageLoad(w_surface, t).r + pc.dh * (1.0 - q * q), 0.0, pc.h_max);
		float bt = imageLoad(w_bedrock, t).r;
		float cb = imageLoad(w_clay_bottom, t).r;
		float ct = imageLoad(w_clay_top, t).r;
		if (pc.dh < 0.0) {
			bt = min(bt, s);
			cb = min(cb, s);
			ct = min(ct, s);
		}
		imageStore(w_surface, t, vec4(s));
		imageStore(w_bedrock, t, vec4(bt));
		imageStore(w_clay_bottom, t, vec4(cb));
		imageStore(w_clay_top, t, vec4(ct));
		imageStore(w_material, t, vec4(top_material(s, bt, ct) / 255.0));
		imageStore(w_mask, t, vec4(1.0));
		flag(t);
		return;
	}
	ivec2 t = (pc.tile % pc.slots) * TILE + g;
	int i = (g.y * TILE + g.x) * 8;
	if (pc.mode == 1) {
		int o = pc.slot * TILE * TILE * 8 + i;
		uint mask = byte(imageLoad(w_mask, t).r);
		// An unedited cell packs as zeros (mask 0, which apply skips), so a tile with a few pits compresses
		// to kilobytes.
		if (mask == 0u) {
			for (int k = 0; k < 8; k++) {
				down[o + k] = 0u;
			}
			return;
		}
		down[o] = floatBitsToUint(imageLoad(w_surface, t).r);
		down[o + 1] = floatBitsToUint(imageLoad(w_bedrock, t).r);
		down[o + 2] = floatBitsToUint(imageLoad(w_clay_bottom, t).r);
		down[o + 3] = floatBitsToUint(imageLoad(w_clay_top, t).r);
		down[o + 4] = floatBitsToUint(imageLoad(w_water, t).r);
		down[o + 5] = byte(imageLoad(w_material, t).r) | byte(imageLoad(w_compaction, t).r) << 8
				| byte(imageLoad(w_saturation, t).r) << 16 | mask << 24;
		down[o + 6] = floatBitsToUint(imageLoad(w_loose, t).r);
		down[o + 7] = floatBitsToUint(imageLoad(w_depth, t).r);
		return;
	}
	uint w5 = up[i + 5];
	if ((w5 >> 24) == 0u) {
		return;
	}
	imageStore(w_surface, t, vec4(uintBitsToFloat(up[i])));
	imageStore(w_bedrock, t, vec4(uintBitsToFloat(up[i + 1])));
	imageStore(w_clay_bottom, t, vec4(uintBitsToFloat(up[i + 2])));
	imageStore(w_clay_top, t, vec4(uintBitsToFloat(up[i + 3])));
	imageStore(w_water, t, vec4(uintBitsToFloat(up[i + 4])));
	imageStore(w_material, t, vec4(float(w5 & 255u) / 255.0));
	imageStore(w_compaction, t, vec4(float((w5 >> 8) & 255u) / 255.0));
	imageStore(w_saturation, t, vec4(float((w5 >> 16) & 255u) / 255.0));
	imageStore(w_mask, t, vec4(1.0));
	imageStore(w_loose, t, vec4(uintBitsToFloat(up[i + 6])));
	imageStore(w_depth, t, vec4(uintBitsToFloat(up[i + 7])));
	if (uintBitsToFloat(up[i + 6]) > 0.0 || uintBitsToFloat(up[i + 7]) > 0.0) {
		flag(t);
	}
}
