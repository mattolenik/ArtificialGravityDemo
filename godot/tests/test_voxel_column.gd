extends SceneTree

## The column rule of the tunnels design (VoxelColumn): a column with gaps unpacks to voxel fractions and packs
## back, heights bit for bit (float32 at 256 m and over holds a 16-bit fraction), loose within a fraction step.

const ONE := 65535
const R := 3200.0
const DT := TAU / 16384

var failed := false

func check(ok: bool, msg: String) -> void:
	if not ok:
		push_error(msg)
		failed = true

func f32(x: float) -> float:
	return VoxelColumn.f32(x)

func col(surface: float, loose := 0.0, gaps := []) -> Dictionary:
	var c := {"surface": f32(surface), "bedrock_top": 300.0, "clay_bottom": 350.0, "clay_top": 352.0, "water_surface": 0.0,
			"loose": f32(loose), "material": 0, "compaction": 100, "saturation": 0, "R": R,
			"gap_bottom": PackedFloat32Array([0, 0, 0, 0]), "gap_top": PackedFloat32Array([0, 0, 0, 0]),
			"gap_loose": PackedFloat32Array([0, 0, 0, 0]), "gap_material": PackedInt32Array([0, 0, 0, 0])}
	for g in gaps.size():
		c.gap_bottom[g] = f32(gaps[g][0]); c.gap_top[g] = f32(gaps[g][1]); c.gap_loose[g] = f32(gaps[g][2])
	return c

## The loose fraction a thickness `l` on a floor at `h` fills voxel k (the floor voxel) with: the window's
## l (R - h) by the voxel's annulus (R - k - 0.5).
func loose_frac(l: float, h: float, k: int) -> int:
	return roundi(l * (R - h) / (R - k - 0.5) * ONE)

func same_heights(a: Dictionary, b: Dictionary) -> bool:
	if a.surface != b.surface or a.gap_bottom != b.gap_bottom or a.gap_top != b.gap_top:
		return false
	if absf(a.loose - b.loose) > 2.0 / ONE:
		return false
	for g in 4:
		if absf(a.gap_loose[g] - b.gap_loose[g]) > 2.0 / ONE:
			return false
	return true

func _initialize() -> void:
	# test_unpack_plain: a surface at 410.37 with 0.5 m of loose over 380..419: full to 409, the partial at 410
	# holding both, nothing above.
	var plain := col(410.37, 0.5)
	var v := VoxelColumn.unpack(plain, 380, 40)
	check(v.solid.size() == 40 and v.solid[0] == ONE and v.solid[29] == ONE and v.loose[29] == 0, "plain full voxels %s" % [v.solid])
	check(v.solid[30] == 24248 and v.loose[30] == loose_frac(0.5, plain.surface, 410) and v.compaction[30] == 100, "plain top voxel solid %d loose %d (want %d)" % [v.solid[30], v.loose[30], loose_frac(0.5, plain.surface, 410)])
	check(v.solid[31] == 0 and v.loose[31] == 0 and v.material[30] == 0, "plain nothing above")
	# test_unpack_gap: a gap [405, 407.5] with 0.25 m of loose on its floor: 405 and 406 air, the loose in 405, a
	# roof partial at 407, full below.
	var gapped := col(410.37, 0.0, [[405.0, 407.5, 0.25]])
	v = VoxelColumn.unpack(gapped, 380, 40)
	check(v.solid[24] == ONE and v.solid[25] == 0 and v.solid[26] == 0 and v.solid[27] == 32768 and v.solid[28] == ONE and v.solid[30] == 24248, "gap solids %s" % [v.solid.slice(24, 31)])
	check(v.loose[25] == loose_frac(0.25, 405.0, 405) and v.loose[26] == 0 and v.loose[27] == 0 and v.compaction[25] == 0, "gap loose %s" % [v.loose.slice(24, 31)])
	# test_pack_round_trip: the two above and a 0.3 m sliver on a voxel floor between two gaps.
	var sliver := col(410.37, 0.0, [[406.3, 408.0, 0.0], [404.5, 406.0, 0.1]])
	for c in [plain, gapped, sliver]:
		var back: Dictionary = VoxelColumn.pack(VoxelColumn.unpack(c, 380, 40), 380, c)
		check(same_heights(back, c) and not back.overflow, "round trip %s -> %s" % [c, back])
	check(VoxelColumn.pack(VoxelColumn.unpack(plain, 380, 40), 380, plain).compaction == 100, "the top loose's compaction")
	# test_pack_partial_cases: hand-built voxels over 400..407 in a column stored solid to 500 (so a run that
	# continues past the range merges with the stored remainder).
	var tall := col(500.0)
	var vox := VoxelColumn.unpack(col(399.0), 400, 8)  # all air
	# (a) a partial on top of fulls that continue below the range (the column stored solid to 400): the surface
	# is the partial's top.
	for k in 3: vox.solid[k] = ONE
	vox.solid[3] = 26214
	var p := VoxelColumn.pack(vox, 400, col(400.0))
	check(p.surface == f32(403 + 26214.0 / ONE) and p.gap_top[0] == 0.0 and p.loose == 0.0, "top partial %s" % p)
	# (b) a partial hanging under fulls that continue past the top: a gap from the lower fulls' top to its bottom.
	vox = VoxelColumn.unpack(col(399.0), 400, 8)
	vox.solid[0] = ONE; vox.solid[1] = ONE; vox.solid[4] = 16384
	for k in range(5, 8): vox.solid[k] = ONE
	p = VoxelColumn.pack(vox, 400, tall)
	check(p.surface == 500.0 and p.gap_bottom[0] == 402.0 and p.gap_top[0] == f32(405 - 16384.0 / ONE) and p.gap_top[1] == 0.0, "bottom partial %s" % p)
	# (c) a lone partial: a run of its own thickness on its voxel's floor, gaps either side.
	vox = VoxelColumn.unpack(col(399.0), 400, 8)
	vox.solid[0] = ONE; vox.solid[1] = ONE; vox.solid[3] = 19661
	p = VoxelColumn.pack(vox, 400, tall)
	check(p.surface == 500.0 and p.gap_bottom[0] == f32(403 + 19661.0 / ONE) and p.gap_top[0] == 408.0 \
			and p.gap_bottom[1] == 402.0 and p.gap_top[1] == 403.0 and p.gap_top[2] == 0.0, "lone partial %s" % p)
	# Loose at the range's bottom with no solid under it in the range lands on the stored run below.
	vox = VoxelColumn.unpack(col(399.0), 400, 8)
	vox.loose[0] = 32768
	p = VoxelColumn.pack(vox, 400, col(399.0))
	check(p.surface == 399.0 and absf(p.loose - 0.5 * (R - 400.5) / (R - 399.0)) < 2.0 / ONE, "loose parked on the run below %s" % p)
	# test_pack_clips_to_range: a surface above the range stays.
	var high := col(450.0)
	p = VoxelColumn.pack(VoxelColumn.unpack(high, 380, 40), 380, high)
	check(p.surface == 450.0 and p.gap_top[0] == 0.0 and p.loose == 0.0, "clips to range %s" % p)
	# A cut inside the range clamps the clay to the new surface and sets the material by the strata.
	var clay := col(412.0)
	clay.clay_bottom = 405.0; clay.clay_top = 410.0
	vox = VoxelColumn.unpack(clay, 400, 16)
	vox.solid[10] = 0; vox.solid[11] = 0; vox.solid[9] = 32768
	p = VoxelColumn.pack(vox, 400, clay)
	check(p.surface == 409.5 and p.clay_top == 409.5 and p.clay_bottom == 405.0 and p.bedrock_top == 300.0 and p.material == 1, "strata clamped %s" % p)
	# test_cap: five gaps pack to four, the lowest two merged, flagged.
	vox = VoxelColumn.unpack(col(399.0), 400, 16)
	for k in [0, 2, 4, 6, 8, 10]: vox.solid[k] = ONE
	p = VoxelColumn.pack(vox, 400, col(411.0))
	check(p.overflow and p.surface == 411.0 and p.gap_bottom[0] == 409.0 and p.gap_top[0] == 410.0 and p.gap_bottom[3] == 401.0 and p.gap_top[3] == 404.0, "cap %s" % p)
	# test_material_at: rock to bedrock_top inclusive, clay through the lens, dirt elsewhere.
	check(VoxelColumn.material_at(299.0, plain) == 2 and VoxelColumn.material_at(300.0, plain) == 2 and VoxelColumn.material_at(300.5, plain) == 0, "rock")
	check(VoxelColumn.material_at(350.0, plain) == 1 and VoxelColumn.material_at(352.0, plain) == 1 and VoxelColumn.material_at(352.01, plain) == 0 and VoxelColumn.material_at(349.9, plain) == 0, "clay and dirt")
	# test_voxel_volume: the annulus of the 1 m wedge at height index k.
	check(absf(VoxelColumn.voxel_volume(400, R, DT) - DT * ((R - 400) * (R - 400) - (R - 401) * (R - 401)) / 2.0) < 1e-9, "voxel volume")
	if failed: quit(1)
	else: print("PASS"); quit(0)
