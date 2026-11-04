#[compute]
#version 450

// Surface nets over a touched chunk of the voxel box (VoxelBox.remesh_dirty; the tunnels design's drawing
// and colliding), two dispatches over the chunk's 16 x 16 columns with a skirt of cells each way (the mesh
// overlaps the tile mesh, which steps back from the chunk and sinks under it) and the box's 64 m:
// 0 vertices: one invocation per dual cell (the cube between eight voxel centres): where the density (the
//   solid plus loose fraction) crosses the half along any of the cube's twelve edges, a vertex at the mean
//   of the crossings, bent into station space (Cyl.position), its normal from the density gradient (a cell
//   spans (R - h) dtheta across), its material the densest corner's (loose counts as dirt) with that
//   corner's loose share; the vertex's index into vmap (-1 for none).
// 1 quads: one invocation per voxel centre and axis: an edge to the next centre that crosses the half gets
//   two triangles over the four cells around it, wound clockwise seen from the air (Godot's front face).
// Samples outside the box clamp to its edge, so nothing caps it. Counts: vertices, indices, an overflow
// flag when a buffer filled (the chunk is left short).

layout(local_size_x = 8, local_size_y = 8, local_size_z = 4) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer Pool { uint pool[]; };
layout(set = 0, binding = 1, std430) restrict readonly buffer Index { int index[]; };
// Two vec4 per vertex: position.xyz and the material id; normal.xyz and the loose share.
layout(set = 0, binding = 2, std430) restrict writeonly buffer Verts { vec4 verts[]; };
layout(set = 0, binding = 3, std430) restrict writeonly buffer Inds { uint inds[]; };
layout(set = 0, binding = 4, std430) restrict buffer VMap { int vmap[]; };
layout(set = 0, binding = 5, std430) restrict buffer Counts { uint n_verts; uint n_inds; uint overflow; uint pad; };

layout(push_constant, std430) uniform Params {
	ivec3 origin;      // the box origin in bricks
	int mode;          // 0 vertices, 1 quads
	ivec2 c0;          // the chunk's first cell (theta index unwrapped in the origin's frame, z index)
	int n_theta;
	int around;
	float R;
	float dtheta;
	float z0;          // station-local z of row 0
	int max_verts;
	int max_inds;
	float pad0, pad1, pad2;
} pc;  // 64 bytes

const float ONE = 65535.0;
// Dual cells from CELL0 cells before the chunk, CELLS per axis; edges from EDGE0, EDGES per axis: the
// quads reach two cells past the chunk, over the tile's sunk ring.
const int CELL0 = -3;
const int CELLS = 21;
const int EDGE0 = -2;
const int EDGES = 20;
const int BRICKS_UP = 6;  // VoxelBox.BRICKS_UP
const int K = 16 * BRICKS_UP;

struct S {
	float d;      // the density less the half: solid where positive
	uint mat;
	float loose;  // the loose share of what fills the voxel
};

// The voxel at ck (theta index unwrapped in the origin's frame, z index, height index), clamped into the
// box: its edge continues outward.
S sample_at(ivec3 ck) {
	ivec3 lo = pc.origin * 16;
	ck = clamp(ck, lo, lo + ivec3(255, 255, K - 1));
	ivec3 b = ck >> 4;
	int e = (((b.z % BRICKS_UP + BRICKS_UP) % BRICKS_UP) * 16 + (b.y & 15)) * 16 + (b.x & 15);
	S r;
	r.d = -0.5;
	r.mat = 0u;
	r.loose = 0.0;
	int bi = index[e];
	if (bi < 0) {
		return r;
	}
	ivec3 v = ck & 15;
	int a = bi * 4096 * 2 + ((v.z * 16 + v.y) * 16 + v.x) * 2;
	uint w0 = pool[a];
	float fs = float(w0 & 0xFFFFu);
	float fl = float(w0 >> 16);
	r.d = (fs + fl) / ONE - 0.5;
	r.mat = fl > fs ? 0u : (pool[a + 1] & 255u);
	r.loose = fl / max(fs + fl, 1.0);
	return r;
}

// The vmap index of the dual cell whose corner 0 is the voxel `cell`, -1 outside the map.
int map_index(ivec3 cell) {
	ivec3 m = cell - ivec3(pc.c0 + CELL0, pc.origin.z * 16);
	if (any(lessThan(m, ivec3(0))) || m.x >= CELLS || m.y >= CELLS || m.z >= K) {
		return -1;
	}
	return (m.z * CELLS + m.y) * CELLS + m.x;
}

vec3 corner(int c) {
	return vec3(c & 1, (c >> 1) & 1, (c >> 2) & 1);
}

void vertex_pass(ivec3 l) {
	if (l.x >= CELLS || l.y >= CELLS || l.z >= K) {
		return;
	}
	ivec3 cell = ivec3(pc.c0 + CELL0, pc.origin.z * 16) + l;
	int mi = (l.z * CELLS + l.y) * CELLS + l.x;
	S s[8];
	for (int c = 0; c < 8; c++) {
		s[c] = sample_at(cell + ivec3(corner(c)));
	}
	vec3 sum = vec3(0.0);
	int n = 0;
	for (int c = 0; c < 8; c++) {
		for (int a = 0; a < 3; a++) {
			int bit = 1 << a;
			if ((c & bit) != 0) {
				continue;
			}
			int d = c | bit;
			if ((s[c].d < 0.0) == (s[d].d < 0.0)) {
				continue;
			}
			float t = s[c].d / (s[c].d - s[d].d);
			sum += mix(corner(c), corner(d), t);
			n++;
		}
	}
	if (n == 0) {
		vmap[mi] = -1;
		return;
	}
	uint vi = atomicAdd(n_verts, 1u);
	if (vi >= uint(pc.max_verts)) {
		atomicOr(overflow, 1u);
		vmap[mi] = -1;
		return;
	}
	vmap[mi] = int(vi);
	// Voxel centres lie half a cell past their indices.
	vec3 p = vec3(cell) + 0.5 + sum / float(n);
	vec3 g = vec3(0.0);
	int best = 0;
	for (int c = 0; c < 8; c++) {
		g += s[c].d * (2.0 * corner(c) - 1.0);
		best = s[c].d > s[best].d ? c : best;
	}
	float th = p.x * pc.dtheta;
	float r = pc.R - p.z;
	// The gradient per metre (a cell spans r dtheta across); the normal points from the solid into the air.
	vec3 n3 = -normalize(vec3(g.x / (r * pc.dtheta), g.y, g.z) + vec3(1e-9));
	// Station space (Cyl.position): spinward (cos th, sin th, 0), toward the axis (-sin th, cos th, 0), axial z.
	vec3 pos = vec3(r * sin(th), -r * cos(th), pc.z0 + p.y);
	vec3 nrm = n3.x * vec3(cos(th), sin(th), 0.0) + n3.z * vec3(-sin(th), cos(th), 0.0) + vec3(0.0, 0.0, n3.y);
	verts[2u * vi] = vec4(pos, float(s[best].mat));
	verts[2u * vi + 1u] = vec4(nrm, s[best].loose);
}

void quad_pass(ivec3 l) {
	if (l.x >= EDGES || l.y >= EDGES || l.z >= K) {
		return;
	}
	ivec3 base = ivec3(pc.c0 + EDGE0, pc.origin.z * 16) + l;
	S s0 = sample_at(base);
	for (int a = 0; a < 3; a++) {
		ivec3 ea = ivec3(a == 0, a == 1, a == 2);
		ivec3 eb = ivec3(a == 2, a == 0, a == 1);  // the next axis round
		ivec3 ec = ivec3(a == 1, a == 2, a == 0);  // and the one after
		S s1 = sample_at(base + ea);
		if ((s0.d < 0.0) == (s1.d < 0.0)) {
			continue;
		}
		// The four dual cells around the edge, a ring about +a.
		ivec3 cs[4] = ivec3[4](base, base - eb, base - eb - ec, base - ec);
		int v[4];
		bool ok = true;
		for (int q = 0; q < 4; q++) {
			int mi = map_index(cs[q]);
			v[q] = mi < 0 ? -1 : vmap[mi];
			ok = ok && v[q] >= 0;
		}
		if (!ok) {
			continue;
		}
		uint ii = atomicAdd(n_inds, 6u);
		if (ii + 6u > uint(pc.max_inds)) {
			atomicOr(overflow, 1u);
			continue;
		}
		// The ring runs counter-clockwise seen from +a in the grid frame, which is left-handed in station
		// space (spinward x axial = -up): clockwise there, Godot's front face, when the air lies at +a.
		int o[6];
		if (s1.d < 0.0) {
			o = int[6](0, 1, 2, 0, 2, 3);
		} else {
			o = int[6](0, 3, 2, 0, 2, 1);
		}
		for (int q = 0; q < 6; q++) {
			inds[ii + uint(q)] = uint(v[o[q]]);
		}
	}
}

void main() {
	ivec3 l = ivec3(gl_GlobalInvocationID);
	if (pc.mode == 0) {
		vertex_pass(l);
	} else {
		quad_pass(l);
	}
}
