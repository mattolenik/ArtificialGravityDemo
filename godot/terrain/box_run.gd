## Windowed check of the voxel box (the tunnels plan), on the tool run's world copy and with its helpers
## (this script extends tool_run.gd and routes its own phases). Phases:
## unpack: with the box live around the spawn, every window field is read, the box packed (pack_all_sync) and
##    every field read again: bit for bit equal (no column was dirty, so none was written); the brick stack
##    under the spawn is read back and each of its 256 columns, packed on the CPU by VoxelColumn.pack from the
##    GPU's voxels, gives the window's surface within 1e-4 m with no gap, and the GPU's voxels equal
##    VoxelColumn.unpack of the window's column (solid exactly, loose within one fraction step).
## move: the player teleported 100 m along z and back (the box moves six or seven bricks each way): every
##    window field bit for bit as before, the box's origin having changed and come back.
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
	_phase = "reload"
	if not await _reload(spawn + Vector2i(0, 40)):
		return
	_phase = "shovel"
	if not await _shovel_box(spawn + Vector2i(0, 80)):
		return
	_phase = "rock"
	if not await _rock_box():
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


## The box's loose over cells, each voxel's fraction by its annulus, from the columns' brick stacks.
func _box_loose(cells: Array[Vector2i]) -> float:
	var p := _terrain.params
	var stacks := {}
	var got := 0.0
	for c in cells:
		var key := Vector2i(floori(c.x / 16.0), floori(c.y / 16.0))
		if not stacks.has(key):
			stacks[key] = _stack(c)
		var vox := _column_vox(stacks[key], c)
		for i in vox.loose.size():
			got += vox.loose[i] / float(VoxelColumn.FRACTION_ONE) * VoxelColumn.voxel_volume(_terrain.box.bottom() + i, p.radius, p.dtheta())
	return got


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
	var held := await _scoop(at)
	var same := _read("surface") == surface
	print("rock: a scoop at %s holds %.6f m³, surface unchanged: %s" % [at, held, same])
	_report("a scoop on bare rock takes nothing", held == 0.0 and same)
	return true


func _box_summary() -> void:
	print("---- box run ----")
	print("machine: %s, %s" % [OS.get_processor_name(), RenderingServer.get_video_adapter_name()])
	var bricks := _terrain.box.allocated()
	var stats := _terrain.box.read_stats()
	print("box: %d bricks allocated (%.1f MB), gap overflows %d, pool dry %d" % [bricks, bricks * VoxelBox.BRICK_BYTES / 1048576.0, stats[VoxelBox.SLOTS], stats[VoxelBox.SLOTS + 1]])
	for pass_name: String in ["box_unpack", "box_pack", "box_edit"]:
		var ms: Array[float] = []
		for t in _timed:
			if t.name == pass_name:
				ms.append(t.ms)
		print("  %-11s per list %s" % [pass_name, Smoke._stat(ms, BOX_BUDGET * bricks)])
		if not ms.is_empty():
			print("  %-11s the longest list per brick allocated %.4f ms (budget %.2f)" % [pass_name, ms.max() / bricks, BOX_BUDGET])
	for phase: String in ["unpack", "move", "reload", "shovel", "rock"]:
		var st := _stat_of(phase)
		print("  %-6s %5.1f s; %s; %d reads" % [phase, st.time, Smoke._times(st.cpu, st.gpu), st.reads])
