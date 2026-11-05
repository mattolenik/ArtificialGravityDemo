#[compute]
#version 450

// The box's loose-dirt simulation (VoxelBox.step; the tunnels design's sand rule): one fixed 1/60 s step is
// one compute list of a flux dispatch per active brick, a barrier, and an apply dispatch per active brick,
// one invocation per column (x, z) of the brick. By mode:
// 0 flux: each loose voxel with room under it falls: a quarter of that room a step (the whole fraction when it
//   fits) into the voxel below. The top loose voxel of each stack (no loose over it) slumps to the eight
//   neighbouring stacks' tops by slice 3's rule: slump_rate of the excess of its top over the neighbour's
//   ground (the first material found scanning the neighbour down from this height, at most a brick) past the
//   repose line (dry to saturated by the column's saturation, over the edge distance), each neighbour taking at
//   most a thirty-second of its room a step, so the arrivals at any voxel never pass its room. A volume
//   leaves as counts of the source voxel (`out`) and arrives as counts of the target voxel (`arrive`, atomic,
//   the annuli's ratio), both in the flux buffer of the target's active brick; a target in a brick that is
//   not active is woken (bit 1 of its slot) and nothing moves there this step, one in an unallocated (air)
//   brick is flagged needed (the next step's allocate gives it a brick) and woken, one outside the box or in
//   the obstacle keeps the material where it is.
//   Slope stability with the free height: the column's surface voxel (its top solid voxel, the one the
//   window's surface lies in) standing over a disturbed neighbour's ground (the window's edit_mask set; its
//   surface plus loose) by more than max(stand slope × edge distance, free height), both mixed dry to
//   saturated by the column's saturation (Materials), fails by slump_rate of the excess, at most the voxel's
//   solid, never under bedrock_top, never rock: the solid leaves as `out`'s high half and arrives as loose
//   times the swell in the voxel's own room (half of it at most) and the room over it (a quarter at most, so
//   the falls' and slumps' shares still fit beside it); less failure when less fits.
//   The span rule (span_column, after the slope stability): a roof voxel (dirt or clay holding any solid, the
//   voxel under it holding under a quarter) reaches half the material's free height (its roof span), dry to
//   saturated by the column's saturation, times the roof's thickness (the solid from it up to the first voxel
//   under a quarter, in metres, capped at one). In the layer under it, within the reach (theta scaled by the
//   cell's width), a support is a voxel holding half a voxel of solid and loose together, a pillar, a post's
//   cap (the voxel standing on a pillar voxel, which a neighbour's roof voxel a layer over the post's top
//   reads), or one outside the box (VoxelBox.span_fails): with none it fails, and with the nearest beyond half
//   the reach and none across from it (more than a right angle away) it fails as a cantilever. It fails as the slope
//   stability's voxel does, slump_rate of its solid a step (all of it once that is under move_eps): `out`'s high
//   half, arriving as loose times the swell in its own room (half at most; a quarter when the voxel over it
//   may fail into it too) and the room of the air voxel under it (a quarter at most). The apply pass's face rule
//   wakes the brick over a failing top voxel, so a chimney climbs across bricks.
// 1 apply: each voxel takes its arrivals, loses what it sent, stores the result when it changed, flags its
//   column dirty (the pack writes the window) and, over move_eps, its brick active (bit 0 of its slot) and the
//   brick across any face it lies on (bit 1).

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict buffer Pool { uint pool[]; };
layout(set = 0, binding = 1, std430) restrict buffer Index { int index[]; };
layout(set = 0, binding = 2, std430) restrict buffer Dirty { uint dirty[]; };
layout(set = 0, binding = 3, std430) restrict buffer BoxStats { uint box_stats[]; };
layout(set = 0, binding = 4, std430) restrict buffer Stats { uint stats[]; };
layout(set = 0, binding = 5, std430) restrict buffer Free { int free_top; int free_list[]; };
layout(set = 0, binding = 6, std430) restrict buffer Needed { uint needed[]; };
layout(set = 0, binding = 7, std430) restrict readonly buffer Cells { ivec2 cells[]; };
// Per active brick (its active index) and voxel: what leaves (loose | solid << 16) and what arrives (loose).
layout(set = 0, binding = 8, std430) restrict buffer Flux { uint flux[]; };
// Per brick slot: its index among the active bricks this step, -1 when not active.
layout(set = 0, binding = 9, std430) restrict readonly buffer Active { int active_of[]; };
// Per material: tan of the stand slope dry and saturated, the swell, the free height dry and saturated
// (VoxelBox.material_table).
layout(set = 0, binding = 10, std430) restrict readonly buffer Materials {
	float stand_dry[5];
	float stand_sat[5];
	float swell[5];
	float free_dry[5];
	float free_sat[5];
} mt;
layout(set = 0, binding = 11, r32f) uniform restrict readonly image2D w_surface;
layout(set = 0, binding = 12, r32f) uniform restrict readonly image2D w_bedrock;
layout(set = 0, binding = 13, r32f) uniform restrict readonly image2D w_clay_bottom;
layout(set = 0, binding = 14, r32f) uniform restrict readonly image2D w_clay_top;
layout(set = 0, binding = 15, r32f) uniform restrict readonly image2D w_water;
layout(set = 0, binding = 16, r8) uniform restrict readonly image2D w_material;
layout(set = 0, binding = 17, r8) uniform restrict readonly image2D w_compaction;
layout(set = 0, binding = 18, r8) uniform restrict readonly image2D w_saturation;
layout(set = 0, binding = 19, r8) uniform restrict readonly image2D w_mask;
layout(set = 0, binding = 20, r32f) uniform restrict readonly image2D w_loose;
layout(set = 0, binding = 21, r32f) uniform restrict readonly image2D w_depth;
layout(set = 0, binding = 22, r32f) uniform restrict readonly image2D w_gap_bottom0;
layout(set = 0, binding = 23, r32f) uniform restrict readonly image2D w_gap_bottom1;
layout(set = 0, binding = 24, r32f) uniform restrict readonly image2D w_gap_bottom2;
layout(set = 0, binding = 25, r32f) uniform restrict readonly image2D w_gap_bottom3;
layout(set = 0, binding = 26, r32f) uniform restrict readonly image2D w_gap_top0;
layout(set = 0, binding = 27, r32f) uniform restrict readonly image2D w_gap_top1;
layout(set = 0, binding = 28, r32f) uniform restrict readonly image2D w_gap_top2;
layout(set = 0, binding = 29, r32f) uniform restrict readonly image2D w_gap_top3;
layout(set = 0, binding = 30, r32f) uniform restrict readonly image2D w_gap_loose0;
layout(set = 0, binding = 31, r32f) uniform restrict readonly image2D w_gap_loose1;
layout(set = 0, binding = 32, r32f) uniform restrict readonly image2D w_gap_loose2;
layout(set = 0, binding = 33, r32f) uniform restrict readonly image2D w_gap_loose3;
layout(set = 0, binding = 34, r8) uniform restrict readonly image2D w_gap_material0;
layout(set = 0, binding = 35, r8) uniform restrict readonly image2D w_gap_material1;
layout(set = 0, binding = 36, r8) uniform restrict readonly image2D w_gap_material2;
layout(set = 0, binding = 37, r8) uniform restrict readonly image2D w_gap_material3;

layout(push_constant, std430) uniform Params {
	ivec3 origin;          // the box origin in bricks
	int mode;              // 0 flux, 1 apply
	ivec3 brick;           // the brick stepped (world index: theta brick in the origin's frame, z brick, height brick)
	int active_i;          // its index among the active bricks (`active` is a reserved word)
	ivec2 first_tile;      // first tile of the window's wanted set (theta wrapped, z)
	int n_theta;
	int slots;
	int n_z;
	int around;
	float R;
	float dtheta;
	ivec2 obstacle;        // nothing moves into a cell within obstacle_radius cells of it
	int obstacle_radius;   // negative: no obstacle
	float slump_rate;
	vec3 repose_tan;       // dirt's repose, dry, damp and saturated
	float move_eps;        // m; the smallest change that flags activity
} pc;

#include "box_column.glslh"

const int FALL_SHARE = 4;
const int SIDE_SHARE = 32;
const int FAIL_SHARE = 2;
const int UP_SHARE = 4;
const ivec2 DIR8[8] = ivec2[8](ivec2(1, 0), ivec2(0, 1), ivec2(-1, 0), ivec2(0, -1), ivec2(1, 1), ivec2(-1, 1), ivec2(-1, -1), ivec2(1, -1));

// A voxel's whereabouts: ok with its pool address when it lies in an allocated brick of the box; e (its slot)
// and col (its column) valid whenever it lies in the box and on the station, else -1.
struct V {
	bool ok;
	int addr;
	int e;
	int col;
	int vi;
};

V find(ivec3 ck) {
	V v;
	v.ok = false;
	v.addr = -1;
	v.e = -1;
	v.col = -1;
	v.vi = -1;
	ivec2 c = ivec2(wrap(ck.x, pc.n_theta), ck.y);
	if (c.y < 0 || c.y >= pc.n_z) {
		return v;
	}
	bool inbox;
	ivec2 s = slot_of_cell(c, pc.origin, inbox);
	int k0 = pc.origin.z * 16;
	if (!inbox || ck.z < k0 || ck.z >= k0 + K) {
		return v;
	}
	v.e = slot_index(ivec3(s.x / 16, s.y / 16, wrap(ck.z >> 4, BRICKS_UP)));
	v.col = s.y * COLUMNS + s.x;
	v.vi = ((ck.z & 15) * 16 + (s.y & 15)) * 16 + (s.x & 15);
	int b = index[v.e];
	if (b < 0) {
		return v;
	}
	v.addr = b * VOXELS_PER_BRICK * 2 + v.vi * 2;
	v.ok = true;
	return v;
}

float vol(int k) {
	return pc.dtheta * (pc.R - float(k) - 0.5);
}

bool blocked(ivec2 c) {
	if (pc.obstacle_radius < 0) {
		return false;
	}
	int half_n = pc.n_theta / 2;
	ivec2 d = ivec2(wrap(c.x - pc.obstacle.x + half_n, pc.n_theta) - half_n, c.y - pc.obstacle.y);
	return d.x * d.x + d.y * d.y <= pc.obstacle_radius * pc.obstacle_radius;
}

// Whether material may move into voxel v now: in an active, allocated brick. Otherwise the brick is woken
// (and flagged needed when it has no brick: air that loose would fall or slump into).
bool open(V v, out int ai) {
	ai = -1;
	if (v.e < 0) {
		return false;
	}
	if (!v.ok) {
		atomicOr(needed[v.e], 1u);
		atomicOr(box_stats[v.e], 2u);
		return false;
	}
	ai = active_of[v.e];
	if (ai < 0) {
		atomicOr(box_stats[v.e], 2u);
		return false;
	}
	return true;
}

// Sends q counts of voxel k (its own units) to voxel v at height kt in active brick ai: arrives as counts of
// the target's annulus.
void send(V v, int ai, int k, int kt, uint q) {
	uint qt = uint(roundh(float(q) * vol(k) / vol(kt)));
	atomicAdd(flux[(ai * VOXELS_PER_BRICK + v.vi) * 2 + 1], qt);
}

// The column flux_column reads (its solid, loose and material per voxel) and its saturation, for span_column.
uint fs[16], fl[16], mt_[16];
float sat;

void flux_column(ivec2 cxz, int kz0, int my_e, int my_ai) {
	// A column off the station, or not of the box, has no voxels to read.
	if (!find(ivec3(cxz, kz0)).ok) {
		return;
	}
	for (int y = 0; y < 16; y++) {
		V v = find(ivec3(cxz, kz0 + y));
		uint w0 = pool[v.addr];
		fs[y] = w0 & 0xFFFFu;
		fl[y] = w0 >> 16;
		mt_[y] = pool[v.addr + 1] & 255u;
	}
	ivec2 t;
	bool resident = texel(ivec2(wrap(cxz.x, pc.n_theta), cxz.y), t);
	sat = resident ? imageLoad(w_saturation, t).r : 0.0;
	float tr = sat < 0.5 ? mix(pc.repose_tan.x, pc.repose_tan.y, 2.0 * sat) : mix(pc.repose_tan.y, pc.repose_tan.z, 2.0 * sat - 1.0);
	// The loose over the brick's top voxel, for the stack-top test at y = 15.
	V va = find(ivec3(cxz, kz0 + 16));
	uint above_l = va.ok ? pool[va.addr] >> 16 : 0u;
	for (int y = 15; y >= 0; y--) {
		if (fl[y] == 0u) {
			continue;
		}
		int k = kz0 + y;
		uint rem = fl[y];
		uint out_l = 0u;
		// Fall.
		V vb = find(ivec3(cxz, k - 1));
		int ai;
		if (y > 0) {
			int room = int(ONE) - int(fs[y - 1]) - int(fl[y - 1]);
			if (room > 0) {
				uint q = min(rem, uint(room / FALL_SHARE));
				if (q > 0u) {
					send(vb, my_ai, k, k - 1, q);
					out_l += q;
					rem -= q;
				}
			}
		} else if (open(vb, ai)) {
			uint w0 = pool[vb.addr];
			int room = int(ONE) - int(w0 & 0xFFFFu) - int(w0 >> 16);
			if (room > 0) {
				uint q = min(rem, uint(room / FALL_SHARE));
				if (q > 0u) {
					send(vb, ai, k, k - 1, q);
					out_l += q;
					rem -= q;
				}
			}
		}
		// Slump from a stack top.
		bool top = y < 15 ? fl[y + 1] == 0u : above_l == 0u;
		if (top && rem > 0u) {
			float H = float(k) + float(fs[y] + fl[y]) / ONE;
			uint q_d[8];
			V tv[8];
			int ta[8];
			int tk[8];
			uint total = 0u;
			for (int d = 0; d < 8; d++) {
				q_d[d] = 0u;
				ivec2 n = cxz + DIR8[d];
				if (blocked(ivec2(wrap(n.x, pc.n_theta), n.y))) {
					continue;
				}
				// The neighbour's ground: scanning down from this height, at most a brick.
				float h_n = float(k - 16);
				V g;
				g.ok = false;
				g.e = -1;
				int gk = k - 16;
				bool wall = false;
				for (int kk = k; kk > k - 16; kk--) {
					V vn = find(ivec3(n, kk));
					if (vn.e < 0) {
						wall = true;  // outside the box: nothing moves there
						break;
					}
					if (!vn.ok) {
						continue;  // air (an unallocated brick)
					}
					uint w0 = pool[vn.addr];
					uint s_n = w0 & 0xFFFFu;
					uint l_n = w0 >> 16;
					if (s_n + l_n > 0u) {
						if (kk == k && s_n == uint(ONE)) {
							wall = true;
						}
						h_n = float(kk) + float(s_n + l_n) / ONE;
						g = vn;
						gk = kk;
						break;
					}
					g = vn;  // the lowest air seen
					gk = kk;
				}
				if (wall || g.e < 0) {
					continue;
				}
				float across = 0.5 * ((pc.R - H) + (pc.R - h_n)) * pc.dtheta;
				float w = DIR8[d].y == 0 ? across : (DIR8[d].x == 0 ? 1.0 : sqrt(across * across + 1.0));
				float ex = (H - h_n) - tr * w;
				if (ex <= 0.0) {
					continue;
				}
				// The target: the ground voxel while it has at least a quarter of room (a share of a shrinking
				// room would never fill it), else the air over it.
				V target = g;
				int kt = gk;
				int room = 0;
				if (g.ok) {
					uint w0 = pool[g.addr];
					room = int(ONE) - int(w0 & 0xFFFFu) - int(w0 >> 16);
				}
				if (room < int(ONE) / 4) {
					if (gk + 1 > k) {
						continue;
					}
					target = find(ivec3(n, gk + 1));
					kt = gk + 1;
					if (target.ok) {
						uint w0 = pool[target.addr];
						room = int(ONE) - int(w0 & 0xFFFFu) - int(w0 >> 16);
					} else {
						room = int(ONE);
					}
				}
				if (!open(target, ai) || room <= 0) {
					continue;
				}
				// At most a share of the target's room, in the source's units (the annuli's ratio).
				uint cap = uint(float(room / SIDE_SHARE) * vol(kt) / vol(k));
				uint q = min(uint(roundh(pc.slump_rate * ex * ONE)), cap);
				if (q == 0u) {
					continue;
				}
				q_d[d] = q;
				tv[d] = target;
				ta[d] = ai;
				tk[d] = kt;
				total += q;
			}
			// What the voxel holds goes to the directions in turn (a proportional split would floor a sliver's
			// counts to nothing and jam the stack under it).
			for (int d = 0; d < 8; d++) {
				uint q = min(q_d[d], rem);
				if (q > 0u) {
					send(tv[d], ta[d], k, tk[d], q);
					out_l += q;
					rem -= q;
				}
			}
		}
		if (out_l > 0u) {
			V me = find(ivec3(cxz, k));
			flux[(my_ai * VOXELS_PER_BRICK + me.vi) * 2] = out_l;
		}
	}
	// Slope stability at the surface voxel.
	if (!resident) {
		return;
	}
	float surf = imageLoad(w_surface, t).r;
	int k_top = int(ceil(surf)) - 1;
	int y_top = k_top - kz0;
	if (y_top < 0 || y_top > 15 || fs[y_top] == 0u || mt_[y_top] >= 2u) {
		return;
	}
	float s_h = float(k_top) + float(fs[y_top]) / ONE;
	uint m = mt_[y_top];
	float stand = mix(mt.stand_dry[m], mt.stand_sat[m], sat);
	float free_h = mix(mt.free_dry[m], mt.free_sat[m], sat);
	float fail = 0.0;
	for (int d = 0; d < 8; d++) {
		ivec2 n = cxz + DIR8[d];
		ivec2 tn;
		if (!texel(ivec2(wrap(n.x, pc.n_theta), n.y), tn) || byte(imageLoad(w_mask, tn).r) == 0u || blocked(ivec2(wrap(n.x, pc.n_theta), n.y))) {
			continue;
		}
		float h_n = imageLoad(w_surface, tn).r + imageLoad(w_loose, tn).r;
		float across = 0.5 * ((pc.R - s_h) + (pc.R - h_n)) * pc.dtheta;
		float w = DIR8[d].y == 0 ? across : (DIR8[d].x == 0 ? 1.0 : sqrt(across * across + 1.0));
		fail = max(fail, (s_h - h_n) - max(stand * w, free_h));
	}
	if (fail <= 1e-3) {
		return;
	}
	fail = min(pc.slump_rate * fail, max(s_h - imageLoad(w_bedrock, t).r, 0.0));
	uint cut = min(uint(roundh(fail * ONE)), fs[y_top]);
	if (cut == 0u) {
		return;
	}
	// The loose gain, with the swell, goes into half of this voxel's room after the cut and a quarter of the
	// room over it (in this voxel's units): cut · swell ≤ (room + cut) / 2 + room_up / 4, so
	// cut ≤ (room + room_up / 2) / (2 swell − 1); less fails when less fits. A count of rounding past the
	// quarter stays here: with the falls' and slumps' shares it still fits.
	V me = find(ivec3(cxz, k_top));
	V va2 = find(ivec3(cxz, k_top + 1));
	int ai2 = my_ai;
	int room = int(ONE) - int(fs[y_top]) - int(fl[y_top]);
	int room_up = 0;
	if (y_top < 15) {
		room_up = int(ONE) - int(fs[y_top + 1]) - int(fl[y_top + 1]);
	} else if (open(va2, ai2)) {
		uint w0 = pool[va2.addr];
		room_up = int(ONE) - int(w0 & 0xFFFFu) - int(w0 >> 16);
	}
	room_up = int(float(room_up) * vol(k_top + 1) / vol(k_top));
	float swell = mt.swell[m];
	cut = min(cut, uint(floor((float(room) + 0.5 * float(room_up)) / (2.0 * swell - 1.0))));
	if (cut == 0u) {
		return;
	}
	uint gain = uint(roundh(float(cut) * swell));
	uint up = min(gain - min(gain, uint((room + int(cut)) / FAIL_SHARE)), uint(room_up / UP_SHARE));
	uint here = gain - up;
	if (up > 0u) {
		send(va2, ai2, k_top, k_top + 1, up);
	}
	uint o = flux[(my_ai * VOXELS_PER_BRICK + me.vi) * 2];
	flux[(my_ai * VOXELS_PER_BRICK + me.vi) * 2] = o | (cut << 16);
	if (here > 0u) {
		atomicAdd(flux[(my_ai * VOXELS_PER_BRICK + me.vi) * 2 + 1], here);
	}
}

// Whether voxel p of the support layer holds a roof: half a voxel of solid and loose together, or a pillar; a
// voxel outside the box (beyond the index laterally, or under its bottom) counts as support, air (an unallocated
// brick) does not.
bool support(ivec3 p) {
	V v = find(p);
	if (v.e < 0) {
		return true;
	}
	if (!v.ok) {
		return false;
	}
	uint w0 = pool[v.addr];
	if ((w0 & 0xFFFFu) + (w0 >> 16) >= uint(ONE) / 2u || (pool[v.addr + 1] & 255u) == uint(PILLAR)) {
		return true;
	}
	// A post's cap: the voxel standing on a pillar voxel, the roof's partial the post holds up.
	V u = find(p - ivec3(0, 0, 1));
	return u.ok && (pool[u.addr + 1] & 255u) == uint(PILLAR);
}

// The span rule at the column's roof voxels, after flux_column has read the column (fs, fl, mt_, sat).
void span_column(ivec2 cxz, int kz0, int my_ai) {
	uint quarter = uint(ONE) / 4u;
	// The voxel under the brick's bottom voxel; outside the box it is solid (no roof voxel over it).
	V vb = find(ivec3(cxz, kz0 - 1));
	uint below_s = vb.e < 0 ? uint(ONE) : (vb.ok ? pool[vb.addr] & 0xFFFFu : 0u);
	for (int y = 0; y < 16; y++) {
		uint s_below = y > 0 ? fs[y - 1] : below_s;
		if (fs[y] == 0u || mt_[y] >= 2u || s_below >= quarter) {
			continue;
		}
		int k = kz0 + y;
		V me = find(ivec3(cxz, k));
		int fi = (my_ai * VOXELS_PER_BRICK + me.vi) * 2;
		if ((flux[fi] >> 16) != 0u) {
			continue;  // the slope stability already cut it this step
		}
		// The thickness: the solid from this voxel up to the first under a quarter, in metres, capped at one.
		float th = 0.0;
		uint s_up = 0u;
		uint m_up = 255u;
		for (int ky = y; ky <= y + 4 && th < 1.0; ky++) {
			uint s_k = 0u;
			uint m_k = 255u;
			if (ky < 16) {
				s_k = fs[ky];
				m_k = mt_[ky];
			} else {
				V vu = find(ivec3(cxz, kz0 + ky));
				if (vu.ok) {
					s_k = pool[vu.addr] & 0xFFFFu;
					m_k = pool[vu.addr + 1] & 255u;
				}
			}
			if (ky == y + 1) {
				s_up = s_k;
				m_up = m_k;
			}
			if (ky > y && s_k < quarter) {
				break;
			}
			th += float(s_k) / ONE;
		}
		uint m = mt_[y];
		float reach = 0.5 * mix(mt.free_dry[m], mt.free_sat[m], sat) * min(th, 1.0);
		// The support disc in the layer under: the nearest support, then one across from it (more than a right
		// angle away). Distances are between voxel centres, theta scaled by the cell's width at the roof's
		// underside.
		float w = pc.dtheta * (pc.R - float(k));
		int n = int(ceil(reach));
		float best = 1.0e9;
		vec2 dir = vec2(0.0);
		for (int dz = -n; dz <= n; dz++) {
			for (int dx = -n; dx <= n; dx++) {
				vec2 o = vec2(float(dx) * w, float(dz));
				float dd = length(o);
				if (dd <= reach && dd < best && support(ivec3(cxz + ivec2(dx, dz), k - 1))) {
					best = dd;
					dir = o;
				}
			}
		}
		bool holds = best <= 0.5 * reach;  // VoxelBox.span_fails
		for (int dz = -n; dz <= n && !holds && best <= reach; dz++) {
			for (int dx = -n; dx <= n && !holds; dx++) {
				vec2 o = vec2(float(dx) * w, float(dz));
				holds = length(o) <= reach && dot(o, dir) < 0.0 && support(ivec3(cxz + ivec2(dx, dz), k - 1));
			}
		}
		if (holds) {
			continue;
		}
		// The failure, as the slope stability's: slump_rate of the solid a step (the whole of it once that is
		// under move_eps, so a failing roof keeps its brick active to the end), leaving as `out`'s high half and
		// arriving as loose times the swell in this voxel's room (half of it at most; a quarter when a roof voxel
		// over this one may fail into it too) and the room of the air voxel under it (a quarter at most), so
		// cut · swell ≤ (room + cut) / share + room_dn / 4; less fails when less fits.
		uint cut = uint(roundh(pc.slump_rate * float(fs[y])));
		if (float(cut) <= pc.move_eps * ONE) {
			cut = fs[y];
		}
		V vd = find(ivec3(cxz, k - 1));
		int ai = my_ai;
		int room = int(ONE) - int(fs[y]) - int(fl[y]);
		int room_dn = 0;
		if (y > 0) {
			room_dn = int(ONE) - int(fs[y - 1]) - int(fl[y - 1]);
		} else if (open(vd, ai)) {
			uint w0 = pool[vd.addr];
			room_dn = int(ONE) - int(w0 & 0xFFFFu) - int(w0 >> 16);
		}
		room_dn = int(float(room_dn) * vol(k - 1) / vol(k));
		int share = fs[y] < quarter && s_up > 0u && m_up < 2u ? UP_SHARE : FAIL_SHARE;
		float swell = mt.swell[m];
		cut = min(cut, uint(floor((float(room) + float(share) * 0.25 * float(room_dn)) / (float(share) * swell - 1.0))));
		if (cut == 0u) {
			continue;
		}
		uint gain = uint(roundh(float(cut) * swell));
		uint dn = min(gain - min(gain, uint((room + int(cut)) / share)), uint(room_dn / UP_SHARE));
		uint here = gain - dn;
		if (dn > 0u) {
			send(vd, ai, k, k - 1, dn);
		}
		flux[fi] |= cut << 16;
		if (here > 0u) {
			atomicAdd(flux[fi + 1], here);
		}
	}
}

void apply_column(ivec2 cxz, int kz0, int my_e, int my_ai) {
	if (!find(ivec3(cxz, kz0)).ok) {
		return;
	}
	bool moved = false;
	bool changed = false;
	int col = -1;
	for (int y = 0; y < 16; y++) {
		int k = kz0 + y;
		V v = find(ivec3(cxz, k));
		col = v.col;
		int fi = (my_ai * VOXELS_PER_BRICK + v.vi) * 2;
		uint o = flux[fi];
		uint arr = flux[fi + 1];
		if (o == 0u && arr == 0u) {
			continue;
		}
		flux[fi] = 0u;
		flux[fi + 1] = 0u;
		uint w0 = pool[v.addr];
		uint fs = w0 & 0xFFFFu;
		uint fl = w0 >> 16;
		uint fs2 = fs - min(o >> 16, fs);
		uint want = fl - min(o & 0xFFFFu, fl) + arr;
		if (want > uint(ONE) - fs2) {
			// Arrivals past the room (the shares leave none): counted at SLOTS + 2 so a driver sees a leak.
			atomicAdd(box_stats[SLOTS + 2], want - (uint(ONE) - fs2));
		}
		uint fl2 = min(want, uint(ONE) - fs2);
		if (fs2 == fs && fl2 == fl) {
			continue;
		}
		pool[v.addr] = fs2 | (fl2 << 16);
		if (arr > 0u) {
			pool[v.addr + 1] &= ~0xFF00u;
		}
		changed = true;
		float dl = abs(float(fl2) - float(fl)) + abs(float(fs2) - float(fs));
		if (dl > pc.move_eps * ONE) {
			moved = true;
			ivec2 lxz = cxz - pc.brick.xy * 16;
			if (lxz.x == 0) {
				V n = find(ivec3(cxz.x - 1, cxz.y, k));
				if (n.e >= 0) atomicOr(box_stats[n.e], 2u);
			}
			if (lxz.x == 15) {
				V n = find(ivec3(cxz.x + 1, cxz.y, k));
				if (n.e >= 0) atomicOr(box_stats[n.e], 2u);
			}
			if (lxz.y == 0) {
				V n = find(ivec3(cxz.x, cxz.y - 1, k));
				if (n.e >= 0) atomicOr(box_stats[n.e], 2u);
			}
			if (lxz.y == 15) {
				V n = find(ivec3(cxz.x, cxz.y + 1, k));
				if (n.e >= 0) atomicOr(box_stats[n.e], 2u);
			}
			if (y == 0) {
				V n = find(ivec3(cxz, k - 1));
				if (n.e >= 0) atomicOr(box_stats[n.e], 2u);
			}
			if (y == 15) {
				V n = find(ivec3(cxz, k + 1));
				if (n.e >= 0) atomicOr(box_stats[n.e], 2u);
			}
		}
	}
	if (changed && col >= 0) {
		dirty[col] = 1u;
	}
	if (moved) {
		atomicOr(box_stats[my_e], 1u);
	}
}

void main() {
	ivec2 l = ivec2(gl_LocalInvocationID.xy);
	ivec2 cxz = pc.brick.xy * 16 + l;
	int kz0 = pc.brick.z * 16;
	int my_e = slot_index(ivec3(wrap(pc.brick.x, 16), wrap(pc.brick.y, 16), wrap(pc.brick.z, BRICKS_UP)));
	if (index[my_e] < 0) {
		return;
	}
	if (pc.mode == 0) {
		flux_column(cxz, kz0, my_e, pc.active_i);
		if (find(ivec3(cxz, kz0)).ok) {
			span_column(cxz, kz0, pc.active_i);
		}
	} else {
		apply_column(cxz, kz0, my_e, pc.active_i);
	}
}
// (A change to box_column.glslh does not reimport this file: edit it to pick the include up.)
