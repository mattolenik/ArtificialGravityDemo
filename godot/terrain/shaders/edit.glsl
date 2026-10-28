#[compute]
#version 450

// The edit layer (EditLayer, decisions 1 to 4 of the terrain edits plan), in three modes:
// 0 stamp: a disc of `radius` cells around `cell` raised or lowered by dh with a parabolic falloff, in the
//   live window; strata are cut by min on the way down and dirt is added on the way up; edit_mask set;
//   loose and water_depth left as they are.
// 1 pack: tile `tile` of the window copied into slot `slot` of `down`, one blob per tile; unedited cells zero.
// 2 apply: the blob in `up` copied over tile `tile` where its mask is set.
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

layout(push_constant, std430) uniform Params {
	ivec2 cell;        // stamp centre (theta index wrapped, z index)
	ivec2 first_tile;  // first tile of the window's wanted set (theta wrapped, z)
	ivec2 tile;        // the tile packed or applied (theta wrapped, z)
	int n_theta;       // 1 m cells around
	int tiles_around;  // unused: slots divides it
	int slots;         // window tiles per axis
	int mode;          // 0 stamp, 1 pack, 2 apply
	int radius;        // stamp radius in cells
	int slot;          // pack: the slot of `down`
	float dh;          // stamp: m at the centre, negative digs
	float h_max;       // the highest ground, h_sea + h_mtn
	vec2 pad;          // to 64 bytes
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

void main() {
	ivec2 g = ivec2(gl_GlobalInvocationID.xy);
	if (pc.mode == 0) {
		// The disc lies in the box around cell; the residency test drops rows off the station.
		ivec2 d = g - pc.radius;
		float dist = length(vec2(d));
		ivec2 t;
		if (dist > float(pc.radius) || !texel(ivec2(wrap(pc.cell.x + d.x, pc.n_theta), pc.cell.y + d.y), t)) {
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
		// Edited strata are real, so never 3 (the detail pass's rock face).
		float material = bt >= s - 0.01 ? 2.0 : (ct >= s - 0.01 ? 1.0 : 0.0);
		imageStore(w_surface, t, vec4(s));
		imageStore(w_bedrock, t, vec4(bt));
		imageStore(w_clay_bottom, t, vec4(cb));
		imageStore(w_clay_top, t, vec4(ct));
		imageStore(w_material, t, vec4(material / 255.0));
		imageStore(w_mask, t, vec4(1.0));
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
}
