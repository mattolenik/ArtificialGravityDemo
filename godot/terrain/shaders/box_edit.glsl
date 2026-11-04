#[compute]
#version 450

// The box's tool ops (VoxelBox.scoop and dump; push, tamp, bore and spoil follow): one workgroup of 8 x 8 x 8
// invocations over the ball's bounding box of voxels (`first`, `extent`; theta index unwrapped near the
// centre), the ball of `radius` m around `centre` (theta index, z index, height, continuous) in metres
// (across: cells times (R - h) dtheta). Modes:
// 0 scoop, one invocation per column of the bounding box (z = 0 threads): each voxel of the column loses
//   the share of its loose, then of its solid (never rock), that the ball covers: the share of SUB³
//   sub-samples inside the ball among those in the fraction's own interval of the voxel (a partial flagged
//   hanging, or under solid with air below, at its ceiling, any other on its floor, as box_pack.glsl reads
//   it); counter[0] gets the loose-equivalent m³ (solid times the material's swell) by the voxels' annuli.
//   What is left over the ball's centre is flagged hanging (a roof's underside), what is left under it sits
//   on the floor, so the pack reads a floor, a gap and a roof, and a second ball there finds the roof where
//   it is. The column's top solid voxel is not thinned by a ball centred under it (its top is the surface
//   and a fraction cannot say where in the voxel the slab sits: the roof keeps that voxel's slab whole). A
//   roof thinner than THIN_ROOF with nothing solid over it (a pit's rim undercut by the ball) drops onto the
//   floor instead. A column already holding four gaps whose voxels the ball
//   spans, and one either side, are all full solid would get a fifth: the whole scoop is refused
//   (counter[1] set).
// 1 dump, one invocation per voxel: `amount` m³ of loose fill the air of the ball's voxels nearest the
//   centre first (each invocation sums the room of the voxels before it in that order, so no two write one
//   voxel); what fits is counted in counter[0], the rest stays in the hand; the voxel's compaction is reset.
// A changed voxel flags its column dirty.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 8) in;

layout(set = 0, binding = 0, std430) restrict buffer Pool { uint pool[]; };
layout(set = 0, binding = 1, std430) restrict buffer Index { int index[]; };
layout(set = 0, binding = 2, std430) restrict buffer Dirty { uint dirty[]; };
layout(set = 0, binding = 3, std430) restrict buffer BoxStats { uint box_stats[]; };
layout(set = 0, binding = 4, std430) restrict buffer Stats { uint stats[]; };
layout(set = 0, binding = 5, std430) restrict buffer Free { int free_top; int free_list[]; };
layout(set = 0, binding = 6, std430) restrict buffer Needed { uint needed[]; };
layout(set = 0, binding = 7, std430) restrict readonly buffer Cells { ivec2 cells[]; };
layout(set = 0, binding = 8, std430) restrict buffer Counter { uint counter[2]; };
layout(set = 0, binding = 9, r32f) uniform restrict readonly image2D w_surface;
layout(set = 0, binding = 10, r32f) uniform restrict readonly image2D w_bedrock;
layout(set = 0, binding = 11, r32f) uniform restrict readonly image2D w_clay_bottom;
layout(set = 0, binding = 12, r32f) uniform restrict readonly image2D w_clay_top;
layout(set = 0, binding = 13, r32f) uniform restrict readonly image2D w_water;
layout(set = 0, binding = 14, r8) uniform restrict readonly image2D w_material;
layout(set = 0, binding = 15, r8) uniform restrict readonly image2D w_compaction;
layout(set = 0, binding = 16, r8) uniform restrict readonly image2D w_saturation;
layout(set = 0, binding = 17, r8) uniform restrict readonly image2D w_mask;
layout(set = 0, binding = 18, r32f) uniform restrict readonly image2D w_loose;
layout(set = 0, binding = 19, r32f) uniform restrict readonly image2D w_depth;
layout(set = 0, binding = 20, r32f) uniform restrict readonly image2D w_gap_bottom0;
layout(set = 0, binding = 21, r32f) uniform restrict readonly image2D w_gap_bottom1;
layout(set = 0, binding = 22, r32f) uniform restrict readonly image2D w_gap_bottom2;
layout(set = 0, binding = 23, r32f) uniform restrict readonly image2D w_gap_bottom3;
layout(set = 0, binding = 24, r32f) uniform restrict readonly image2D w_gap_top0;
layout(set = 0, binding = 25, r32f) uniform restrict readonly image2D w_gap_top1;
layout(set = 0, binding = 26, r32f) uniform restrict readonly image2D w_gap_top2;
layout(set = 0, binding = 27, r32f) uniform restrict readonly image2D w_gap_top3;
layout(set = 0, binding = 28, r32f) uniform restrict readonly image2D w_gap_loose0;
layout(set = 0, binding = 29, r32f) uniform restrict readonly image2D w_gap_loose1;
layout(set = 0, binding = 30, r32f) uniform restrict readonly image2D w_gap_loose2;
layout(set = 0, binding = 31, r32f) uniform restrict readonly image2D w_gap_loose3;
layout(set = 0, binding = 32, r8) uniform restrict readonly image2D w_gap_material0;
layout(set = 0, binding = 33, r8) uniform restrict readonly image2D w_gap_material1;
layout(set = 0, binding = 34, r8) uniform restrict readonly image2D w_gap_material2;
layout(set = 0, binding = 35, r8) uniform restrict readonly image2D w_gap_material3;

layout(push_constant, std430) uniform Params {
	ivec3 origin;      // the box origin in bricks
	int mode;
	ivec3 first;       // the bounding box's first voxel (theta index unwrapped near the centre, z index, height index)
	int n_theta;
	ivec3 extent;      // voxels per axis, at most 8
	int slots;
	vec3 centre;       // the ball's centre (theta index, z index, height), continuous
	float radius;      // m
	vec4 swell;        // the materials' swell factors
	float amount;      // dump: m³
	float R;
	float dtheta;
	int n_z;
	ivec2 first_tile;
	int around;
	int pad;
} pc;

#include "box_column.glslh"

const int SUB = 8;
// A roof thinner than this, in m, with nothing solid over it, drops onto the floor of the cut.
const float THIN_ROOF = 0.3;
shared uint refuse;

// The brick slot of voxel ck (theta unwrapped, z, height index), -1 outside the box or off the station.
int slot_of_voxel(ivec3 ck) {
	ivec2 c = ivec2(wrap(ck.x, pc.n_theta), ck.y);
	if (c.y < 0 || c.y >= pc.n_z) {
		return -1;
	}
	bool inbox;
	ivec2 s = slot_of_cell(c, pc.origin, inbox);
	int k0 = pc.origin.z * 16;
	if (!inbox || ck.z < k0 || ck.z >= k0 + K) {
		return -1;
	}
	return slot_index(ivec3(s.x / 16, s.y / 16, wrap(ck.z >> 4, 4)));
}

// Wakes the brick holding voxel ck (bit 0 of its slot: the sand steps it).
void wake(ivec3 ck) {
	int e = slot_of_voxel(ck);
	if (e >= 0) {
		atomicOr(box_stats[e], 1u);
	}
}

// The pool address of voxel ck (theta unwrapped, z, height index) and its column's dirty index; false when
// it lies outside the box, off the station or in an unallocated (air) slot.
bool voxel_addr(ivec3 ck, out int addr, out int col) {
	ivec2 c = ivec2(wrap(ck.x, pc.n_theta), ck.y);
	if (c.y < 0 || c.y >= pc.n_z) {
		return false;
	}
	bool inbox;
	ivec2 s = slot_of_cell(c, pc.origin, inbox);
	int k0 = pc.origin.z * 16;
	if (!inbox || ck.z < k0 || ck.z >= k0 + K) {
		return false;
	}
	int b = index[slot_index(ivec3(s.x / 16, s.y / 16, wrap(ck.z >> 4, 4)))];
	if (b < 0) {
		return false;
	}
	addr = b * VOXELS_PER_BRICK * 2 + (((ck.z & 15) * 16 + (s.y & 15)) * 16 + (s.x & 15)) * 2;
	col = s.y * COLUMNS + s.x;
	return true;
}

uint solid_of(ivec3 ck) {
	int addr, col;
	return voxel_addr(ck, addr, col) ? pool[addr] & 0xFFFFu : 0u;
}

// Whether the sub-sample at (a, b, c) of voxel ck lies in the ball.
bool in_ball(ivec3 ck, int a, int b, int c) {
	float h = float(ck.z) + (float(c) + 0.5) / float(SUB);
	float dx = (float(ck.x) + (float(a) + 0.5) / float(SUB) - pc.centre.x) * (pc.R - h) * pc.dtheta;
	float dz = float(ck.y) + (float(b) + 0.5) / float(SUB) - pc.centre.y;
	float dh = h - pc.centre.z;
	return dx * dx + dz * dz + dh * dh <= pc.radius * pc.radius;
}

// The share of the sub-samples in the rows of the voxel's interval [lo, hi] (relative height; the row within
// half a spacing of the interval counts, so a sliver has one) that lie in the ball.
float covered(ivec3 ck, float lo, float hi) {
	int n = 0;
	int total = 0;
	for (int c = 0; c < SUB; c++) {
		float ry = (float(c) + 0.5) / float(SUB);
		if (ry < lo - 0.5 / float(SUB) || ry > hi + 0.5 / float(SUB)) {
			continue;
		}
		for (int a = 0; a < SUB; a++) {
			for (int b = 0; b < SUB; b++) {
				total++;
				n += in_ball(ck, a, b, c) ? 1 : 0;
			}
		}
	}
	return total > 0 ? float(n) / float(total) : 0.0;
}

float vol(int k) {
	return pc.dtheta * (pc.R - float(k) - 0.5);
}

// Whether a scoop would give the column at ckxy a fifth gap: four stored already, and the ball's voxels
// there plus one either side all full solid.
bool fifth_gap(ivec2 ckxy) {
	ivec2 t;
	if (!texel(ivec2(wrap(ckxy.x, pc.n_theta), ckxy.y), t)) {
		return false;
	}
	Col col = read_col(t);
	int gaps = 0;
	for (int g = 0; g < 4; g++) {
		gaps += col.gt[g] > col.gb[g] ? 1 : 0;
	}
	if (gaps < 4) {
		return false;
	}
	for (int k = pc.first.z - 1; k <= pc.first.z + pc.extent.z; k++) {
		if (solid_of(ivec3(ckxy, k)) < uint(ONE)) {
			return false;
		}
	}
	return true;
}

// Fractions q of a volume v over voxel k, at most room: the count placed.
uint place(float v, int k, uint room) {
	return min(uint(roundh(v / vol(k) * ONE)), room);
}

void scoop_column(ivec2 cxz) {
	int kz0 = pc.first.z;
	int nk = pc.extent.z;
	int addr[8];
	bool ok[8];
	uint fs[8], fl[8], mt[8], hg[8], w1s[8];
	bool have = true;
	int col = 0;
	for (int i = 0; i < 8; i++) {
		fs[i] = 0u;
		fl[i] = 0u;
		mt[i] = 0u;
		hg[i] = 0u;
		w1s[i] = 0u;
		ok[i] = false;
		if (i >= nk) {
			continue;
		}
		int c;
		ok[i] = voxel_addr(ivec3(cxz, kz0 + i), addr[i], c);
		if (ok[i]) {
			col = c;
			uint w0 = pool[addr[i]];
			fs[i] = w0 & 0xFFFFu;
			fl[i] = w0 >> 16;
			w1s[i] = pool[addr[i] + 1];
			mt[i] = w1s[i] & 255u;
			hg[i] = (w1s[i] >> 24) & 1u;
		} else {
			have = false;
		}
	}
	uint below = solid_of(ivec3(cxz, kz0 - 1));
	uint above = solid_of(ivec3(cxz, kz0 + nk));
	int top = -1;
	if (above == 0u) {
		for (int i = 0; i < nk; i++) {
			top = fs[i] > 0u ? i : top;
		}
	}
	float got = 0.0;
	bool any = false;
	for (int i = 0; i < nk; i++) {
		if (fs[i] == 0u && fl[i] == 0u) {
			continue;
		}
		ivec3 ck = ivec3(cxz, kz0 + i);
		bool solid_below = i > 0 ? fs[i - 1] > 0u : below > 0u;
		bool solid_above = i + 1 < nk ? fs[i + 1] > 0u : above > 0u;
		bool hanging = fs[i] > 0u && fs[i] < uint(ONE) && (hg[i] != 0u || (!solid_below && solid_above));
		bool keep_top = i == top && pc.centre.z < float(ck.z);
		float a = float(fs[i]) / ONE;
		float b = float(fl[i]) / ONE;
		uint took_s = (fs[i] > 0u && mt[i] < 2u && !keep_top) ? uint(roundh(float(fs[i]) * covered(ck, hanging ? 1.0 - a : 0.0, hanging ? 1.0 : a))) : 0u;
		uint took_l = fl[i] > 0u ? uint(roundh(float(fl[i]) * covered(ck, hanging ? 0.0 : a, (hanging ? 0.0 : a) + b))) : 0u;
		if (took_s == 0u && took_l == 0u) {
			continue;
		}
		got += (float(took_l) + float(took_s) * pc.swell[mt[i]]) / ONE * vol(ck.z);
		fs[i] -= took_s;
		fl[i] -= took_l;
		if (took_s > 0u && i != top) {
			hg[i] = float(ck.z) + 0.5 > pc.centre.z ? 1u : 0u;
		}
		any = true;
	}
	if (!any) {
		return;
	}
	atomicAdd(counter[0], uint(roundh(got * 1e6)));
	// The cut leaves a floor piece in its lowest voxels and, over the ball's centre, a roof piece: kept where it
	// is (the pack hangs its underside from the solid over it) when solid lies over the box or it is at least
	// THIN_ROOF thick; a thinner overhang with nothing over it (a pit's rim undercut by the ball) drops onto the
	// floor, its volume kept. Not when it holds rock.
	if (have && above == 0u) {
		float sa = 0.0;
		bool rock_above = false;
		for (int i = 0; i < nk; i++) {
			if (float(kz0 + i) + 0.5 > pc.centre.z) {
				sa += float(fs[i]) / ONE * vol(kz0 + i);
				rock_above = rock_above || (fs[i] > 0u && mt[i] >= 2u);
			}
		}
		if (sa > 0.0 && !rock_above && sa < THIN_ROOF * vol(kz0 + nk - 1)) {
			for (int i = 0; i < nk; i++) {
				if (float(kz0 + i) + 0.5 > pc.centre.z) {
					fs[i] = 0u;
				}
			}
			float rem = sa;
			for (int i = 0; i < nk && rem > 0.0; i++) {
				uint q = place(rem, kz0 + i, uint(ONE) - fs[i] - fl[i]);
				fs[i] += q;
				rem -= float(q) / ONE * vol(kz0 + i);
			}
		}
	}
	for (int i = 0; i < nk; i++) {
		if (ok[i]) {
			pool[addr[i]] = fs[i] | (fl[i] << 16);
			pool[addr[i] + 1] = (w1s[i] & 0x00FFFFFFu) | ((fs[i] > 0u ? hg[i] : 0u) << 24);
		}
	}
	wake(ivec3(cxz, kz0));
	wake(ivec3(cxz, kz0 + nk - 1));
	dirty[col] = 1u;
}

// The air of voxel ck in m³ when the ball reaches it (its nearest point within radius), else 0.
float room_of(ivec3 ck, out int addr, out int col) {
	if (!voxel_addr(ck, addr, col)) {
		return 0.0;
	}
	vec3 lo = vec3(ck);
	vec3 hi = lo + 1.0;
	vec3 q = clamp(pc.centre, lo, hi);
	float dx = (q.x - pc.centre.x) * (pc.R - q.z) * pc.dtheta;
	float dz = q.y - pc.centre.y;
	float dh = q.z - pc.centre.z;
	if (dx * dx + dz * dz + dh * dh > pc.radius * pc.radius) {
		return 0.0;
	}
	uint w0 = pool[addr];
	return float(int(ONE) - int(w0 & 0xFFFFu) - int(w0 >> 16)) / ONE * vol(ck.z);
}

float dist_of(ivec3 ck) {
	vec3 c = vec3(ck) + 0.5;
	float dx = (c.x - pc.centre.x) * (pc.R - c.z) * pc.dtheta;
	return dx * dx + (c.y - pc.centre.y) * (c.y - pc.centre.y) + (c.z - pc.centre.z) * (c.z - pc.centre.z);
}

void dump(ivec3 l, ivec3 ck) {
	int addr, col;
	float mine = room_of(ck, addr, col);
	if (mine <= 0.0) {
		return;
	}
	float d = dist_of(ck);
	int me = (l.z * 8 + l.y) * 8 + l.x;
	float before = 0.0;
	for (int z = 0; z < pc.extent.z; z++) {
		for (int y = 0; y < pc.extent.y; y++) {
			for (int x = 0; x < pc.extent.x; x++) {
				int i = (z * 8 + y) * 8 + x;
				if (i == me) {
					continue;
				}
				ivec3 o = pc.first + ivec3(x, y, z);
				float od = dist_of(o);
				if (od < d || (od == d && i < me)) {
					int oa, oc;
					before += room_of(o, oa, oc);
				}
			}
		}
	}
	float share = clamp(pc.amount - before, 0.0, mine);
	uint q = uint(floor(share / vol(ck.z) * ONE));
	if (q == 0u) {
		return;
	}
	uint w0 = pool[addr];
	pool[addr] = (w0 & 0xFFFFu) | (((w0 >> 16) + q) << 16);
	pool[addr + 1] &= ~0xFF00u;
	atomicAdd(counter[0], uint(roundh(float(q) / ONE * vol(ck.z) * 1e6)));
	dirty[col] = 1u;
	wake(ck);
}

void main() {
	ivec3 l = ivec3(gl_LocalInvocationID);
	bool in_box = all(lessThan(l, pc.extent));
	ivec3 ck = pc.first + l;
	if (pc.mode == 0) {
		if (l == ivec3(0)) {
			refuse = 0u;
		}
		barrier();
		if (in_box && l.z == 0 && fifth_gap(ck.xy)) {
			atomicOr(refuse, 1u);
		}
		barrier();
		if (refuse != 0u) {
			if (l == ivec3(0)) {
				atomicOr(counter[1], 1u);
			}
			return;
		}
		if (in_box && l.z == 0) {
			scoop_column(ck.xy);
		}
		return;
	}
	if (pc.mode == 1 && in_box) {
		dump(l, ck);
	}
}
