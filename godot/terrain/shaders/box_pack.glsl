#[compute]
#version 450

// The voxel box's exit side (VoxelBox.pack_dirty): one invocation per box column; a column flagged dirty is
// packed back into its window fields by VoxelColumn.pack's rule (box_column.glslh): the runs of its K voxels
// (a full voxel over its whole height; a partial flagged hanging, or under solid with air under it, from
// its ceiling, any other on its floor; pillar voxels runs of their own), merged with the stored runs and
// pillars outside the box's range, the loose on each run converted back to m over the run's top; the top
// run's top to surface, its loose and compaction, the gaps under it (a pillar run becomes a gap of the pillar's
// material, which the unpack refills, and any other air beside it an air gap; at most four:
// beyond that the lowest two air gaps in a row merge, the sliver between turned to loose on the merged gap's
// floor by its swell, counted in box_stats[SLOTS]), the material by the strata at the surface, the clay
// clamped to it, edit_mask set, the tile's activity flagged in the edit layer's stats (so the settle pack saves it); the dirty flag
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
	vec4 swell;  // the materials' swell factor, to 96 bytes
} pc;

#include "box_column.glslh"

// The runs found so far, bottom-up: bottom, top, loose volume per unit dtheta (m²), compaction, pillar. At
// most RUNS; a ninth drops the lowest dirt run over run 0 (the gaps either side of it merge).
const int RUNS = 8;
float pb[RUNS];
float pt[RUNS];
float pl[RUNS];
int pcm[RUNS];
bool pp[RUNS];
int np = 0;
bool over = false;

// The gaps, bottom-up: bottom, top, loose volume per unit dtheta (m²) on the floor, material. A pillar run
// gives at most an air gap under it and its own.
const int GAPS = 2 * RUNS;
float hb[GAPS];
float ht[GAPS];
float hl[GAPS];
int hm[GAPS];
int ng = 0;

Col col;  // the column being packed (read in main)

void drop_run() {
	// The solid of the lowest dirt run over run 0 becomes loose on the run under it by its material's swell:
	// nothing is lost (VoxelColumn.pack merges the same two gaps at the end). ponytail: beside a pillar run this
	// merges an air gap with a pillar's, where the CPU merges the next air gaps in a row; only a column of nine
	// runs gets here, and one of nothing but pillars over run 0 turns one to loose.
	int j = 1;
	while (j < np - 2 && pp[j]) {
		j++;
	}
	float mid = 0.5 * (pb[j] + pt[j]);
	pl[j - 1] += pl[j] + (pt[j] - pb[j]) * (pc.R - mid) * pc.swell[material_at(mid, col)];
	for (int i = j; i < np - 1; i++) {
		pb[i] = pb[i + 1];
		pt[i] = pt[i + 1];
		pl[i] = pl[i + 1];
		pcm[i] = pcm[i + 1];
		pp[i] = pp[i + 1];
	}
	np--;
	over = true;
}

// A solid piece [b, t]: merged onto the last run when it touches it and is of its kind (taking the piece's
// loose and compaction: a stored run's, when its top is past the range), else a new run.
void push(float b, float t, float l, int c, bool p) {
	if (np > 0 && pt[np - 1] == b && pp[np - 1] == p) {
		pt[np - 1] = t;
		pl[np - 1] = l;
		pcm[np - 1] = c;
		return;
	}
	if (np == RUNS) {
		drop_run();
	}
	pb[np] = b;
	pt[np] = t;
	pl[np] = l;
	pcm[np] = c;
	pp[np] = p;
	np++;
}

// The part of the stored pillar gap topping at `top` (a stored run's bottom) within [lo, hi], as a pillar
// piece (VoxelColumn._pillar_piece).
void push_pillar(float top, float lo, float hi) {
	for (int g = 0; g < 4; g++) {
		float b = max(col.gb[g], lo);
		if (col.gm[g] == PILLAR && col.gt[g] == top && b < min(top, hi)) {
			push(b, min(top, hi), 0.0, 0, true);
		}
	}
}

// Whether the air from a run's top a up to a pillar's bottom b is what the unpack refills under the pillar: no
// whole voxel of it, or every voxel from a's up holding loose, full but the last (VoxelColumn._refills).
bool refills(float a, float b, int k0) {
	if (ceil(a) >= b) {
		return true;
	}
	for (int k = int(floor(a)); k < int(b); k++) {
		int i = k - k0;
		if (i < 0 || i >= K || loo[i] == 0u || (k + 1 < int(b) && sol[i] + loo[i] < uint(ONE))) {
			return false;
		}
	}
	return true;
}

// A gap [b, t] onto the list, v its loose volume, m its material.
void gap(float b, float t, float v, int m) {
	hb[ng] = b;
	ht[ng] = t;
	hl[ng] = v;
	hm[ng] = m;
	ng++;
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
	for (int L = 0; L < BRICKS_UP; L++) {
		int bidx = index[slot_index(ivec3(s.x / 16, s.y / 16, wrap(pc.origin.z + L, BRICKS_UP)))];
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
			mat[i] = w1 & 255u;
			cmp[i] = (w1 >> 8) & 255u;
			flg[i] = (w1 >> 24) & 1u;
		}
	}
	col = read_col(t);
	Runs st = runs_of(col);
	float fk0 = float(k0);
	float topk = float(k0 + K);
	for (int j = st.n - 1; j >= 0; j--) {
		push_pillar(st.b[j], BELOW, fk0);
		if (st.b[j] < fk0) {
			push(st.b[j], min(st.t[j], fk0), st.t[j] < fk0 ? st.l[j] * (pc.R - st.t[j]) : 0.0, st.c[j], false);
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
			push(h, h + 1.0, 0.0, 0, mat[i] == uint(PILLAR));
		} else if (flg[i] == 0u && ((i > 0 && sol[i - 1] > 0u) || (i == 0 && solid_under))) {
			push(h, h + ff, 0.0, 0, false);
		} else if (flg[i] != 0u || (i + 1 < K && sol[i + 1] > 0u) || (i + 1 == K && solid_at(st, topk))) {
			push(h + 1.0 - ff, h + 1.0, 0.0, 0, false);
		} else {
			push(h, h + ff, 0.0, 0, false);
		}
	}
	for (int j = st.n - 1; j >= 0; j--) {
		push_pillar(st.b[j], topk, -BELOW);
		if (st.t[j] > topk) {
			push(max(st.b[j], topk), st.t[j], st.l[j] * (pc.R - st.t[j]), st.c[j], false);
		}
	}
	// ponytail: a pillar with no ground over it has no place in the column form: it goes (VoxelColumn.pack).
	while (pp[np - 1]) {
		np--;
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
	for (int i = 1; i < np; i++) {
		if (pp[i] && refills(pt[i - 1], pb[i], k0)) {
			gap(pt[i - 1], pt[i], pl[i - 1], PILLAR);
		} else if (pp[i]) {
			gap(pt[i - 1], pb[i], pl[i - 1], 0);
			gap(pb[i], pt[i], 0.0, PILLAR);
		} else if (pp[i - 1] && pl[i - 1] == 0.0 && floor(pb[i]) <= pt[i - 1]) {
			ht[ng - 1] = pb[i];
		} else {
			gap(pt[i - 1], pb[i], pl[i - 1], 0);
		}
	}
	while (ng > 4) {
		over = true;
		// The lowest two air gaps in a row merge (a pillar's never does), the solid between them loose on the
		// merged gap's floor by its material's swell: nothing is lost (VoxelColumn.pack).
		int j = 0;
		while (j < ng - 1 && (hm[j] == PILLAR || hm[j + 1] == PILLAR)) {
			j++;
		}
		if (j == ng - 1) {
			// ponytail: no two air gaps in a row (pillars standing alone): the lowest pillar's gap becomes air,
			// joined with the air gaps resting on it and under it, their loose summed: nothing is gained or lost
			// (VoxelColumn.pack).
			int q = 0;
			while (hm[q] != PILLAR) {
				q++;
			}
			int lo = q > 0 && hm[q - 1] == 0 && ht[q - 1] == hb[q] ? q - 1 : q;
			int hi = q + 1 < ng && hm[q + 1] == 0 && hb[q + 1] == ht[q] ? q + 1 : q;
			for (int i = lo + 1; i <= hi; i++) {
				hl[lo] += hl[i];
			}
			ht[lo] = ht[hi];
			hm[lo] = 0;
			for (int i = lo + 1; i + hi - lo < ng; i++) {
				hb[i] = hb[i + hi - lo];
				ht[i] = ht[i + hi - lo];
				hl[i] = hl[i + hi - lo];
				hm[i] = hm[i + hi - lo];
			}
			ng -= hi - lo;
			continue;
		}
		float mid = 0.5 * (ht[j] + hb[j + 1]);
		hl[j] += hl[j + 1] + (hb[j + 1] - ht[j]) * (pc.R - mid) * pc.swell[material_at(mid, col)];
		ht[j] = ht[j + 1];
		for (int i = j + 1; i < ng - 1; i++) {
			hb[i] = hb[i + 1];
			ht[i] = ht[i + 1];
			hl[i] = hl[i + 1];
			hm[i] = hm[i + 1];
		}
		ng--;
	}
	float surf = pt[np - 1];
	imageStore(w_surface, t, vec4(surf));
	imageStore(w_loose, t, vec4(pl[np - 1] / (pc.R - surf)));
	imageStore(w_compaction, t, vec4(float(pcm[np - 1]) / 255.0));
	vec4 gb = vec4(0.0), gt = vec4(0.0), gl = vec4(0.0), gm = vec4(0.0);
	for (int g = 0; g < 4; g++) {
		int idx = ng - 1 - g;
		if (idx >= 0) {
			gb[g] = hb[idx];
			gt[g] = ht[idx];
			gl[g] = hl[idx] / (pc.R - hb[idx]);
			gm[g] = float(hm[idx]) / 255.0;
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
	imageStore(w_gap_material0, t, vec4(gm.x));
	imageStore(w_gap_material1, t, vec4(gm.y));
	imageStore(w_gap_material2, t, vec4(gm.z));
	imageStore(w_gap_material3, t, vec4(gm.w));
	float cb = min(col.cb, surf);
	float ct = min(col.ct, surf);
	imageStore(w_clay_bottom, t, vec4(cb));
	imageStore(w_clay_top, t, vec4(ct));
	float material = col.bt >= surf - 0.01 ? 2.0 : (ct >= surf - 0.01 ? 1.0 : 0.0);
	imageStore(w_material, t, vec4(material / 255.0));
	imageStore(w_mask, t, vec4(1.0));
	// The chunk's word: packed, and touched when a gap lies within the box's range.
	uint cw = 1u;
	for (int i = 0; i < ng; i++) {
		if (hb[i] < topk && ht[i] > fk0) {
			cw |= 2u;
		}
	}
	atomicOr(box_stats[chunk_word(c)], cw);
	// The chunks whose skirts reach this column (three cells over their borders, box_mesh.glsl) remesh with it.
	for (int dy = -3; dy <= 3; dy += 3) {
		for (int dx = -3; dx <= 3; dx += 3) {
			int w = chunk_word(ivec2(wrap(c.x + dx, pc.n_theta), c.y + dy));
			if (w != chunk_word(c)) {
				atomicOr(box_stats[w], 1u);
			}
		}
	}
	flag(t);
	if (over) {
		atomicAdd(box_stats[SLOTS], 1u);
	}
}
// (A change to box_column.glslh does not reimport this file: touch it to pick the include up.)
