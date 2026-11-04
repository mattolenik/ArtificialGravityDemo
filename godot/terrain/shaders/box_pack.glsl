#[compute]
#version 450

// The voxel box's exit side (VoxelBox.pack_dirty): one invocation per box column; a column flagged dirty is
// packed back into its window fields by VoxelColumn.pack's rule (box_column.glslh): the runs of its 64 voxels
// (a full voxel over its whole height; a partial flagged hanging, or under solid with air under it, from
// its ceiling, any other on its floor), merged with the stored runs outside the box's range, the
// loose on each run converted back to m over the run's top; the top run's top to surface, its loose and
// compaction, the gaps under it (at most four: beyond that the lowest two merge, the sliver between lost,
// counted in box_stats[1024]), the material by the strata at the surface, the clay clamped to it, edit_mask
// set, the tile's activity flagged in the edit layer's stats (so the settle pack saves it); the dirty flag
// cleared. A column the box never changed is never packed, so its heights stay bit for bit.

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict buffer Pool { uint pool[]; };
layout(set = 0, binding = 1, std430) restrict buffer Index { int index[]; };
layout(set = 0, binding = 2, std430) restrict buffer Dirty { uint dirty[]; };
layout(set = 0, binding = 3, std430) restrict buffer BoxStats { uint box_stats[]; };
layout(set = 0, binding = 4, std430) restrict buffer Stats { uint stats[]; };
layout(set = 0, binding = 5, std430) restrict buffer Free { int free_top; int free_list[]; };
layout(set = 0, binding = 6, std430) restrict buffer Needed { uint needed[]; };
layout(set = 0, binding = 7, std430) restrict readonly buffer Cells { ivec2 cells[]; };
layout(set = 0, binding = 8, r32f) uniform restrict image2D w_surface;
layout(set = 0, binding = 9, r32f) uniform restrict image2D w_bedrock;
layout(set = 0, binding = 10, r32f) uniform restrict image2D w_clay_bottom;
layout(set = 0, binding = 11, r32f) uniform restrict image2D w_clay_top;
layout(set = 0, binding = 12, r32f) uniform restrict image2D w_water;
layout(set = 0, binding = 13, r8) uniform restrict image2D w_material;
layout(set = 0, binding = 14, r8) uniform restrict image2D w_compaction;
layout(set = 0, binding = 15, r8) uniform restrict image2D w_saturation;
layout(set = 0, binding = 16, r8) uniform restrict image2D w_mask;
layout(set = 0, binding = 17, r32f) uniform restrict image2D w_loose;
layout(set = 0, binding = 18, r32f) uniform restrict image2D w_depth;
layout(set = 0, binding = 19, r32f) uniform restrict image2D w_gap_bottom0;
layout(set = 0, binding = 20, r32f) uniform restrict image2D w_gap_bottom1;
layout(set = 0, binding = 21, r32f) uniform restrict image2D w_gap_bottom2;
layout(set = 0, binding = 22, r32f) uniform restrict image2D w_gap_bottom3;
layout(set = 0, binding = 23, r32f) uniform restrict image2D w_gap_top0;
layout(set = 0, binding = 24, r32f) uniform restrict image2D w_gap_top1;
layout(set = 0, binding = 25, r32f) uniform restrict image2D w_gap_top2;
layout(set = 0, binding = 26, r32f) uniform restrict image2D w_gap_top3;
layout(set = 0, binding = 27, r32f) uniform restrict image2D w_gap_loose0;
layout(set = 0, binding = 28, r32f) uniform restrict image2D w_gap_loose1;
layout(set = 0, binding = 29, r32f) uniform restrict image2D w_gap_loose2;
layout(set = 0, binding = 30, r32f) uniform restrict image2D w_gap_loose3;
layout(set = 0, binding = 31, r8) uniform restrict image2D w_gap_material0;
layout(set = 0, binding = 32, r8) uniform restrict image2D w_gap_material1;
layout(set = 0, binding = 33, r8) uniform restrict image2D w_gap_material2;
layout(set = 0, binding = 34, r8) uniform restrict image2D w_gap_material3;

layout(push_constant, std430) uniform Params {
	ivec3 origin;
	int mode;
	ivec3 old;
	int count;
	ivec2 first_tile;
	int n_theta;
	int slots;
	int n_z;
	int around;
	float R;
	float dtheta;
	float h_max;
	float pad0, pad1, pad2;
} pc;

#include "box_column.glslh"

// The runs found so far, bottom-up: bottom, top, loose volume per unit dtheta (m²), compaction. At most
// RUNS; a ninth drops run 1 (the lowest gap merges with the one over it).
const int RUNS = 8;
float pb[RUNS];
float pt[RUNS];
float pl[RUNS];
int pcm[RUNS];
int np = 0;
bool over = false;

void drop_run_1() {
	pl[0] += pl[1];
	for (int i = 1; i < np - 1; i++) {
		pb[i] = pb[i + 1];
		pt[i] = pt[i + 1];
		pl[i] = pl[i + 1];
		pcm[i] = pcm[i + 1];
	}
	np--;
	over = true;
}

// A solid piece [b, t]: merged onto the last run when it touches it (taking the piece's loose and
// compaction: a stored run's, when its top is past the range), else a new run.
void push(float b, float t, float l, int c) {
	if (np > 0 && pt[np - 1] == b) {
		pt[np - 1] = t;
		pl[np - 1] = l;
		pcm[np - 1] = c;
		return;
	}
	if (np == RUNS) {
		drop_run_1();
	}
	pb[np] = b;
	pt[np] = t;
	pl[np] = l;
	pcm[np] = c;
	np++;
}

bool solid_at(Runs r, float h) {
	for (int j = 0; j < r.n; j++) {
		if (r.b[j] <= h && r.t[j] > h) {
			return true;
		}
	}
	return false;
}

void flag(ivec2 t) {
	atomicOr(stats[(t.y / TILE) * pc.slots + t.x / TILE], 1u);
}

void main() {
	int gid = int(gl_GlobalInvocationID.x);
	if (gid >= COLUMNS * COLUMNS || dirty[gid] == 0u) {
		return;
	}
	dirty[gid] = 0u;
	ivec2 s = ivec2(gid % COLUMNS, gid / COLUMNS);
	bool ok;
	ivec2 c = cell_of_slot(s, pc.origin, ok);
	ivec2 t;
	if (!ok || !texel(c, t)) {
		return;
	}
	int k0 = pc.origin.z * 16;
	ivec2 within = s % 16;
	for (int L = 0; L < 4; L++) {
		int bidx = index[slot_index(ivec3(s.x / 16, s.y / 16, wrap(pc.origin.z + L, 4)))];
		for (int y = 0; y < 16; y++) {
			int i = L * 16 + y;
			if (bidx < 0) {
				sol[i] = 0u;
				loo[i] = 0u;
				cmp[i] = 0u;
				flg[i] = 0u;
				continue;
			}
			int v = bidx * VOXELS_PER_BRICK * 2 + ((y * 16 + within.y) * 16 + within.x) * 2;
			uint w0 = pool[v];
			uint w1 = pool[v + 1];
			sol[i] = w0 & 0xFFFFu;
			loo[i] = w0 >> 16;
			cmp[i] = (w1 >> 8) & 255u;
			flg[i] = (w1 >> 24) & 1u;
		}
	}
	Col col = read_col(t);
	Runs st = runs_of(col);
	float fk0 = float(k0);
	float topk = float(k0 + K);
	for (int j = st.n - 1; j >= 0; j--) {
		if (st.b[j] < fk0) {
			push(st.b[j], min(st.t[j], fk0), st.t[j] < fk0 ? st.l[j] * (pc.R - st.t[j]) : 0.0, st.c[j]);
		}
	}
	bool solid_under = np > 0 && pt[np - 1] == fk0;
	for (int i = 0; i < K; i++) {
		uint f = sol[i];
		if (f == 0u) {
			continue;
		}
		float h = float(k0 + i);
		float ff = float(f) / ONE;
		if (f == uint(ONE)) {
			push(h, h + 1.0, 0.0, 0);
		} else if (flg[i] == 0u && ((i > 0 && sol[i - 1] > 0u) || (i == 0 && solid_under))) {
			push(h, h + ff, 0.0, 0);
		} else if (flg[i] != 0u || (i + 1 < K && sol[i + 1] > 0u) || (i + 1 == K && solid_at(st, topk))) {
			push(h + 1.0 - ff, h + 1.0, 0.0, 0);
		} else {
			push(h, h + ff, 0.0, 0);
		}
	}
	for (int j = st.n - 1; j >= 0; j--) {
		if (st.t[j] > topk) {
			push(max(st.b[j], topk), st.t[j], st.l[j] * (pc.R - st.t[j]), st.c[j]);
		}
	}
	for (int i = 0; i < K; i++) {
		if (loo[i] == 0u) {
			continue;
		}
		float h = float(k0 + i);
		int r = np - 1;
		while (r >= 0 && (pb[r] > h || pt[r] > h + 1.0)) {
			r--;
		}
		if (r >= 0) {
			pl[r] += float(loo[i]) / ONE * (pc.R - h - 0.5);
			pcm[r] = int(cmp[i]);
		}
	}
	while (np - 1 > 4) {
		drop_run_1();
	}
	float surf = pt[np - 1];
	imageStore(w_surface, t, vec4(surf));
	imageStore(w_loose, t, vec4(pl[np - 1] / (pc.R - surf)));
	imageStore(w_compaction, t, vec4(float(pcm[np - 1]) / 255.0));
	vec4 gb = vec4(0.0), gt = vec4(0.0), gl = vec4(0.0);
	for (int g = 0; g < 4; g++) {
		int idx = np - 2 - g;
		if (idx >= 0) {
			gb[g] = pt[idx];
			gt[g] = pb[idx + 1];
			gl[g] = pl[idx] / (pc.R - pt[idx]);
		}
	}
	imageStore(w_gap_bottom0, t, vec4(gb.x));
	imageStore(w_gap_bottom1, t, vec4(gb.y));
	imageStore(w_gap_bottom2, t, vec4(gb.z));
	imageStore(w_gap_bottom3, t, vec4(gb.w));
	imageStore(w_gap_top0, t, vec4(gt.x));
	imageStore(w_gap_top1, t, vec4(gt.y));
	imageStore(w_gap_top2, t, vec4(gt.z));
	imageStore(w_gap_top3, t, vec4(gt.w));
	imageStore(w_gap_loose0, t, vec4(gl.x));
	imageStore(w_gap_loose1, t, vec4(gl.y));
	imageStore(w_gap_loose2, t, vec4(gl.z));
	imageStore(w_gap_loose3, t, vec4(gl.w));
	imageStore(w_gap_material0, t, vec4(0.0));
	imageStore(w_gap_material1, t, vec4(0.0));
	imageStore(w_gap_material2, t, vec4(0.0));
	imageStore(w_gap_material3, t, vec4(0.0));
	float cb = min(col.cb, surf);
	float ct = min(col.ct, surf);
	imageStore(w_clay_bottom, t, vec4(cb));
	imageStore(w_clay_top, t, vec4(ct));
	float material = col.bt >= surf - 0.01 ? 2.0 : (ct >= surf - 0.01 ? 1.0 : 0.0);
	imageStore(w_material, t, vec4(material / 255.0));
	imageStore(w_mask, t, vec4(1.0));
	flag(t);
	if (over) {
		atomicAdd(box_stats[SLOTS], 1u);
	}
}
