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
	var vox := {"solid": PackedInt32Array(), "loose": PackedInt32Array(), "material": PackedByteArray(), "compaction": PackedByteArray()}
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


func _box_summary() -> void:
	print("---- box run ----")
	print("machine: %s, %s" % [OS.get_processor_name(), RenderingServer.get_video_adapter_name()])
	var bricks := _terrain.box.allocated()
	var stats := _terrain.box.read_stats()
	print("box: %d bricks allocated (%.1f MB), gap overflows %d, pool dry %d" % [bricks, bricks * VoxelBox.BRICK_BYTES / 1048576.0, stats[VoxelBox.SLOTS], stats[VoxelBox.SLOTS + 1]])
	for pass_name: String in ["box_unpack", "box_pack"]:
		var ms: Array[float] = []
		for t in _timed:
			if t.name == pass_name:
				ms.append(t.ms)
		print("  %-11s per list %s" % [pass_name, Smoke._stat(ms, BOX_BUDGET * bricks)])
		if not ms.is_empty():
			print("  %-11s the longest list per brick allocated %.4f ms (budget %.2f)" % [pass_name, ms.max() / bricks, BOX_BUDGET])
	for phase: String in ["unpack", "move", "reload"]:
		var st := _stat_of(phase)
		print("  %-6s %5.1f s; %s; %d reads" % [phase, st.time, Smoke._times(st.cpu, st.gpu), st.reads])
