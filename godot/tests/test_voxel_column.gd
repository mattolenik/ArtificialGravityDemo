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
	# (d) a roof: a tunnel cut under the surface sliver leaves its underside hanging from that sliver (two
	# partials, air under, nothing full over): one run, the surface unchanged, one gap under it.
	var roof := col(404.37)
	vox = VoxelColumn.unpack(roof, 400, 8)
	vox.solid[2] = 0; vox.solid[3] = roundi(0.13 * ONE)
	p = VoxelColumn.pack(vox, 400, roof)
	check(p.surface == roof.surface and p.gap_bottom[0] == 402.0 and p.gap_top[0] == f32(404 - roundi(0.13 * ONE) / float(ONE)) and p.gap_top[1] == 0.0, "roof underside %s" % p)
	# unpack flags a roof's underside hanging, and pack hangs a flagged partial even over solid (a remnant the
	# scoop left over a ball's centre, with the floor's remnant under it): one gap, not two.
	v = VoxelColumn.unpack(gapped, 380, 40)
	check(v.hanging[27] == 1 and v.hanging[30] == 0 and v.hanging[24] == 0, "hanging flags %s" % [v.hanging.slice(24, 31)])
	vox = VoxelColumn.unpack(col(412.0), 400, 16)
	vox.solid[9] = roundi(0.4 * ONE); vox.solid[10] = roundi(0.3 * ONE); vox.hanging[10] = 1
	p = VoxelColumn.pack(vox, 400, col(412.0))
	check(p.surface == 412.0 and p.gap_bottom[0] == f32(409 + roundi(0.4 * ONE) / float(ONE)) and p.gap_top[0] == f32(411 - roundi(0.3 * ONE) / float(ONE)) and p.gap_top[1] == 0.0, "flagged remnant hangs %s" % p)
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
	# test_cap: five gaps pack to four, the lowest two merged, flagged; the solid between them (402..403, dirt)
	# becomes loose on the merged gap's floor by its material's swell (nothing is lost).
	vox = VoxelColumn.unpack(col(399.0), 400, 16)
	for k in [0, 2, 4, 6, 8, 10]: vox.solid[k] = ONE
	p = VoxelColumn.pack(vox, 400, col(411.0), PackedFloat32Array([1.2, 1.35, 1.6, 1.6]))
	check(p.overflow and p.surface == 411.0 and p.gap_bottom[0] == 409.0 and p.gap_top[0] == 410.0 and p.gap_bottom[3] == 401.0 and p.gap_top[3] == 404.0 \
			and p.gap_loose[3] == f32(1.2 * (R - 402.5) / (R - 401.0)), "cap %s" % p)
	# test_pillar_round_trip: a gap 402..405 with the pillar material unpacks to pillar voxels and packs back exactly.
	var post := col(410.0); post.gap_bottom[0] = 402.0; post.gap_top[0] = 405.0; post.gap_material[0] = VoxelColumn.PILLAR
	var pv := VoxelColumn.unpack(post, 380, 40)
	check(pv.material[22] == VoxelColumn.PILLAR and pv.solid[22] == VoxelColumn.FRACTION_ONE and pv.material[24] == VoxelColumn.PILLAR and pv.solid[21] == VoxelColumn.FRACTION_ONE and pv.material[21] == 0 and pv.solid[25] == VoxelColumn.FRACTION_ONE and pv.material[25] == 0, "a pillar gap is three pillar voxels between dirt")
	var pb := VoxelColumn.pack(pv, 380, post)
	check(pb.gap_bottom[0] == 402.0 and pb.gap_top[0] == 405.0 and pb.gap_material[0] == VoxelColumn.PILLAR and pb.surface == 410.0, "the pillar packs back as its gap")
	# A pillar stored outside the box's range, or across either edge of it, keeps its gap.
	var tall_post := col(420.0); tall_post.gap_bottom[0] = 402.0; tall_post.gap_top[0] = 405.0; tall_post.gap_material[0] = VoxelColumn.PILLAR
	for k0 in [390, 395, 403, 406]:
		pb = VoxelColumn.pack(VoxelColumn.unpack(tall_post, k0, 8), k0, tall_post)
		check(same_heights(pb, tall_post) and pb.gap_material[0] == VoxelColumn.PILLAR, "a pillar at the range's edge from %d %s" % [k0, pb])
	# Between a floor's partial and a roof's: one gap, the partials dirt, the whole voxels between them pillar.
	var propped := col(410.0); propped.gap_bottom[0] = f32(402.3); propped.gap_top[0] = f32(406.6); propped.gap_material[0] = VoxelColumn.PILLAR
	pv = VoxelColumn.unpack(propped, 380, 40)
	check(pv.material[22] == 0 and pv.solid[22] < ONE and pv.material[23] == VoxelColumn.PILLAR and pv.material[25] == VoxelColumn.PILLAR and pv.material[26] == 0 and pv.hanging[26] == 1, "a propped roof's voxels %s" % [pv.material.slice(21, 28)])
	pb = VoxelColumn.pack(pv, 380, propped)
	check(same_heights(pb, propped) and pb.gap_material[0] == VoxelColumn.PILLAR and pb.gap_top[1] == 0.0, "a propped roof is one gap %s" % pb)
	# test_pillar_split: air between the pillar and its floor's loose, and air with loose over it: three gaps, the
	# pillar's sharing its bounds with the air gaps either side; they unpack to the same voxels.
	pv = VoxelColumn.unpack(col(410.0), 380, 40)
	for k in range(22, 27): pv.solid[k] = 0
	pv.loose[22] = roundi(0.3 * ONE); pv.loose[26] = roundi(0.2 * ONE)
	for k in [24, 25]: pv.solid[k] = ONE; pv.material[k] = VoxelColumn.PILLAR
	pb = VoxelColumn.pack(pv, 380, col(410.0))
	check(pb.gap_bottom[0] == 406.0 and pb.gap_top[0] == 407.0 and pb.gap_material[0] == 0 and absf(pb.gap_loose[0] - 0.2 * (R - 406.5) / (R - 406.0)) < 2.0 / ONE \
			and pb.gap_bottom[1] == 404.0 and pb.gap_top[1] == 406.0 and pb.gap_material[1] == VoxelColumn.PILLAR and pb.gap_loose[1] == 0.0 \
			and pb.gap_bottom[2] == 402.0 and pb.gap_top[2] == 404.0 and pb.gap_material[2] == 0 and absf(pb.gap_loose[2] - 0.3 * (R - 402.5) / (R - 402.0)) < 2.0 / ONE, "a split hollow %s" % pb)
	var back_v := VoxelColumn.unpack(pb, 380, 40)
	check(back_v.material[24] == VoxelColumn.PILLAR and back_v.material[25] == VoxelColumn.PILLAR and back_v.solid[23] == 0 and back_v.loose[23] == 0 and back_v.solid[26] == 0 \
			and absi(back_v.loose[22] - pv.loose[22]) <= 2 and absi(back_v.loose[26] - pv.loose[26]) <= 2, "a split hollow unpacks %s %s" % [back_v.solid.slice(21, 28), back_v.loose.slice(21, 28)])
	# test_pillar_overflow_merge: five gaps, the second a pillar: the merge drops a dirt sliver, never the pillar.
	# Air 401..402, the pillar 403..405, air 406..407 and 408..409 stored, air 411..412 cut in the box: the lowest
	# two air gaps in a row merge (406..409), the sliver 407..408 loose on its floor by dirt's swell.
	var five := col(418.0, 0.0, [[401.0, 402.0, 0.0], [403.0, 405.0, 0.0], [406.0, 407.0, 0.0], [408.0, 409.0, 0.0]])
	five.gap_material[1] = VoxelColumn.PILLAR
	vox = VoxelColumn.unpack(five, 400, 20)
	vox.solid[11] = 0
	var swell5 := PackedFloat32Array([1.2, 1.35, 1.6, 1.6, 1.0])
	p = VoxelColumn.pack(vox, 400, five, swell5)
	check(p.overflow and p.gap_bottom[0] == 411.0 and p.gap_top[0] == 412.0 and p.gap_bottom[1] == 406.0 and p.gap_top[1] == 409.0 \
			and p.gap_loose[1] == f32(swell5[0] * (R - 407.5) / (R - 406.0)) and p.gap_material[1] == 0 \
			and p.gap_bottom[2] == 403.0 and p.gap_top[2] == 405.0 and p.gap_material[2] == VoxelColumn.PILLAR and p.gap_bottom[3] == 401.0 and p.gap_top[3] == 402.0, "pillar overflow %s" % p)
	# test_material_at: rock to bedrock_top inclusive, clay through the lens, dirt elsewhere.
	check(VoxelColumn.material_at(299.0, plain) == 2 and VoxelColumn.material_at(300.0, plain) == 2 and VoxelColumn.material_at(300.5, plain) == 0, "rock")
	check(VoxelColumn.material_at(350.0, plain) == 1 and VoxelColumn.material_at(352.0, plain) == 1 and VoxelColumn.material_at(352.01, plain) == 0 and VoxelColumn.material_at(349.9, plain) == 0, "clay and dirt")
	# test_voxel_volume: the annulus of the 1 m wedge at height index k.
	check(absf(VoxelColumn.voxel_volume(400, R, DT) - DT * ((R - 400) * (R - 400) - (R - 401) * (R - 401)) / 2.0) < 1e-9, "voxel volume")
	if failed: quit(1)
	else: print("PASS"); quit(0)
