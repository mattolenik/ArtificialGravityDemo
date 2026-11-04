#[compute]
#version 450

// The voxel box's entry side (VoxelBox, the tunnels design): the box of 16 x 16 x 4 bricks of 16³ voxels
// around the player, sparse: a brick slot holds a pool brick only where a column has something in its 16 m.
// Modes (pc.mode), one invocation each per slot or per box column, barriers between (VoxelBox._move_rd):
// 0 free: a slot whose brick (under the old origin) lies outside the new box gives its brick back to the
//   free stack and goes unallocated.
// 1 mark: a column new to the box (or its layers new to it) flags the slots its content needs.
// 2 allocate: a flagged, unallocated slot pops a brick from the free stack and clears it; the flag is cleared.
// 3 fill: a new column writes its voxels (VoxelColumn.unpack's rule, box_column.glslh) into its allocated
//   slots; an unallocated slot was air. A column off the station or not resident writes air.
// With count > 0, modes 1 and 3 run over the cells listed instead (a reload after a window-side stamp: the
// whole column again, its dirty flag dropped since the window is the truth).
// A voxel is two uints at ((y * 16 + z) * 16 + x) * 2 of its brick: solid | loose << 16 (fractions of
// 65535), material | compaction << 8 | saturation << 16 | flags << 24 (bit 0: the solid hangs from the
// ceiling, box_column.glslh).

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict buffer Pool { uint pool[]; };
layout(set = 0, binding = 1, std430) restrict buffer Index { int index[]; };
layout(set = 0, binding = 2, std430) restrict buffer Dirty { uint dirty[]; };
layout(set = 0, binding = 3, std430) restrict buffer BoxStats { uint box_stats[]; };
layout(set = 0, binding = 4, std430) restrict buffer Stats { uint stats[]; };
layout(set = 0, binding = 5, std430) restrict buffer Free { int free_top; int free_list[]; };
layout(set = 0, binding = 6, std430) restrict buffer Needed { uint needed[]; };
layout(set = 0, binding = 7, std430) restrict readonly buffer Cells { ivec2 cells[]; };
layout(set = 0, binding = 8, r32f) uniform restrict readonly image2D w_surface;
layout(set = 0, binding = 9, r32f) uniform restrict readonly image2D w_bedrock;
layout(set = 0, binding = 10, r32f) uniform restrict readonly image2D w_clay_bottom;
layout(set = 0, binding = 11, r32f) uniform restrict readonly image2D w_clay_top;
layout(set = 0, binding = 12, r32f) uniform restrict readonly image2D w_water;
layout(set = 0, binding = 13, r8) uniform restrict readonly image2D w_material;
layout(set = 0, binding = 14, r8) uniform restrict readonly image2D w_compaction;
layout(set = 0, binding = 15, r8) uniform restrict readonly image2D w_saturation;
layout(set = 0, binding = 16, r8) uniform restrict readonly image2D w_mask;
layout(set = 0, binding = 17, r32f) uniform restrict readonly image2D w_loose;
layout(set = 0, binding = 18, r32f) uniform restrict readonly image2D w_depth;
layout(set = 0, binding = 19, r32f) uniform restrict readonly image2D w_gap_bottom0;
layout(set = 0, binding = 20, r32f) uniform restrict readonly image2D w_gap_bottom1;
layout(set = 0, binding = 21, r32f) uniform restrict readonly image2D w_gap_bottom2;
layout(set = 0, binding = 22, r32f) uniform restrict readonly image2D w_gap_bottom3;
layout(set = 0, binding = 23, r32f) uniform restrict readonly image2D w_gap_top0;
layout(set = 0, binding = 24, r32f) uniform restrict readonly image2D w_gap_top1;
layout(set = 0, binding = 25, r32f) uniform restrict readonly image2D w_gap_top2;
layout(set = 0, binding = 26, r32f) uniform restrict readonly image2D w_gap_top3;
layout(set = 0, binding = 27, r32f) uniform restrict readonly image2D w_gap_loose0;
layout(set = 0, binding = 28, r32f) uniform restrict readonly image2D w_gap_loose1;
layout(set = 0, binding = 29, r32f) uniform restrict readonly image2D w_gap_loose2;
layout(set = 0, binding = 30, r32f) uniform restrict readonly image2D w_gap_loose3;
layout(set = 0, binding = 31, r8) uniform restrict readonly image2D w_gap_material0;
layout(set = 0, binding = 32, r8) uniform restrict readonly image2D w_gap_material1;
layout(set = 0, binding = 33, r8) uniform restrict readonly image2D w_gap_material2;
layout(set = 0, binding = 34, r8) uniform restrict readonly image2D w_gap_material3;

layout(push_constant, std430) uniform Params {
	ivec3 origin;      // the box origin in bricks (theta brick, z brick, height brick)
	int mode;
	ivec3 old;         // the origin before this move (far away when the box is new)
	int count;         // cells listed, 0 for the whole box
	ivec2 first_tile;  // first tile of the window's wanted set (theta wrapped, z)
	int n_theta;       // 1 m cells around
	int slots;         // window tiles per axis
	int n_z;           // 1 m cells along
	int around;        // bricks around
	float R;           // hull radius in m
	float dtheta;      // rad per cell around
	float h_max;
	float pad0, pad1, pad2;  // to 80 bytes
} pc;

#include "box_column.glslh"

void main() {
	int gid = int(gl_GlobalInvocationID.x);
	if (pc.mode == 0) {
		if (gid >= SLOTS) {
			return;
		}
		int bidx = index[gid];
		if (bidx < 0) {
			return;
		}
		ivec3 s = ivec3(gid % 16, (gid / 16) % 16, gid / 256);
		ivec3 b = pc.old + ivec3(wrap(s.x - pc.old.x, 16), wrap(s.y - pc.old.y, 16), wrap(s.z - pc.old.z, 4));
		bool inside = wrap(b.x - pc.origin.x, pc.around) < 16 && b.y >= pc.origin.y && b.y < pc.origin.y + 16
				&& b.z >= pc.origin.z && b.z < pc.origin.z + 4;
		if (inside) {
			return;
		}
		int top = atomicAdd(free_top, 1);
		free_list[top] = bidx;
		index[gid] = -1;
		return;
	}
	if (pc.mode == 2) {
		if (gid >= SLOTS) {
			return;
		}
		if (needed[gid] != 0u && index[gid] < 0) {
			int top = atomicAdd(free_top, -1);
			if (top > 0) {
				int b = free_list[top - 1];
				index[gid] = b;
				for (int i = 0; i < VOXELS_PER_BRICK * 2; i++) {
					pool[b * VOXELS_PER_BRICK * 2 + i] = 0u;
				}
			} else {
				atomicAdd(free_top, 1);
				atomicAdd(box_stats[SLOTS + 1], 1u);  // the pool ran dry (never for the ground: 1024 slots, 1536 bricks)
			}
		}
		needed[gid] = 0u;
		return;
	}
	ivec2 s;
	int mask;
	if (pc.count > 0) {
		if (gid >= pc.count) {
			return;
		}
		bool inbox;
		s = slot_of_cell(cells[gid], pc.origin, inbox);
		if (!inbox) {
			return;
		}
		mask = 15;
	} else {
		if (gid >= COLUMNS * COLUMNS) {
			return;
		}
		s = ivec2(gid % COLUMNS, gid / COLUMNS);
		ivec2 b = pc.origin.xy + ivec2(wrap(s.x / 16 - pc.origin.x, 16), wrap(s.y / 16 - pc.origin.y, 16));
		bool was = wrap(b.x - pc.old.x, pc.around) < 16 && b.y >= pc.old.y && b.y < pc.old.y + 16;
		mask = 0;
		for (int L = 0; L < 4; L++) {
			int bk = pc.origin.z + L;
			if (!was || bk < pc.old.z || bk >= pc.old.z + 4) {
				mask |= 1 << L;
			}
		}
		if (mask == 0) {
			return;
		}
	}
	bool ok;
	ivec2 c = cell_of_slot(s, pc.origin, ok);
	ivec2 t;
	int k0 = pc.origin.z * 16;
	uint sat = 0u;
	if (ok && texel(c, t)) {
		Col col = read_col(t);
		sat = uint(col.sat);
		column_voxels(col, k0);
	} else {
		clear_column();
	}
	if (pc.mode == 3 && pc.count > 0) {
		dirty[s.y * COLUMNS + s.x] = 0u;
	}
	ivec2 within = s % 16;
	for (int L = 0; L < 4; L++) {
		if ((mask & (1 << L)) == 0) {
			continue;
		}
		int e = slot_index(ivec3(s.x / 16, s.y / 16, wrap(pc.origin.z + L, 4)));
		if (pc.mode == 1) {
			bool any = false;
			for (int y = 0; y < 16; y++) {
				any = any || sol[L * 16 + y] != 0u || loo[L * 16 + y] != 0u;
			}
			if (any) {
				atomicOr(needed[e], 1u);
			}
			continue;
		}
		int bidx = index[e];
		if (bidx < 0) {
			continue;
		}
		int base = bidx * VOXELS_PER_BRICK * 2;
		bool any_loose = false;
		for (int y = 0; y < 16; y++) {
			int i = L * 16 + y;
			int v = base + ((y * 16 + within.y) * 16 + within.x) * 2;
			pool[v] = sol[i] | (loo[i] << 16);
			pool[v + 1] = mat[i] | (cmp[i] << 8) | (sat << 16) | (flg[i] << 24);
			any_loose = any_loose || loo[i] != 0u;
		}
		// Loose that enters the box goes active, so a pile mid-slump resumes (the sand settles it).
		if (any_loose) {
			atomicOr(box_stats[e], 1u);
		}
	}
}
