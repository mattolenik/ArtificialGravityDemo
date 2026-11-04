## The column rule of the tunnels design on the CPU: the reference for box_unpack.glsl and box_pack.glsl and
## the headless tests. A column (the window fields of one cell, as EditLayer.decode returns them, plus "R" the
## hull radius) holds solid runs: the top run up to `surface`, then below each gap g (gap_top[g] > gap_bottom[g],
## listed top-down) the next run, the last one reaching the hull. A voxel k spans heights [k, k + 1) and holds a
## solid fraction and a loose fraction in 0..FRACTION_ONE, their sum at most FRACTION_ONE.
## Unpack: a voxel's solid is the measure of its overlap with the runs; the loose on a run's top (the window's
## loose, m over the floor's area (R - floor)) fills the voxels from the floor up by the annulus volume
## (R - k - 0.5) of each, so the voxels hold the same volume the window says.
## Pack: a full voxel is solid over its whole height; a partial voxel hangs from its ceiling ([k + 1 - f, k + 1])
## when flagged hanging (unpack flags a run's underside; the scoop what it leaves over a ball's centre) or
## when solid lies over it and none under, and otherwise sits on its floor ([k, k + f]); touching pieces
## merge into runs; the air between runs is a gap; loose
## goes to the run below it, converted back to m over that run's top. A run that continues past the box's
## range keeps the stored boundary and loose beyond it. Heights come back as float32 (what the window holds):
## exact for a height the window stored at 256 m and over, loose within a fraction step. Only this file and the
## tests may loop per voxel.
class_name VoxelColumn

const FRACTION_ONE := 65535
## Rock up to bedrock_top, clay through the lens, dirt elsewhere (MaterialSet ids).
const DIRT := 0
const CLAY := 1
const ROCK := 2
## The bottom run's floor: nothing is dug under the hull.
const BELOW := -1.0e9


## x as the float32 the window would store.
static func f32(x: float) -> float:
	return PackedFloat32Array([x])[0]


## The annulus of the 1 m wedge at height index k over one cell of dtheta: the m³ a fraction of 1 holds.
static func voxel_volume(k: int, R: float, dtheta: float) -> float:
	return dtheta * ((R - k) * (R - k) - (R - k - 1) * (R - k - 1)) / 2.0


static func material_at(h: float, col: Dictionary) -> int:
	if h <= col.bedrock_top:
		return ROCK
	return CLAY if h >= col.clay_bottom and h <= col.clay_top else DIRT


## The solid runs of col as [top, bottom, loose_m, compaction] top-down, the last reaching BELOW; a run's loose
## is the m lying on its top (the window's loose for the top run, gap_loose[g] under gap g).
static func runs_of(col: Dictionary) -> Array:
	var gaps := []
	for g in 4:
		if col.gap_top[g] > col.gap_bottom[g]:
			gaps.append([col.gap_top[g], col.gap_bottom[g], col.gap_loose[g]])
	gaps.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0])
	var out := []
	var top: float = col.surface
	var loose_m: float = col.loose
	var comp: int = col.compaction
	for g in gaps:
		if g[0] < top:
			out.append([top, g[0], loose_m, comp])
		if g[1] < top:
			top = g[1]
			loose_m = g[2]
			comp = 0
	out.append([top, BELOW, loose_m, comp])
	return out


## Voxels k0 .. k0 + n - 1 of col: solid and loose fractions, the solid's material (by the strata at its top),
## the loose's compaction (the column's byte on the top run's loose, 0 in a gap) and the hanging flag (1 on a
## partial holding a run's underside).
static func unpack(col: Dictionary, k0: int, n: int) -> Dictionary:
	var solid := PackedInt32Array()
	solid.resize(n)
	var loose := PackedInt32Array()
	loose.resize(n)
	var material := PackedByteArray()
	material.resize(n)
	var compaction := PackedByteArray()
	compaction.resize(n)
	var hanging := PackedByteArray()
	hanging.resize(n)
	var R: float = col.R
	var runs := runs_of(col)
	for run in runs:
		var lo: float = max(run[1], float(k0))
		var hi: float = min(run[0], float(k0 + n))
		for k in range(floori(lo), ceili(hi)):
			var m: float = min(hi, k + 1.0) - max(lo, float(k))
			if m <= 0.0:
				continue
			if solid[k - k0] == 0:
				material[k - k0] = material_at(min(hi, k + 1.0) - 0.01, col)
				hanging[k - k0] = 1 if lo > k and hi >= k + 1.0 else 0
			else:
				hanging[k - k0] = 0
			solid[k - k0] = mini(solid[k - k0] + roundi(m * FRACTION_ONE), FRACTION_ONE)
	for run in runs:
		# A run whose top is under the range keeps its loose stored (pack keeps it too); loose past the range's
		# top is dropped (the box top is 24 m over the feet).
		if run[2] <= 0.0 or run[0] < k0:
			continue
		# The loose's volume over (R - floor), per unit dtheta, placed from the floor voxel up by each voxel's
		# annulus (R - k - 0.5).
		var v: float = run[2] * (R - run[0])
		var k := floori(run[0])
		while v > 0.0 and k < k0 + n:
			var room := FRACTION_ONE - solid[k - k0] - loose[k - k0]
			if room > 0:
				var q := mini(roundi(v / (R - k - 0.5) * FRACTION_ONE), room)
				if q == 0:
					break
				loose[k - k0] += q
				compaction[k - k0] = run[3]
				v -= q / float(FRACTION_ONE) * (R - k - 0.5)
			k += 1
	return {"solid": solid, "loose": loose, "material": material, "compaction": compaction, "hanging": hanging}


## The column back from voxels k0 .. k0 + n - 1 (vox as unpack returns them), merged with col's runs outside
## that range: a copy of col with surface, loose, the gaps, material (by the strata at the surface), compaction
## (the top loose's) and the clay clamped to the surface, plus "overflow": true when five or more gaps had to
## merge into four (the lowest two, the sliver between them lost).
static func pack(vox: Dictionary, k0: int, col: Dictionary) -> Dictionary:
	var R: float = col.R
	var s: PackedInt32Array = vox.solid
	var l: PackedInt32Array = vox.loose
	var n := s.size()
	var hang: PackedByteArray = vox.get("hanging", PackedByteArray())
	if hang.size() != n:
		hang.resize(n)
	var top_k := float(k0 + n)
	# Solid pieces [bottom, top, loose_v (per unit dtheta, m²), compaction], bottom-up: the stored runs' parts
	# under the range (their loose kept when it lies under the range too), each voxel's piece by the partial
	# rule, then the stored parts over the range with their loose.
	var pieces := []
	var stored := runs_of(col)
	for i in range(stored.size() - 1, -1, -1):
		var run: Array = stored[i]
		if run[1] < k0:
			pieces.append([run[1], min(run[0], float(k0)), run[2] * (R - run[0]) if run[0] < k0 else 0.0, run[3]])
	var solid_under: bool = not pieces.is_empty() and pieces[-1][1] == float(k0)
	for k in n:
		var f := s[k]
		if f == 0:
			continue
		var h := k0 + k
		if f == FRACTION_ONE:
			pieces.append([float(h), h + 1.0, 0.0, 0])
		elif hang[k] == 0 and ((k > 0 and s[k - 1] > 0) or (k == 0 and solid_under)):
			pieces.append([float(h), h + f / float(FRACTION_ONE), 0.0, 0])
		elif hang[k] != 0 or (k + 1 < n and s[k + 1] > 0) or (k + 1 == n and _solid_at(stored, top_k)):
			pieces.append([h + 1.0 - f / float(FRACTION_ONE), h + 1.0, 0.0, 0])
		else:
			pieces.append([float(h), h + f / float(FRACTION_ONE), 0.0, 0])
	for i in range(stored.size() - 1, -1, -1):
		var run: Array = stored[i]
		if run[0] > top_k:
			pieces.append([max(run[1], top_k), run[0], run[2] * (R - run[0]), run[3]])
	# Touching pieces merge into runs; the merged run takes the upper piece's loose (a stored run's, when its top
	# is past the range).
	var runs := []
	for p in pieces:
		if not runs.is_empty() and runs[-1][1] == p[0]:
			runs[-1][1] = p[1]
			runs[-1][2] = p[2]
			runs[-1][3] = p[3]
		else:
			runs.append(p)
	# Loose in the range goes to the run under it: the highest run with its bottom at or under the voxel's floor
	# and its top at or under the voxel's ceiling (the voxel's own ceiling piece is not its floor).
	for k in n:
		if l[k] == 0:
			continue
		var h := float(k0 + k)
		var r := runs.size() - 1
		while r >= 0 and (runs[r][0] > h or runs[r][1] > h + 1.0):
			r -= 1
		if r >= 0:
			runs[r][2] += l[k] / float(FRACTION_ONE) * (R - h - 0.5)
			runs[r][3] = vox.compaction[k]
	# Top-down: the surface, then a gap under each run, at most four.
	var out := col.duplicate(true)
	out.overflow = false
	runs.reverse()
	var gaps := []
	for i in runs.size() - 1:
		gaps.append([runs[i + 1][1], runs[i][0], runs[i + 1][2] / (R - runs[i + 1][1])])
	while gaps.size() > 4:
		out.overflow = true
		var b: Array = gaps.pop_back()
		var a: Array = gaps[-1]
		gaps[-1] = [b[0], a[1], (a[2] * (R - a[0]) + b[2] * (R - b[0])) / (R - b[0])]
	out.surface = f32(runs[0][1])
	out.loose = f32(runs[0][2] / (R - runs[0][1]))
	out.compaction = runs[0][3]
	for g in 4:
		out.gap_bottom[g] = f32(gaps[g][0]) if g < gaps.size() else 0.0
		out.gap_top[g] = f32(gaps[g][1]) if g < gaps.size() else 0.0
		out.gap_loose[g] = f32(gaps[g][2]) if g < gaps.size() else 0.0
		out.gap_material[g] = 0
	out.clay_bottom = min(col.clay_bottom, out.surface)
	out.clay_top = min(col.clay_top, out.surface)
	out.material = ROCK if col.bedrock_top >= out.surface - 0.01 else (CLAY if out.clay_top >= out.surface - 0.01 else DIRT)
	return out


## Whether height h lies inside a stored run (its bottom at or under h, its top over it).
static func _solid_at(runs: Array, h: float) -> bool:
	for run in runs:
		if run[1] <= h and run[0] > h:
			return true
	return false
