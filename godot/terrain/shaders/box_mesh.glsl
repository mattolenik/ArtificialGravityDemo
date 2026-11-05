#[compute]
#version 450

// Surface nets over a touched chunk of the voxel box (VoxelBox.remesh_dirty; the tunnels design's drawing
// and colliding), two dispatches over the chunk's 16 x 16 columns with a skirt of cells each way (the mesh
// overlaps the tile mesh, which steps back from the chunk and sinks under it; the skirt's edge sinks to meet
// the tile's ramp) and the box's 96 m:
// 0 vertices: one invocation per dual cell (the cube between eight voxel centres): where the density (the
//   signed distance along the column from the voxel's centre to its run's end, sample_at) crosses zero along
//   any of the cube's twelve edges, a vertex at the mean of the crossings (a vertical edge's by the
//   distances toward each other, a lateral edge's by the fill less a half: a wall's foot would bulge by the
//   floor's nearness otherwise), bent into station space (Cyl.position), its normal from the density gradient (a cell spans
//   (R - h) dtheta across), its material the densest corner's (loose counts as dirt; a post's sample is pillar, see column_runs) with that corner's loose
//   share; the vertex's index into vmap (-1 for none).
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
	float sag_depth;   // m the underside of a roof voxel at full strain is drawn lower (ToolParams.sag_depth)
	float pad1, pad2;
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
const uint PILLAR = 4u;  // VoxelBox.PILLAR

struct S {
	float d;      // the density: the signed distance along the column to the run's nearer end, solid where positive
	float up;     // the same toward the run's end above the centre, and
	float down;   // below it: a vertical edge's crossing lies where the lower's `up` meets the upper's `down`
	float df;     // the fill less a half, for the lateral edges
	uint mat;
	float loose;  // the loose share of what fills the voxel
};

// The pool address of the voxel at ck (theta index unwrapped in the origin's frame, z index, height index),
// clamped into the box (its edge continues outward); -1 where its brick is not allocated (empty).
int word_at(ivec3 ck) {
	ivec3 lo = pc.origin * 16;
	ck = clamp(ck, lo, lo + ivec3(255, 255, K - 1));
	ivec3 b = ck >> 4;
	int e = (((b.z % BRICKS_UP + BRICKS_UP) % BRICKS_UP) * 16 + (b.y & 15)) * 16 + (b.x & 15);
	int bi = index[e];
	if (bi < 0) {
		return -1;
	}
	ivec3 v = ck & 15;
	return bi * 4096 * 2 + ((v.z * 16 + v.y) * 16 + v.x) * 2;
}

// What fills the voxel at ck (fill_at), and whether it holds a pillar (full solid of material PILLAR).
float fill_pillar(ivec3 ck, out bool pillar) {
	int a = word_at(ck);
	pillar = false;
	if (a < 0) {
		return 0.0;
	}
	uint w0 = pool[a];
	pillar = (w0 & 0xFFFFu) == 0xFFFFu && (pool[a + 1] & 255u) == PILLAR;
	return min((float(w0 & 0xFFFFu) + float(w0 >> 16)) / ONE, 1.0);
}

// What fills the voxel at ck, solid plus loose, 0 to 1.
float fill_at(ivec3 ck) {
	int a = word_at(ck);
	if (a < 0) {
		return 0.0;
	}
	uint w0 = pool[a];
	return min((float(w0 & 0xFFFFu) + float(w0 >> 16)) / ONE, 1.0);
}

// The strain of the voxel at ck, 0 to 1 (box_sand.glsl's span rule: an unsupported roof voxel sags before
// it fails): its run's underside is drawn lower by it times pc.sag_depth.
float strain_at(ivec3 ck) {
	int a = word_at(ck);
	return a >= 0 ? float(pool[a + 1] >> 25) / 127.0 : 0.0;
}

// The solid runs of ck's column over the seven voxels around it, as heights from ck's floor: a full voxel
// is solid throughout, a partial one holds its fill as a slab at its floor (where the voxel under it holds
// at least as much as the one over it) or at its roof, and slabs that touch merge into one run. A pillar
// counts as air in that choice (a roof's partial over a post keeps its slab at its roof), and a run of pillar
// voxels reaches down to the top of the floor's slab in a partial voxel directly under it and up to the
// underside of the roof's slab in a partial voxel directly over it, so the drawn post meets the floor and the
// roof (the stored pillar holds whole voxels only); `post` tells whether that reach covers ck's centre (its
// sample is drawn as pillar). Air next to the post leaves its end at the voxel boundary. A run's underside
// is drawn lower by its bottom voxel's strain times sag_depth: the sag before a roof fails.
const int RUNS = 7;
int column_runs(ivec3 ck, out float starts[RUNS], out float ends[RUNS], out bool post) {
	float g[RUNS + 2];
	float gs[RUNS + 2];
	bool p[RUNS + 2];
	for (int i = 0; i < RUNS + 2; i++) {
		g[i] = fill_pillar(ck + ivec3(0, 0, i - 4), p[i]);
		gs[i] = p[i] ? 0.0 : g[i];
	}
	post = false;
	int n = 0;
	for (int i = 1; i <= RUNS; i++) {
		float f = g[i];
		if (f <= 0.0) {
			continue;
		}
		float lo = float(i - 4);
		float a = lo;
		float b = lo + 1.0;
		if (f < 1.0) {
			if (gs[i - 1] >= gs[i + 1]) {
				b = lo + f;
			} else {
				a = lo + 1.0 - f;
			}
		}
		// The partial under a post holds its slab at its floor (the post counts as air over it); the one over it
		// at its roof while something fills the voxel over that (else its slab sits on the post already).
		if (p[i] && !p[i - 1] && g[i - 1] > 0.0 && g[i - 1] < 1.0) {
			a = lo - 1.0 + g[i - 1];
			post = post || (i == 5 && g[4] < 0.5);
		}
		if (p[i] && i + 2 < RUNS + 2 && !p[i + 1] && g[i + 1] > 0.0 && g[i + 1] < 1.0 && gs[i + 2] > 0.0) {
			b = lo + 2.0 - g[i + 1];
			post = post || (i == 3 && g[4] < 0.5);
		}
		a -= strain_at(ck + ivec3(0, 0, i - 4)) * pc.sag_depth;
		if (n > 0 && ends[n - 1] >= a - 1e-4) {
			ends[n - 1] = b;
		} else {
			starts[n] = a;
			ends[n] = b;
			n++;
		}
	}
	return n;
}

// The voxel at ck: its density is the signed distance along the column from its centre to the nearer end of
// the run it is in (solid) or of the air it is in (negative), and `up` and `down` the distances to the end
// in each direction, within 2.5 voxels, so a vertical edge's crossing interpolates to a run's exact end
// whichever voxel the end lies in (column_runs). A run thinner than a voxel that passes no voxel's centre
// (a tunnel's roof under a shallow pit, split over two partial voxels) would vanish: when it stands alone,
// half a voxel or more of air on both sides, and the fill goes on past the voxel on all four sides at its
// layer (a sheet, as a roof is), the voxel holding its larger part stands solid for it (the upper on a
// tie), the run's far end exact, its near end snapped to that centre. A sliver a ball's curved cut leaves
// just over a pit's floor is a centreless run too, but not alone, and the slivers left in a thin wall
// between two cuts are alone but no sheet (air across the wall): both stay air, as the surface nets would
// have them, where the second once stood as a stack of floating shelves. The fill less a half (the density before 2026-11-04) put every end in the middle third of
// its voxel, which meshed a slope as a stair of bricks and lit it as one, drew a thin roof's top 0.6 m low
// as a dark riser and lost it where no centre was solid.
S sample_at(ivec3 ck) {
	float f = fill_at(ck);
	S r;
	r.df = f - 0.5;
	float starts[RUNS];
	float ends[RUNS];
	bool post;
	int n = column_runs(ck, starts, ends, post);
	const float c = 0.5;
	bool solid = false;
	r.up = -2.5;
	r.down = -2.5;
	for (int i = 0; i < n; i++) {
		if (starts[i] <= c && c <= ends[i]) {
			solid = true;
			r.up = min(ends[i] - c, 2.5);
			r.down = min(c - starts[i], 2.5);
		} else if (starts[i] > c) {
			r.up = max(r.up, -(starts[i] - c));
		} else {
			r.down = max(r.down, -(c - ends[i]));
		}
	}
	if (!solid && f > 0.0) {
		bool sheet = min(fill_at(ck + ivec3(1, 0, 0)), fill_at(ck - ivec3(1, 0, 0))) >= 0.2
				&& min(fill_at(ck + ivec3(0, 1, 0)), fill_at(ck - ivec3(0, 1, 0))) >= 0.2;
		for (int i = 0; i < n && sheet; i++) {
			bool overlaps = ends[i] > 0.0 && starts[i] < 1.0;
			bool centreless = floor(ends[i] - 0.5) < ceil(starts[i] - 0.5);
			bool alone = (i == 0 || starts[i] - ends[i - 1] >= 0.5) && (i + 1 == n || starts[i + 1] - ends[i] >= 0.5);
			if (overlaps && centreless && alone) {
				float mine = min(ends[i], 1.0) - max(starts[i], 0.0);
				float other = ends[i] - starts[i] - mine;
				if (mine > other || (mine == other && starts[i] < 0.0)) {
					solid = true;
					r.up = max(ends[i] - c, 0.0);
					r.down = max(c - starts[i], 0.0);
				}
			}
		}
	}
	r.d = (solid ? 1.0 : -1.0) * min(abs(r.up), abs(r.down));
	r.mat = 0u;
	r.loose = 0.0;
	int a = word_at(ck);
	if (a >= 0) {
		uint w0 = pool[a];
		float fs = float(w0 & 0xFFFFu);
		float fl = float(w0 >> 16);
		r.mat = fl > fs ? 0u : (pool[a + 1] & 255u);
		r.loose = fl / max(fs + fl, 1.0);
	}
	if (post) {
		r.mat = PILLAR;
		r.loose = 0.0;
	}
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
			float t;
			if (a == 2) {
				float lc = abs(s[c].up);
				t = lc / max(lc + abs(s[d].down), 1e-6);
			} else {
				float dc = (s[c].d < 0.0 ? -1.0 : 1.0) * abs(s[c].df);
				float dd = (s[d].d < 0.0 ? -1.0 : 1.0) * abs(s[d].df);
				t = clamp(dc / (dc - dd), 0.0, 1.0);
			}
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
	// The skirt's outer vertices sink to meet the ground tile's ramp: the tile, its vertices at cell centres,
	// sinks a quarter cell within two cells of the chunk (tile.gdshader), so it ramps from a quarter down at
	// 1.5 cells out to level at 2.5, and the skirt's last vertex row at 2 would stand an eighth of a metre
	// over it, a ledge around every chunk (and a gap to the sky from under it).
	vec2 in_chunk = p.xy - vec2(pc.c0);
	vec2 past = max(-in_chunk, in_chunk - 16.0);
	float out_cells = max(past.x, past.y);
	p.z -= 0.25 * clamp(min(out_cells - 1.5, 2.5 - out_cells), 0.0, 0.5);
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
