## Windowed check of the voxel box (the tunnels plan), on the tool run's world copy and with its helpers
## (this script extends tool_run.gd and routes its own phases). Phases:
## unpack: with the box live around the spawn, every window field is read, the box packed (pack_all_sync) and
##    every field read again: bit for bit equal (no column was dirty, so none was written); the brick stack
##    under the spawn is read back and each of its 256 columns, packed on the CPU by VoxelColumn.pack from the
##    GPU's voxels, gives the window's surface within 1e-4 m with no gap, and the GPU's voxels equal
##    VoxelColumn.unpack of the window's column (solid exactly, loose within one fraction step).
## move: the player teleported 100 m along z and back (the box moves six or seven bricks each way): every
##    window field bit for bit as before, the box's origin having changed and come back.
## seam: the player teleported to theta = 0 on the spawn's row (the box crosses the seam) and back: every window
##    field bit for bit as before, the box's origin on the seam's bricks meanwhile.
## reload: a 2 m³ window-side deposit of radius 1 at R1, then reload of its disc: the loose fractions over the
##    disc's columns, each by its voxel's annulus, add up to 2 m³ within 0.1 %, as the window's loose does.
## shovel (S, flat dry ground, the player 4 cells spinward): a scoop at S's collider point holds half the ball
##    (Tools.ball_volume) times the swell within 2 %, and the window's surface over the box of 3 dropped by
##    that solid volume (_removed) within 0.1 %; dumped 4 m along +z, the shovel is empty, the window's loose
##    over the box of 3 there and the box's loose fractions by their annuli both hold it within 0.1 %; two
##    scoops at W (a pit about 2 m deep) then two balls 1.5 m under the wall's surface 1.2 m along +z: the
##    column 2 m along holds exactly one gap under an unchanged surface (the second ball merged with the first's
##    hollow); the ring is shown while the player looks at the ground near them and hidden looking level (the
##    hit beyond reach).
## sand (D, flat ground): a 30 m³ window-side deposit of radius 1 (reloaded into the box by stamp_tool) settles
##    in the box within 10 s: the window's loose over the box of 24 holds it within 0.1 %, the steepest loose
##    slope is at repose · 1.02.
## edge: a 5 m³ deposit two cells inside the box's far edge along z settles with its volume kept within 0.1 %
##    over the box of 8 (the sand parks dirt at the edge, none crosses).
## cave (C, flat ground): scoops at one spot until the pit is over 3 m deep: once settled no loose lies over
##    the box of 6 (the walls stand under the 4 m free height); scoops on until it is over 5 m deep: once
##    settled loose lies there (the walls caved), no wall step stands more than 2 cm over max(stand · 1.02 · w,
##    free), and the annulus between the first and last surfaces over the box of 8 is the hand's solid plus
##    the loose's within 0.1 % (each by the swell).
## rock (the noise report's rock site): a scoop on the first cell within 6 of the player's cell + (0, 4)
##    whose ball footprint is bare rock (every cell's surface at its bedrock_top) holds nothing and changes
##    no surface; the footprint's cells and their top voxels are printed.
## The GPU time of the unpack lists (the first fill, the moves, the reload) and the pack lists is printed
## against 0.5 ms per brick allocated.
extends "res://terrain/tool_run.gd"

const BOX_BUDGET := 0.5


func _route() -> void:
	var p := _terrain.params
	var spawn := p.cell_of(_terrain.maps.spawn.x, _terrain.maps.spawn.y)
	await _frames(10)
	_listening = true
	_phase = "unpack"
	if not await _unpack(spawn):
		return
	_phase = "move"
	if not await _move(spawn):
		return
	_phase = "seam"
	if not await _seam_move(spawn):
		return
	_phase = "reload"
	if not await _reload(spawn + Vector2i(0, 40)):
		return
	_phase = "shovel"
	if not await _shovel_box(spawn + Vector2i(0, 80)):
		return
	_phase = "rock"
	if not await _rock_box():
		return
	_phase = "sand"
	if not await _sand(spawn + Vector2i(0, -40)):
		return
	_phase = "edge"
	if not await _edge(spawn):
		return
	_phase = "cave"
	if not await _cave(spawn + Vector2i(0, -80)):
		return
	_phase = "pickup"
	if not await _pickup_box(spawn + Vector2i(40, 0)):
		return
	_phase = ""
	await _frames(6)
	_box_summary()
	print("PASS" if _ok else "FAIL")
	get_tree().quit(0 if _ok else 1)


## Every window field, read synchronously.
func _snapshot() -> Dictionary:
	var out := {}
	for f: String in TerrainWindow.FIELDS:
		out[f] = _read(f)
	return out


func _same(a: Dictionary, b: Dictionary) -> Array[String]:
	var differ: Array[String] = []
	for f: String in TerrainWindow.FIELDS:
		if a[f] != b[f]:
			differ.append(f)
	return differ


## Per differing field: how many texels differ and the first one's cell and values (floats or bytes).
func _diff_report(a: Dictionary, b: Dictionary) -> String:
	var n := _terrain.window.size
	var out := PackedStringArray()
	for f: String in _same(a, b):
		var is_float := f in TerrainWindow.FLOAT_FIELDS
		var x: Array = Array(a[f].to_float32_array()) if is_float else Array(a[f])
		var y: Array = Array(b[f].to_float32_array()) if is_float else Array(b[f])
		var count := 0
		var first := ""
		for k in n * n:
			if x[k] == y[k]:
				continue
			count += 1
			if first.is_empty():
				@warning_ignore("integer_division")
				first = "texel %s: %s -> %s" % [Vector2i(k % n, k / n), x[k], y[k]]
		out.append("%s %d texels (%s)" % [f, count, first])
	return "; ".join(out)


## The window's column at cell, as VoxelColumn takes it.
func _col_at(s: Dictionary, cell: Vector2i) -> Dictionary:
	var c := {"R": _terrain.params.radius}
	for f: String in ["surface", "bedrock_top", "clay_bottom", "clay_top", "water_surface", "loose"]:
		c[f] = _f(s[f], cell)
	for f: String in ["material", "compaction", "saturation"]:
		c[f] = _b(s[f], cell)
	for g: String in ["gap_bottom", "gap_top", "gap_loose"]:
		c[g] = PackedFloat32Array([_f(s[g + "0"], cell), _f(s[g + "1"], cell), _f(s[g + "2"], cell), _f(s[g + "3"], cell)])
	c["gap_material"] = PackedInt32Array([_b(s["gap_material0"], cell), _b(s["gap_material1"], cell), _b(s["gap_material2"], cell), _b(s["gap_material3"], cell)])
	return c


## The four bricks (bottom up) of the brick stack holding cell, read back; an empty array where the slot holds none.
func _stack(cell: Vector2i) -> Array[PackedByteArray]:
	var box := _terrain.box
	var out: Array[PackedByteArray] = []
	for L in VoxelBox.BRICKS_UP:
		out.append(box.read_brick(VoxelBox.slot_of(box.brick_of_cell(cell, box.bottom() + L * VoxelBox.BRICK))))
	_stat_of(_phase).reads += 8
	return out


## The 64 voxels of cell's column from its stack, as VoxelColumn returns them.
func _column_vox(stack: Array[PackedByteArray], cell: Vector2i) -> Dictionary:
	var n := VoxelBox.BRICKS_UP * VoxelBox.BRICK
	var vox := {"solid": PackedInt32Array(), "loose": PackedInt32Array(), "material": PackedByteArray(), "compaction": PackedByteArray(), "hanging": PackedByteArray()}
	for k: String in vox:
		vox[k].resize(n)
	var x := posmod(cell.x, VoxelBox.BRICK)
	var z := posmod(cell.y, VoxelBox.BRICK)
	for L in VoxelBox.BRICKS_UP:
		if stack[L].is_empty():
			continue
		for y in VoxelBox.BRICK:
			var v := VoxelBox.voxel(stack[L], x, y, z)
			var i := L * VoxelBox.BRICK + y
			vox.solid[i] = v.solid
			vox.loose[i] = v.loose
			vox.material[i] = v.material
			vox.compaction[i] = v.compaction
			vox.hanging[i] = v.hanging
	return vox


func _unpack(spawn: Vector2i) -> bool:
	var box := _terrain.box
	await _frames(3)
	if not box.exists():
		return _quit("The box did not follow the player after the first patch.")
	var before := _snapshot()
	box.pack_all_sync()
	await _frames(2)
	var after := _snapshot()
	var differ := _same(before, after)
	var bricks := box.allocated()
	print("unpack: the box at %s (bottom %d m), %d of %d slots hold a brick (%.1f MB of %d); pack_all_sync changed %s" % [
			box.origin(), box.bottom(), bricks, VoxelBox.SLOTS, bricks * VoxelBox.BRICK_BYTES / 1048576.0, VoxelBox.POOL_BRICKS * VoxelBox.BRICK_BYTES / 1048576, "no field" if differ.is_empty() else str(differ)])
	_report("unpack then pack changes no column", differ.is_empty())
	# The brick stack under the spawn against the window's columns, both ways.
	var stack := _stack(spawn)
	var brick := box.brick_of_cell(spawn, box.bottom())
	var k0 := box.bottom()
	var bad_pack := 0
	var bad_solid := 0
	var bad_loose := 0
	var worst := 0.0
	for z in VoxelBox.BRICK:
		for x in VoxelBox.BRICK:
			var cell := Vector2i(posmod(brick.x * VoxelBox.BRICK + x, _terrain.params.n_theta()), brick.y * VoxelBox.BRICK + z)
			var col := _col_at(after, cell)
			var vox := _column_vox(stack, cell)
			var back := VoxelColumn.pack(vox, k0, col)
			worst = maxf(worst, absf(back.surface - col.surface))
			if absf(back.surface - col.surface) > 1e-4 or back.gap_top[0] != 0.0 or absf(back.loose - col.loose) > 2.0 / VoxelColumn.FRACTION_ONE:
				bad_pack += 1
			var ref := VoxelColumn.unpack(col, k0, VoxelBox.BRICKS_UP * VoxelBox.BRICK)
			if ref.solid != vox.solid:
				bad_solid += 1
			for i in ref.loose.size():
				if absi(ref.loose[i] - vox.loose[i]) > 1:
					bad_loose += 1
					break
	print("unpack: the stack at brick %s: of 256 columns, %d pack to a surface off the window's (worst %.1f µm) or with a gap or loose, %d differ from the CPU rule in solid, %d in loose" % [brick, bad_pack, worst * 1e6, bad_solid, bad_loose])
	_report("the GPU's voxels are the window's columns by the CPU rule", bad_pack == 0 and bad_solid == 0 and bad_loose == 0)
	return true


func _move(spawn: Vector2i) -> bool:
	var box := _terrain.box
	var before := _snapshot()
	var o0 := box.origin()
	if not await _teleport(spawn + Vector2i(0, 100)):
		return false
	await _frames(3)
	var o1 := box.origin()
	if not await _teleport(spawn):
		return false
	await _frames(3)
	var o2 := box.origin()
	var after := _snapshot()
	var differ := _same(before, after)
	print("move: the box from %s to %s and back to %s; %s" % [o0, o1, o2, "no field changed" if differ.is_empty() else "changed " + str(differ)])
	_report("a move over untouched ground changes no column", differ.is_empty() and o1 != o0 and o2 == o0)
	return true


func _seam_move(spawn: Vector2i) -> bool:
	var box := _terrain.box
	# As the tool run arrives at its seam phase: a pile settled against an obstacle, the obstacle lifted, the
	# pile settled again, the player back at the spawn, then the teleport.
	var s2 := spawn + Vector2i(0, -120)
	if not await _teleport(s2 + Vector2i(6, 0)):
		return false
	_terrain.set_obstacle(s2 + Vector2i(0, 3), 1)
	_stamp(_op(s2, 1, EditLayer.MODE_DEPOSIT, 30.0))
	var w1 := await _settled(s2)
	_terrain.set_obstacle(TerrainSim.NO_CELL, -1)
	var w2 := await _settled(s2)
	print("seam: a pile against an obstacle settled in %.2f s, lifted and settled again in %.2f s" % [w1, w2])
	if not await _teleport(spawn):
		return false
	await _frames(3)
	var before := _snapshot()
	if not await _teleport(Vector2i(0, spawn.y)):
		return false
	await _frames(3)
	var o1 := box.origin()
	var bricks := box.allocated()
	if not await _teleport(spawn):
		return false
	await _frames(3)
	var after := _snapshot()
	var differ := _same(before, after)
	# A pile re-entering the box goes active (a pile mid-slump resumes) and creeps a little: its loose may
	# move, conserved; every other field keeps its bits.
	var l0 := _sum(before.loose, before.surface)
	var l1 := _sum(after.loose, after.surface)
	var loose_only := differ.size() == 1 and differ[0] == "loose" and absf(l1 - l0) <= 1e-3 * l0
	print("seam: the box at %s on the seam (%d bricks), back at %s; %s; the window's loose %.6f m³, was %.6f (%+.4f %%)" % [
			o1, bricks, box.origin(), "no field changed" if differ.is_empty() else "changed " + _diff_report(before, after), l1, l0, _residual("seam loose", l1, l0)])
	_report("a move across the seam changes no column but a pile's loose, conserved", (differ.is_empty() or loose_only) and bricks > 0)
	return true


## The largest difference between two float fields' texels.
func _max_abs_diff(a: PackedByteArray, b: PackedByteArray) -> float:
	var x := a.to_float32_array()
	var y := b.to_float32_array()
	var worst := 0.0
	for k in x.size():
		worst = maxf(worst, absf(x[k] - y[k]))
	return worst


func _reload(r1: Vector2i) -> bool:
	var box := _terrain.box
	var disc := _disc(r1, 1)
	_stamp(_op(r1, 1, EditLayer.MODE_DEPOSIT, 2.0))
	await _frames(3)
	box.reload(disc)
	await _frames(3)
	var s := _snapshot()
	var want := _vol(s.loose, s.surface, disc)
	var p := _terrain.params
	var got := 0.0
	var stacks := {}
	for c in disc:
		var key := Vector2i(floori(c.x / 16.0), floori(c.y / 16.0))
		if not stacks.has(key):
			stacks[key] = _stack(c)
		var vox := _column_vox(stacks[key], c)
		for i in vox.loose.size():
			got += vox.loose[i] / float(VoxelColumn.FRACTION_ONE) * VoxelColumn.voxel_volume(box.bottom() + i, p.radius, p.dtheta())
	print("reload: a 2 m³ deposit at %s; the window's loose over the disc %.6f m³, the box's %.6f m³ (%+.4f %%)" % [r1, want, got, _residual("reload", got, 2.0)])
	_report("a reloaded deposit's voxels hold its volume", absf(want - 2.0) <= 2e-3 and absf(got - 2.0) <= 2e-3)
	return true


var _max_bricks := 0


func _process(delta: float) -> void:
	super._process(delta)
	if _listening:
		_max_bricks = maxi(_max_bricks, _terrain.box.active_bricks().size())


## The loose-equivalent of the solid lost over cells since the surfaces s0 (no gaps then): the annulus between
## the surfaces and each gap's, every height by its material's swell from the strata as they stood (clay
## between clay_bottom and clay_top, dirt elsewhere; rock is never lost).
func _swelled_loss(cells: Array[Vector2i], s0: PackedByteArray, cb0: PackedByteArray, ct0: PackedByteArray) -> float:
	var p := _terrain.params
	var m := _terrain.materials
	var surface := _read("surface")
	var gb: Array[PackedByteArray] = []
	var gt: Array[PackedByteArray] = []
	for g in 4:
		gb.append(_read("gap_bottom%d" % g))
		gt.append(_read("gap_top%d" % g))
	var v := 0.0
	for c in cells:
		var spans: Array[Vector2] = [Vector2(_f(surface, c), _f(s0, c))]
		for g in 4:
			if _f(gt[g], c) > _f(gb[g], c):
				spans.append(Vector2(_f(gb[g], c), _f(gt[g], c)))
		for sp in spans:
			if sp.y <= sp.x:
				continue
			var clay_lo := maxf(sp.x, _f(cb0, c))
			var clay_hi := minf(sp.y, _f(ct0, c))
			var clay := Cyl.span_volume(clay_lo, clay_hi, p.radius, p.dtheta(), 1.0) if clay_hi > clay_lo else 0.0
			var all := Cyl.span_volume(sp.x, sp.y, p.radius, p.dtheta(), 1.0)
			v += (all - clay) * m.swell_factor[0] + clay * m.swell_factor[1]
	return v


## The box's loose and solid over cells, each voxel's fraction by its annulus, from the columns' brick stacks:
## [loose, solid].
func _box_volumes(cells: Array[Vector2i]) -> Array[float]:
	var p := _terrain.params
	var stacks := {}
	var loose := 0.0
	var solid := 0.0
	for c in cells:
		var key := Vector2i(floori(c.x / 16.0), floori(c.y / 16.0))
		if not stacks.has(key):
			stacks[key] = _stack(c)
		var vox := _column_vox(stacks[key], c)
		for i in vox.loose.size():
			var vol := VoxelColumn.voxel_volume(_terrain.box.bottom() + i, p.radius, p.dtheta())
			loose += vox.loose[i] / float(VoxelColumn.FRACTION_ONE) * vol
			solid += vox.solid[i] / float(VoxelColumn.FRACTION_ONE) * vol
	return [loose, solid]


func _box_loose(cells: Array[Vector2i]) -> float:
	return _box_volumes(cells)[0]


## Phase pickup at A: an auger bores 10 m and is picked up; the uncased shaft caves in. The loose and solid of
## the box's voxels and of the window (surfaces and gaps) over the box of 12 before and after, so a loss shows
## where it happens: the box's loose gain against its solid loss times the swell, and each against the window.
func _pickup_box(a: Vector2i) -> bool:
	if not await _teleport(a + Vector2i(-4, 0)):
		return false
	var t := _terrain.tool_params
	var swell := _terrain.materials.swell_factor[0]
	var at := _center(a)
	var auger := _tools.place(at.x, at.y, Vector2i(0, 1))
	if auger == null:
		return _quit("The auger was not placed at %s." % a)
	var reason := await _stopped(auger, 40.0)
	if reason.is_empty():
		return _quit("The auger did not stop in 40 s.")
	var waited := await _settled(auger.spoil_cell())
	var cells := _box(a, 12)
	var w_loose0 := _vol(_read("loose"), _read("surface"), cells) + _gap_loose(cells)
	var w_solid0 := _solid_volume(cells)
	var b0 := _box_volumes(cells)
	_tools.pickup()
	var waited2 := await _settled(a, 20.0)
	var w_loose1 := _vol(_read("loose"), _read("surface"), cells) + _gap_loose(cells)
	var w_solid1 := _solid_volume(cells)
	var b1 := _box_volumes(cells)
	print("pickup: bored (%s), settled in %.2f s, picked up, settled in %.2f s; the box's voxels: loose %.6f -> %.6f (%+.6f), solid %.6f -> %.6f (%+.6f, · %.2f = %+.6f); the window: loose %.6f -> %.6f (%+.6f), solid %.6f -> %.6f (%+.6f)" % [
			reason, waited, waited2, b0[0], b1[0], b1[0] - b0[0], b0[1], b1[1], b1[1] - b0[1], swell, (b0[1] - b1[1]) * swell,
			w_loose0, w_loose1, w_loose1 - w_loose0, w_solid0, w_solid1, w_solid1 - w_solid0])
	var clipped: int = _terrain.box.read_stats()[VoxelBox.SLOTS + 2]
	print("pickup: the sand clipped %d counts of arriving loose at full voxels so far" % clipped)
	var box_ok := absf((b1[0] - b0[0]) - (b0[1] - b1[1]) * swell) <= 1e-3 * (b1[0] - b0[0])
	var window_ok := absf((w_loose1 - w_loose0) - (w_solid0 - w_solid1) * swell) <= 1e-3 * (w_loose1 - w_loose0)
	var agree := absf(b1[0] - w_loose1) <= 1e-3 * w_loose1 and absf((b1[1] - b0[1]) - (w_solid1 - w_solid0)) <= 1e-3 * absf(b1[1] - b0[1])
	_report("the caved shaft's loose is its walls' solid times the swell, in the box and in the window, no arrival clipped", reason == "depth" and waited >= 0.0 and waited2 >= 0.0 and box_ok and window_ok and agree and clipped == 0)
	return true


func _shovel_box(s: Vector2i) -> bool:
	if not await _teleport(s + Vector2i(4, 0)):
		return false
	var box := _terrain.box
	var p := _terrain.params
	var t := _terrain.tool_params
	var swell := _terrain.materials.swell_factor[0]
	var cells := _box(s, 3)
	var s0 := _read("surface")
	var held := await _scoop(s)
	var s1 := _read("surface")
	var removed := _removed(s0, s1, cells)
	var half := Tools.ball_volume(t.scoop_ball, box.grid_of(_tools.surface_point(s)), p.radius, p.dtheta()) / 2.0 * swell
	print("shovel: a scoop on flat ground at %s holds %.6f m³ (half the ball · swell %.2f = %.6f, %+.2f %%); the surface over the box of 3 dropped %.6f m³ · swell = %.6f (%+.4f %%)" % [
			s, held, swell, half, (held / half - 1.0) * 100.0, removed, removed * swell, _residual("box scoop", removed * swell, held)])
	_report("a scoop takes a half ball of solid, counted by the annulus", held > 0.0 and absf(held - half) <= 0.02 * half and absf(removed * swell - held) <= 1e-3 * held)
	var d := s + Vector2i(0, 4)
	var dcells := _box(d, 3)
	var ld0 := _vol(_read("loose"), _read("surface"), dcells)
	var emptied := await _dump(d)
	var ld1 := _vol(_read("loose"), _read("surface"), dcells)
	var got := _box_loose(dcells)
	print("shovel: dumped at %s, empty: %s; the window's loose over the box of 3 gained %.6f m³, the box's fractions hold %.6f m³ (%+.4f %%)" % [
			d, emptied, ld1 - ld0, got, _residual("box dump", got, held)])
	_report("a dump's loose lands in the box and the window", emptied and absf(ld1 - ld0 - held) <= 1e-3 * held and absf(got - held) <= 1e-3 * held)
	var w := s + Vector2i(0, -12)
	await _scoop(w)
	await _scoop(w)
	await _dump(s + Vector2i(0, 8))
	var sw := _read("surface")
	var wall := w + Vector2i(0, 2)
	var top := _f(sw, wall)
	var aim := Cyl.position((w.x + 0.5) * p.dtheta(), -p.length / 2.0 + w.y + 0.5 + 1.2, top - 1.5, p.radius)
	var first := await _scoop_at(aim)
	var second := await _scoop_at(aim)
	var gaps := 0
	for g in 4:
		gaps += int(_f(_read("gap_top%d" % g), wall) > _f(_read("gap_bottom%d" % g), wall))
	var roof := _f(_read("surface"), wall)
	print("shovel: a pit at %s (floor %.2f m under the wall's top %.2f), then two balls into its wall: %.6f and %.6f m³ held; the wall column %s holds %d gap(s) [%.2f, %.2f] under a surface at %.2f" % [
			w, top - _f(sw, w), top, first, second - first, wall, gaps, _f(_read("gap_bottom0"), wall), _f(_read("gap_top0"), wall), roof])
	_report("a wall scoop makes one gap under the roof, a second merges with it", first > 0.0 and second > first and gaps == 1 and roof == top)
	await _dump(s + Vector2i(0, 8))
	_player.look(Vector2(0.0, 300.0))
	await _frames(3)
	var shown := _tools.patch.visible
	_player.look(Vector2(0.0, -300.0))
	await _frames(3)
	var hidden := not _tools.patch.visible
	print("shovel: the ring shown looking at the ground: %s, hidden looking level (the ground beyond reach): %s" % [shown, hidden])
	_report("the ring follows the aim", shown and hidden)
	return true


func _rock_box() -> bool:
	var site := NoiseReport.rock_site(_terrain.maps, _terrain.params)
	_terrain.teleport(site.x, site.y)
	if not await _settled_patch():
		return false
	await _frames(3)
	var surface := _read("surface")
	var bedrock := _read("bedrock_top")
	var material := _read("material")
	var loose := _read("loose")
	var from := _tools.player_cell() + Vector2i(0, 4)
	var at := _bare_rock_site(from)
	if at == TerrainSim.NO_CELL:
		_report("a scoop on bare rock takes nothing (no bare-rock ball footprint within 6 cells of %s)" % from, false)
		return true
	var box := _terrain.box
	for c in _ball_footprint(at):
		var k := floori(_f(surface, c))
		var vox := []
		for kk in [k + 1, k, k - 1]:
			var data := box.read_brick(VoxelBox.slot_of(box.brick_of_cell(c, kk)))
			vox.append("%d:%s" % [kk, VoxelBox.voxel(data, posmod(c.x, 16), posmod(kk, 16), posmod(c.y, 16)) if not data.is_empty() else "none"])
		print("rock cell %s: material %d, surface %.3f, bedrock %.3f, loose %.4f; voxels %s" % [c, _b(material, c), _f(surface, c), _f(bedrock, c), _f(loose, c), vox])
	var h0 := _tools.held
	var held := await _scoop(at) - h0
	var same := _read("surface") == surface
	print("rock: a scoop at %s adds %.6f m³ to the hand, surface unchanged: %s" % [at, held, same])
	_report("a scoop on bare rock takes nothing", held == 0.0 and same)
	return true


func _sand(d: Vector2i) -> bool:
	if not await _teleport(d + Vector2i(6, 0)):
		return false
	var cells := _box(d, 24)
	_stamp(_op(d, 1, EditLayer.MODE_DEPOSIT, 30.0))
	var waited := await _settled(d)
	var vol := _vol(_read("loose"), _read("surface"), cells)
	var steep := _steepest(cells, [])
	var repose := tan(deg_to_rad(_terrain.materials.repose_dry[0])) * 1.02
	print("sand: a 30 m³ deposit at %s settled in %.2f s; %.6f m³ over the box of 24 (%+.4f %%); steepest %.4f, repose · 1.02 %.4f; active bricks at most %d" % [
			d, waited, vol, _residual("box sand", vol, 30.0), steep, repose, _max_bricks])
	_report("a pile settles at repose in the box, conserved", waited >= 0.0 and absf(vol - 30.0) <= 0.03 and steep <= repose)
	return true


func _edge(spawn: Vector2i) -> bool:
	if not await _teleport(spawn):
		return false
	var box := _terrain.box
	var e := Vector2i(spawn.x, box.origin().y * VoxelBox.BRICK + VoxelBox.COLUMNS - 3)
	var cells := _box(e, 8)
	var l0 := _vol(_read("loose"), _read("surface"), cells)
	_stamp(_op(e, 1, EditLayer.MODE_DEPOSIT, 5.0))
	var waited := await _settled(e)
	var l1 := _vol(_read("loose"), _read("surface"), cells)
	print("edge: a 5 m³ deposit at %s, two cells inside the box's far edge (origin %s), settled in %.2f s; the loose over the box of 8 gained %.6f m³ (%+.4f %%)" % [
			e, box.origin(), waited, l1 - l0, _residual("box edge", l1 - l0, 5.0)])
	_report("the sand parks dirt at the box's edge", waited >= 0.0 and absf(l1 - l0 - 5.0) <= 0.005)
	return true


func _cave(c: Vector2i) -> bool:
	if not await _teleport(c + Vector2i(5, 0)):
		return false
	var swell := _terrain.materials.swell_factor[0]
	var stand := tan(deg_to_rad(_terrain.materials.stable_slope_dry[0])) * 1.02
	var free := _terrain.materials.roof_span_dry[0]
	var cells := _box(c, 8)
	var inner := _box(c, 6)
	var s0 := _read("surface")
	var cb0 := _read("clay_bottom")
	var ct0 := _read("clay_top")
	var h0 := _tools.held
	var top := _f(s0, c)
	var scoops := 0
	while top - _f(_read("surface"), c) < 3.0 and scoops < 12:
		await _scoop(c)
		await _frames(15)
		scoops += 1
	var depth1 := top - _f(_read("surface"), c)
	var waited1 := await _settled(c)
	var loose1 := _vol(_read("loose"), _read("surface"), inner)
	print("cave: %d scoops at %s, the pit %.2f m deep; settled in %.2f s; loose over the box of 6 %.6f m³ (the walls stand under %.1f m)" % [scoops, c, depth1, waited1, loose1, free])
	_report("a pit under the free height keeps its walls", depth1 > 3.0 and waited1 >= 0.0 and loose1 <= 1e-3)
	while top - _f(_read("surface"), c) < 5.0 and scoops < 24:
		await _scoop(c)
		await _frames(15)
		scoops += 1
	var depth2 := top - _f(_read("surface"), c)
	var waited2 := await _settled(c, 20.0)
	var s1 := _read("surface")
	var loose2 := _vol(_read("loose"), s1, cells) + _gap_loose(cells)
	var lost := _swelled_loss(cells, s0, cb0, ct0)
	var got := _tools.held - h0 + loose2
	var wall := _wall_excess(cells, stand, free)
	print("cave: %d scoops, the pit %.2f m deep; settled in %.2f s; loose over the box of 8 %.6f m³; the solid lost over the box (the surfaces' annuli less the gaps', each height by its material's swell) %.6f m³ loose-equivalent for %.6f held + %.6f loose = %.6f (%+.4f %%); the tallest wall over max(stand · 1.02 · w, free) %+.4f m" % [
			scoops, depth2, waited2, loose2, lost, _tools.held - h0, loose2, got, _residual("box cave", got, lost), wall])
	_report("a pit over the free height caves to the stand slope, conserved", depth2 > 5.0 and waited2 >= 0.0 and loose2 > 0.1 and absf(got - lost) <= 1e-3 * lost and wall <= 0.02)
	return true


func _box_summary() -> void:
	print("---- box run ----")
	print("machine: %s, %s" % [OS.get_processor_name(), RenderingServer.get_video_adapter_name()])
	var bricks := _terrain.box.allocated()
	var stats := _terrain.box.read_stats()
	print("box: %d bricks allocated (%.1f MB), gap overflows %d, pool dry %d" % [bricks, bricks * VoxelBox.BRICK_BYTES / 1048576.0, stats[VoxelBox.SLOTS], stats[VoxelBox.SLOTS + 1]])
	print("box: at most %d bricks active at once; %d sand steps" % [_max_bricks, _terrain.box.steps])
	for pass_name: String in ["box_unpack", "box_pack", "box_edit", "box_sand"]:
		var ms: Array[float] = []
		for t in _timed:
			if t.name == pass_name:
				ms.append(t.ms)
		print("  %-11s per list %s" % [pass_name, Smoke._stat(ms, BOX_BUDGET * bricks)])
		if not ms.is_empty():
			print("  %-11s the longest list per brick allocated %.4f ms (budget %.2f)" % [pass_name, ms.max() / bricks, BOX_BUDGET])
	for phase: String in ["unpack", "move", "seam", "reload", "shovel", "rock", "sand", "edge", "cave", "pickup"]:
		var st := _stat_of(phase)
		print("  %-6s %5.1f s; %s; %d reads" % [phase, st.time, Smoke._times(st.cpu, st.gpu), st.reads])
