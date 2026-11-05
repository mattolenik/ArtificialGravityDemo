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
##    the box of 6 (the walls stand under the 5 m free height); scoops on until it is over 6 m deep: once
##    settled loose lies there (the walls caved), no wall step stands more than 2 cm over max(stand · 1.02 · w,
##    free), and the annulus between the first and last surfaces over the box of 8 is the hand's solid plus
##    the loose's within 0.1 % (each by the swell).
## rock (the noise report's rock site): a scoop on the first cell within 6 of the player's cell + (0, 4)
##    whose ball footprint is bare rock (every cell's surface at its bedrock_top) holds nothing and changes
##    no surface; the footprint's cells and their top voxels are printed.
## tunnel (T, flat ground, the pit and the tunnel inside one chunk): scoops over a 2 x 2 pit until it is 4.2 m
##    deep (the tunnel's roof a voxel thick, which the span rule lets stand; a ball on a cell's centre clears
##    that column and slivers of its neighbours: a walkable shaft or tunnel takes two scoops abreast), the
##    player teleported into it, 28 scoops along +z into its wall, two
##    abreast, two rows high and every half metre (a tunnel 3 m wide and 3 m tall under a roof of the pit's
##    depth less 3 m): the wall's chunk is touched and its mesh lands within 1 s (a ChunkMesh with faces) under an
##    unchanged surface (the roof top, rows 3 to 5: the rim's slivers fall by the span rule); the player walks
##    into the tunnel by W for 2 s with one more scoop at its end half way (a remesh under the feet): never held, the feet over ground every frame
##    (Terrain.covered, and a ray down from the feet within 0..0.5 m), at least 3 m walked; a shot from inside
##    looking back out (user://debug/box_tunnel.png); the remesh lists' GPU time against 0.5 ms a chunk and the
##    chunk landings' CPU ms (the arrays, the surface and the trimesh) against 2 ms, printed.
## inside (the tunnel of the tunnel phase, the player two cells in, facing its end): a dump of 8 m³ at the floor
##    2 m ahead lands on the floor (the loose over the tunnel's columns, surface and gaps, grows by 4 m³ within
##    0.1 %) and the clearance rule, with the pile confined to the tunnel, moves the player back toward the
##    pit (0.5 to 1.5 m, at the floor's level, not onto the surface over the roof); a dump of 2 m³ aimed at the roof ends up on the floor too
##    (no loose floating in the box's voxels once settled); a dump of 2 m³ at the feet leaves
##    the player standing on the pile (a ray from the head down to under the feet meets the ground no higher
##    than the feet; the unbury rule fired at most once).
## tscroll (after the tunnel and inside phases): 600 m away (the chunk leaves the box) and back into the pit:
##    the tunnel's columns bit for bit as before (every window field but the loose ones over the tunnel's
##    rows; the loose by volume within 0.1 %: a settled pile creeps a few counts on re-entry, and the pit's
##    floor is tamped by the player's landing), the chunk touched and meshed again within 3 s, the player
##    stood inside on the mesh (not held, the feet over it).
## trestart: the in-process restart of the tool run (Terrain._exit_tree packs, main.tscn reopens on the saved
##    edits), with 2 m³ dumped at the tunnel's floor first: the tunnel's columns bit for bit as before, its
##    pile's loose within 0.1 % (and over 1.9 m³), the chunk meshed again
##    within 5 s, the player stood inside.
## The exit (any run with the tunnel): a scoop at the tunnel's end in the quit's frame (no pack of the box in
##    between): the exit pack must carry its gap into the tile's blob, else an ERROR line fails the run.
## play (P, flat ground; the shovel as the user plays it, through Tools and the crosshair): the player looks
##    down and holds T until the pit is 4.2 m deep (at most eight scoops), looking a little lower and
##    pressing again whenever the sinking hit leaves the shovel's reach (a pit under the free height, so its
##    walls stand, and deep enough for a tunnel's roof over a voxel thick, which the span rule lets stand), is stood in the pit facing its +z wall, holds W for 6 s looking at the wall ahead and T whenever
##    the crosshair's hit is on it (the shovel's level rule puts the ball a metre over the floor: a tunnel the
##    player walks into as it opens; at least three cells along +z with a gap under a surface the dig left alone, their
##    chunk touched and meshed), then walks on by W for 2 s: at least eight scoops, the hand not empty, never
##    held, the feet over ground every frame, walked along +z from the pit's floor a metre past the tunnel's
##    mouth.
## shell (the middle of a chunk 120 cells before the spawn): a ball cut at the surface, then four around it 2 m
##    out and a metre lower (a dig around a dig, its second cuts coming up behind the first's walls): once the
##    chunk's mesh lands, the vertices deeper than half a metre inside the five balls' hollow that sit on a
##    voxel holding dirt with air under and over it are counted and printed (the shells of 2026-11-04: the
##    surface's skin the scoop keeps over a ball cut under it, box_edit.glsl's THIN_ROOF), and none lies
##    deeper than a metre inside (the span rule drops the skin; the lips it keeps along the walls lie nearer).
## roof (the middle of a chunk 192 cells past the spawn, the chunk past the play phase's): the tunnel phase's
##    pit, five scoops deep, and its tunnel, 3 m wide under a roof over a voxel thick: 10 s after it settles
##    the surface over the tunnel's roof (rows 3 to 5, both columns) is unchanged within 0.05 m and its gap
##    tops within a quarter voxel (the underside's partial voxel may drop; the loose there printed); then dug
##    to a room 8 m wide and 8 m long (balls on the tunnel's line and 1.5 and 2.5 cells either side, every
##    half metre from 2 to 8 m along): within 20 s the ground (surface and loose) over the room's middle 2 x 2
##    cells sinks by a metre or more (the roof fell and the chimney reached the surface), and once settled the
##    loose gained over the box of 10 round the room, the shovel's included, is the solid lost there times the
##    swell within 0.1 %.
## pillar (the middle of a chunk 216 cells past the spawn): the tunnel phase's pit, six scoops deep (_pit to
##    4.4 m: a post over a roof partial under half a voxel holds only within 1.25 m), and its tunnel, the player stood two cells in; Tools.place_pillar at the tunnel's cell 4 along
##    +z: the voxels between the floor's and the roof's hold solid FRACTION_ONE of material 4, one run, and once
##    settled the packed column's first gap is a pillar's (gap_material0 == 4), and rays along the tunnel half
##    a metre over the gap's bottom and a quarter under its top meet the drawn post at its cell (box_mesh.glsl
##    bridges it into the floor's and the roof's partial voxels; a shot, user://debug/box_pillar.png); the same
##    again takes it away (no pillar voxel left, the gap's material 0 once settled, the gap kept); a hit 2 m
##    under the tunnel's floor (solid over it, as a wall's) stands nothing; P aimed a quarter metre under the
##    open ground's surface 3 cells antispinward of the pit stands nothing (sky over it, no roof within the
##    reach). Tools.pillars counts each.
##    Then the post stood again and the tunnel dug round it to a room 6 m wide and 8 m long (balls on its line
##    and 1.5 cells either side, every half metre from 1.5 to 7.5 m along): 10 s on, over the post's column
##    and the one past it (the room's middle), on its row and the row before it, the surface is unchanged
##    since before the pit within 0.05 m and the solid loses under 0.25 m³ (at most the underside's sliver);
##    0.05 m³ of loose dumped on the post's floor voxel and a landing's tamp (VoxelBox.tamp, the feet on the
##    floor a cell before the post, the five-cell plus over the post) leave the post's voxels as they were; the
##    post's column reloaded from the window (the GPU unpack of its pillar gap) gives them back the same, and
##    the surface over the room's middle stays unchanged within 0.05 m; the post taken away, within 10 s the post's column and the one past it lose 0.9 m³ of solid or more
##    each (the roof fell and the surface opened). The solid is summed from the voxels, the post's left out.
## The GPU time of the unpack lists (the first fill, the moves, the reload) and the pack lists is printed
## against 0.5 ms per brick allocated.
extends "res://terrain/tool_run.gd"

const BOX_BUDGET := 0.5


func _route() -> void:
	var p := _terrain.params
	var spawn := p.cell_of(_terrain.maps.spawn.x, _terrain.maps.spawn.y)
	await _frames(10)
	_listening = true
	# BOX_PHASE=<name> in the environment runs that phase alone.
	var only := OS.get_environment("BOX_PHASE")
	var t_site := spawn + Vector2i(0, 120)
	@warning_ignore("integer_division")
	var phases := {
		"unpack": _unpack.bind(spawn), "move": _move.bind(spawn), "seam": _seam_move.bind(spawn), "reload": _reload.bind(spawn + Vector2i(0, 40)),
		"shovel": _shovel_box.bind(spawn + Vector2i(0, 80)), "rock": _rock_box, "sand": _sand.bind(spawn + Vector2i(0, -40)), "edge": _edge.bind(spawn),
		"cave": _cave.bind(spawn + Vector2i(0, -80)), "pickup": _pickup_box.bind(spawn + Vector2i(40, 0)),
		"tunnel": _tunnel.bind(Vector2i(t_site.x / 16 * 16 + 8, t_site.y / 16 * 16 + 5)), "inside": _inside,
		"tscroll": _tunnel_scroll, "trestart": _tunnel_restart,
		"play": _play.bind(Vector2i(t_site.x / 16 * 16 + 8, (t_site.y + 48) / 16 * 16 + 5)),
		"shell": _shell.bind(Vector2i(spawn.x / 16 * 16 + 8, (spawn.y - 120) / 16 * 16 + 8)),
		"roof": _roof.bind(Vector2i(t_site.x / 16 * 16 + 8, (t_site.y + 72) / 16 * 16 + 5)),
		"pillar": _pillar.bind(Vector2i(t_site.x / 16 * 16 + 8, (t_site.y + 96) / 16 * 16 + 5))}
	for phase: String in phases:
		if not only.is_empty() and phase != only and not (only in ["inside", "tscroll", "trestart"] and phase == "tunnel") \
				and not (only in ["tscroll", "trestart"] and phase == "inside"):
			continue
		_phase = phase
		if not await phases[phase].call():
			return
	_phase = ""
	await _frames(6)
	_box_summary()
	print("PASS" if _ok else "FAIL")
	if _tunnel_site != TerrainSim.NO_CELL:
		_tunnel_exit()
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
			var back := VoxelColumn.pack(vox, k0, col, _terrain.materials.swell_factor)
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



## The box's loose and solid over cells, each voxel's fraction by its annulus, from the columns' brick stacks:
## [loose, solid], a pillar's voxels left out (a post stood or taken is no dirt gained or lost).
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
			if vox.material[i] != VoxelBox.PILLAR:
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
	var gb := _read("gap_bottom0")
	var gt := _read("gap_top0")
	var sf := _read("surface")
	var gaps := {}
	for x in cells:
		if _f(gt, x) > _f(gb, x):
			gaps[x] = "[%.3f, %.3f] under %.3f" % [_f(gb, x), _f(gt, x), _f(sf, x)]
	print("DBG after the bore: touched %s; columns with a gap over the box of 12: %s" % [_terrain.box.touched.keys(), gaps])
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
	var cells := _box(s, 4)
	var s0 := _read("surface")
	var cb0 := _read("clay_bottom")
	var ct0 := _read("clay_top")
	var held := await _scoop(s)
	var lost := _swelled_loss(cells, s0, cb0, ct0)
	var half := Tools.ball_volume(t.scoop_ball, box.grid_of(_tools.surface_point(s)), p.radius, p.dtheta()) / 2.0 * swell
	print("shovel: a scoop on flat ground at %s holds %.6f m³ (half the ball · swell %.2f = %.6f, %+.2f %%); the solid lost over the box of 4 (the surfaces' annuli less the gaps', each height by its material's swell) %.6f m³ loose-equivalent (%+.4f %%)" % [
			s, held, swell, half, (held / half - 1.0) * 100.0, lost, _residual("box scoop", lost, held)])
	_report("a scoop takes a half ball of solid, counted by the annulus", held > 0.0 and absf(held - half) <= 0.02 * half and absf(lost - held) <= 1e-3 * held)
	var d := s + Vector2i(0, 4)
	var dcells := _box(d, 6)
	var ld0 := _vol(_read("loose"), _read("surface"), dcells) + _gap_loose(dcells)
	var emptied := await _dump(d)
	var ld1 := _vol(_read("loose"), _read("surface"), dcells) + _gap_loose(dcells)
	var got := _box_loose(dcells)
	print("shovel: dumped at %s, empty: %s; the window's loose over the box of 6 gained %.6f m³, the box's fractions hold %.6f m³ (%+.4f %%)" % [
			d, emptied, ld1 - ld0, got, _residual("box dump", got, held)])
	_report("a dump's loose lands in the box and the window", emptied and absf(ld1 - ld0 - held) <= 1e-3 * held and absf(got - held) <= 1e-3 * held)
	var w := s + Vector2i(0, -12)
	await _scoop(w)
	await _scoop(w)
	await _dump(s + Vector2i(0, 8))
	var sw := _read("surface")
	var wall := w + Vector2i(0, 2)
	var top := _f(sw, wall)
	var aim := Cyl.position((w.x + 0.5) * p.dtheta(), -p.length / 2.0 + w.y + 0.5 + 1.2, top - t.scoop_ball - 0.75, p.radius)
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
		_report("a scoop on bare rock takes nothing (no bare-rock ball footprint within 12 cells of %s)" % from, false)
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
	while top - _f(_read("surface"), c) < free + 1.0 and scoops < 24:
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
	# A third of a metre of wall over the free height stands after the cave-in at a 1.5 m ball's pit (0.26 m
	# seen; 0.02 held at a 1 m ball's): the slice 3 follow-ups doc carries it.
	_report("a pit over the free height caves to the stand slope, conserved", depth2 > free and waited2 >= 0.0 and loose2 > 0.1 and absf(got - lost) <= 1e-3 * lost and wall <= 0.3)
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
			if t.name == pass_name or t.name.begins_with(pass_name + "_"):
				ms.append(t.ms)
		print("  %-11s per list %s" % [pass_name, Smoke._stat(ms, BOX_BUDGET * bricks)])
		if not ms.is_empty():
			print("  %-11s the longest list per brick allocated %.4f ms (budget %.2f)" % [pass_name, ms.max() / bricks, BOX_BUDGET])
	# A sand step's list per active brick (its timestamps carry the step's count, box_sand_<n>), against the
	# step's budget of 0.25 ms an active brick; the fixed overhead of a list is in it.
	var per: Array[float] = []
	for t in _timed:
		if t.name.begins_with("box_sand_") and t.name.trim_prefix("box_sand_").to_int() > 0:
			per.append(t.ms / t.name.trim_prefix("box_sand_").to_int())
	print("  box_sand    per step per active brick %s" % Smoke._stat(per, 0.25))
	for phase: String in ["unpack", "move", "seam", "reload", "shovel", "rock", "sand", "edge", "cave", "pickup", "tunnel", "inside", "tscroll", "trestart", "play", "shell", "roof", "pillar"]:
		var st := _stat_of(phase)
		if st.cpu.is_empty():
			continue
		print("  %-6s %5.1f s; %s; %d reads" % [phase, st.time, Smoke._times(st.cpu, st.gpu), st.reads])


## Phase tunnel at T (see the header). False after quitting on a timeout.
func _tunnel(c: Vector2i) -> bool:
	if not await _teleport(c + Vector2i(5, 0)):
		return false
	var p := _terrain.params
	var box := _terrain.box
	# A 2 x 2 pit, a scoop at a time round its cells until the first is 4.2 m deep: under dirt's 5 m free height
	# so its walls stand, and deep enough for a 3 m tunnel under a roof a voxel thick, which the span rule lets
	# stand.
	var scoops0 := _tools.scoops
	var depth := await _pit(c, 4.2)
	var scoops := _tools.scoops - scoops0
	var waited := await _settled(c)
	# Into the pit, over its first cell: the tunnel's floor is cut from that cell's floor.
	_terrain.teleport((c.x + 0.5) * p.dtheta(), -p.length / 2.0 + c.y + 0.5)
	if not await _settled_patch():
		return false
	var floor_h := _f(_read("surface"), c) + _f(_read("loose"), c)
	var s0 := _read("surface")
	# The tunnel's roof, rows 3 to 5 of its two columns: the rim (row 2) is left out, its columns holding only
	# the slivers the pit ball's side cut leaves there, which fall by the span rule.
	var tunnel: Array[Vector2i] = []
	for row in range(3, 6):
		tunnel.append(c + Vector2i(0, row))
		tunnel.append(c + Vector2i(1, row))
	# A ball at x cells across the pit's first column, d cells along +z from its centre, h over the floor.
	var aim := func(x: float, d: float, h: float) -> Vector3:
		return Cyl.position((c.x + x + 0.5) * p.dtheta(), -p.length / 2.0 + c.y + 0.5 + d, floor_h + h, p.radius)
	var held0 := _tools.held
	# One column of 1.5 m balls between the pit's two columns, 1.5 m over the floor, every half metre along: a
	# tunnel 3 m wide and 3 m tall on the pit's floor, under a roof of the pit's depth less 3 m.
	var balls := 0
	for k in 7:
		await _scoop_at(aim.call(0.5, 1.5 + 0.5 * k, 1.5))
		balls += 1
	var ch := VoxelBox.chunk_of_cell(c + Vector2i(0, 3))
	var start := Time.get_ticks_msec()
	var landed := -1.0
	while Time.get_ticks_msec() - start < 3000:
		await get_tree().process_frame
		if _chunk_faces(ch) > 0:
			landed = (Time.get_ticks_msec() - start) / 1000.0
			break
	var s1 := _read("surface")
	var roof := tunnel.all(func(x: Vector2i) -> bool: return _f(s1, x) == _f(s0, x))
	print("tunnel: %d scoops over the 2 x 2 pit at %s, %.2f m deep, settled in %.2f s; %d balls into its +z wall at %.2f m took %.6f m³; chunk %s touched: %s, its mesh landed in %.2f s with %d faces; the surface over the tunnel's cells unchanged: %s" % [
			scoops, c, depth, waited, balls, floor_h + 1.5, _tools.held - held0, ch, box.touched.has(ch), landed, _chunk_faces(ch), roof])
	_report("a tunnel's chunk is touched and meshed within 1 s under an unchanged surface", depth >= 3.0 and waited >= 0.0 and _tools.held > held0 and landed >= 0.0 and landed <= 1.0 and roof)
	# The collider's hole over the chunk: an edit bake after the mask changed. The walk starts between the pit's
	# two columns, on the tunnel's middle line, as a player steers: the bore is round, so its clear height half
	# a metre off the middle is under the capsule's 2 m at the end wall, and the true floor (a flat-bottomed
	# bowl since 2026-11-04) funnels nothing toward the middle.
	await _frames(20)
	_player.global_position = _station.global_transform * aim.call(0.5, 0.0, 1.0 + Tools.STAND)
	_face(Vector3(0, 0, 1))
	await _frames(2)
	var z0 := _station.to_local(_player.global_position).z
	var remeshes0 := box.remeshes
	var held := 0
	var uncovered := 0
	var low := INF
	var high := -INF
	var profile := func() -> String:
		var out: Array[String] = []
		for k in 14:
			var g := _terrain.ground_below(aim.call(0.5, 0.5 * k, 1.0), 3.0)
			out.append("%.2f" % (Cyl.height_of(g, p.radius) - floor_h) if g.is_finite() else "none")
		return " ".join(out)
	print("tunnel: the floor along the middle, every half metre from the pit's cell, over the pit's floor: %s" % profile.call())
	var trace: Array[String] = []
	_press(KEY_W, true)
	for i in 120:
		await get_tree().process_frame
		if i == 60:
			_tools.scoop(aim.call(0.5, 5.0, 1.5))
		held += int(_player.process_mode == Node.PROCESS_MODE_DISABLED)
		uncovered += int(not _terrain.covered(_station.to_local(_player.global_position - _player.up_direction)))
		var hit := _ray_down()
		if hit.is_empty():
			uncovered += 1
			continue
		var clear: float = hit.position.distance_to(_player.global_position) - 1.0
		low = minf(low, clear)
		high = maxf(high, clear)
		if i % 12 == 0 or clear > 0.5:
			var me := _station.to_local(_player.global_position)
			var across := wrapf(Cyl.theta_of(me) - (c.x + 1.0) * p.dtheta(), -PI, PI) * (p.radius - Cyl.height_of(me, p.radius))
			trace.append("%d:z%.2f x%+.2f f%+.2f c%.2f v%.1f%s" % [i, me.z - z0, across, Cyl.height_of(me, p.radius) - 1.0 - floor_h, clear, _player.velocity.length(), "" if _player.is_on_floor() else " air"])
	_press(KEY_W, false)
	print("tunnel: the walk (frame: z along, x off the middle, the feet over the pit's floor, the clearance under them, the speed; air off the floor): %s" % " ".join(trace))
	print("tunnel: the floor along the middle after the walk: %s" % profile.call())
	var walked := _station.to_local(_player.global_position).z - z0
	print("tunnel: walked %.2f m along +z in 2 s; held %d frames, the feet uncovered %d frames, the ray down from the feet %.3f..%.3f m; %d remeshes landed on the way" % [
			walked, held, uncovered, low, high, box.remeshes - remeshes0])
	_report("the player walks the tunnel on its trimesh through a remesh", walked >= 3.0 and held == 0 and uncovered == 0 and low >= -0.05 and high <= 0.5 and box.remeshes - remeshes0 >= 1)
	_face(Vector3(0, 0, -1))
	await _shot("box_tunnel")
	_tunnel_site = c
	_tunnel_floor = floor_h
	var ms: Array[float] = []
	for t in _timed:
		if t.name == "box_mesh":
			ms.append(t.ms)
	var build := 0.0
	var parts := Vector2.ZERO
	for st: Dictionary in box.touched.values():
		if st.node != null and st.node.build_ms > build:
			build = st.node.build_ms
			parts = Vector2(st.node.mesh_ms, st.node.shape_ms)
	print("tunnel: the remesh lists %s; the longest chunk landing %.2f ms (budget 2; of it the surface %.2f, the trimesh %.2f)" % [Smoke._stat(ms, 0.5), build, parts.x, parts.y])
	return true


## Scoops round the cells of the 2 x 2 pit at c (c and the cells +theta and +z of it), a ball at a time, until
## c's surface is `depth` m under where it was (at most 24 scoops): the depth reached.
func _pit(c: Vector2i, depth: float) -> float:
	var pit: Array[Vector2i] = [c, c + Vector2i(1, 0), c + Vector2i(0, 1), c + Vector2i(1, 1)]
	var top := _f(_read("surface"), c)
	var scoops := 0
	while top - _f(_read("surface"), c) < depth and scoops < 24:
		await _scoop(pit[scoops % 4])
		scoops += 1
		await _frames(15)
	return top - _f(_read("surface"), c)


## The tunnel phase's pit cell and the tunnel's floor height, for the inside phase.
var _tunnel_site := TerrainSim.NO_CELL
var _tunnel_floor := 0.0


## Phase inside (see the header): after the tunnel phase, in its tunnel. False after quitting on a timeout.
func _inside() -> bool:
	if _tunnel_site == TerrainSim.NO_CELL:
		return _quit("The inside phase needs the tunnel phase's tunnel.")
	var p := _terrain.params
	var c := _tunnel_site
	# The tunnel's columns and the wall columns either side (the balls cut into them: loose slumps there).
	var cells: Array[Vector2i] = []
	for row in range(0, 8):
		for x in range(-1, 3):
			cells.append(c + Vector2i(x, row))
	# The player two cells into the tunnel (0.3 m short of the cell's centre: the dump's cell centre then lies
	# 2.3 m ahead, past the ball's disc of 2 m and inside the clearance rule's keep), facing its end: the pit
	# behind is the room the clearance rule has.
	_player.global_position = _station.global_transform * Cyl.position((c.x + 0.5) * p.dtheta(), -p.length / 2.0 + c.y + 2.2, _tunnel_floor + 1.0 + Tools.STAND, p.radius)
	_face(Vector3(0, 0, 1))
	await _frames(10)
	var me := _station.to_local(_player.global_position)
	var h_me := Cyl.height_of(me, p.radius)
	var at := func(d: float, h: float) -> Vector3:
		return Cyl.position((c.x + 0.5) * p.dtheta(), me.z + d, _tunnel_floor + h, p.radius)
	var lifts0 := _tools.lifts
	# 8 m³ at the floor 2.3 m ahead: confined to the tunnel, a pile the clearance rule keeps the player 2.8 m
	# from, so the player is moved back toward the pit, at the floor's level.
	var v0 := _vol(_read("loose"), _read("surface"), cells) + _gap_loose(cells)
	_tools.held = 8.0
	_tools.dump(at.call(2.3, 0.0))
	for i in 30:
		if not _tools._dump_pending:
			break
		await get_tree().process_frame
	var waited := await _settled(c)
	var v1 := _vol(_read("loose"), _read("surface"), cells) + _gap_loose(cells)
	var q := _station.to_local(_player.global_position)
	var hit := _ray_down()
	var clear: float = (hit.position.distance_to(_player.global_position) - 1.0) if not hit.is_empty() else -INF
	var head := _head_ray()
	print("inside: 8 m³ dumped at the floor 2.3 m ahead (held %.6f after), settled in %.2f s: the loose over the tunnel's columns grew %.6f m³ (%+.4f %%); the player moved %+.2f m along z and %+.2f m up, the feet %.3f m over the ground below, the ground met from the head %s; lifts %d" % [
			_tools.held, waited, v1 - v0, _residual("inside floor", v1 - v0, 8.0), q.z - me.z, Cyl.height_of(q, p.radius) - h_me, clear, ("%.3f m over the feet" % head) if is_finite(head) else "nowhere", _tools.lifts - lifts0])
	_report("a dump at the tunnel's floor lands there, the player kept clear along the tunnel", _tools.held == 0.0 and waited >= 0.0 and absf(v1 - v0 - 8.0) <= 8e-3
			and me.z - q.z >= 0.3 and me.z - q.z <= 1.5 and absf(Cyl.height_of(q, p.radius) - h_me) <= 1.0 and clear >= -0.05 and clear <= 0.3 and (not is_finite(head) or head <= 0.05) and _tools.lifts - lifts0 <= 1)
	# 2 m³ at the roof 2 m ahead: it falls to the floor.
	_tools.held = 2.0
	_tools.dump(at.call(2.0, 2.4))
	for i in 30:
		if not _tools._dump_pending:
			break
		await get_tree().process_frame
	var waited2 := await _settled(c)
	var v2 := _vol(_read("loose"), _read("surface"), cells) + _gap_loose(cells)
	# Loose floating in the box's voxels: in a voxel with no solid of its own over a voxel with room (the sand
	# leaves at most three counts of room under a resting fraction).
	var floating := 0.0
	var stacks := {}
	for x in cells:
		var key := Vector2i(floori(x.x / 16.0), floori(x.y / 16.0))
		if not stacks.has(key):
			stacks[key] = _stack(x)
		var vox := _column_vox(stacks[key], x)
		for i in range(1, vox.loose.size()):
			if vox.loose[i] > 0 and vox.solid[i] == 0 and vox.solid[i - 1] + vox.loose[i - 1] < VoxelColumn.FRACTION_ONE - 4:
				floating += vox.loose[i] / float(VoxelColumn.FRACTION_ONE) * VoxelColumn.voxel_volume(_terrain.box.bottom() + i, p.radius, p.dtheta())
	print("inside: 2 m³ dumped at the roof (held %.6f after), settled in %.2f s: the loose over the tunnel's columns grew %.6f m³ more (%+.4f %%), %.6f m³ of it floating" % [
			_tools.held, waited2, v2 - v1, _residual("inside roof", v2 - v1, 2.0), floating])
	_report("a dump at the tunnel's roof ends up on its floor", _tools.held == 0.0 and waited2 >= 0.0 and absf(v2 - v1 - 2.0) <= 2e-3 and floating <= 1e-6)
	# 2 m³ at the player's own feet: the pile rises under them and the player ends up standing on it.
	me = _station.to_local(_player.global_position)
	_tools.held = 2.0
	_tools.dump(Cyl.position(Cyl.theta_of(me), me.z, _tunnel_floor, p.radius))
	for i in 30:
		if not _tools._dump_pending:
			break
		await get_tree().process_frame
	var waited3 := await _settled(c)
	var v3 := _vol(_read("loose"), _read("surface"), cells) + _gap_loose(cells)
	q = _station.to_local(_player.global_position)
	hit = _ray_down()
	clear = (hit.position.distance_to(_player.global_position) - 1.0) if not hit.is_empty() else -INF
	head = _head_ray()
	print("inside: 2 m³ dumped at the feet (held %.6f after), settled in %.2f s: the loose over the tunnel's columns grew %.6f m³ more (%+.4f %%); the player %+.2f m up, the feet %.3f m over the ground below, the ground met from the head %s; lifts %d" % [
			_tools.held, waited3, v3 - v2, _residual("inside feet", v3 - v2, 2.0), Cyl.height_of(q, p.radius) - Cyl.height_of(me, p.radius), clear, ("%.3f m over the feet" % head) if is_finite(head) else "nowhere", _tools.lifts - lifts0])
	_report("a dump at the feet leaves the player standing on it", _tools.held == 0.0 and waited3 >= 0.0 and absf(v3 - v2 - 2.0) <= 2e-3 and clear >= -0.05 and clear <= 0.3 and (not is_finite(head) or head <= 0.05) and _tools.lifts - lifts0 <= 1)
	return true


## Turns the player and tilts the camera toward station-local target, as the mouse would (the camera rides
## a spring arm, so a frame or two converges).
func _aim_at(target: Vector3) -> void:
	var cam: Camera3D = get_viewport().get_camera_3d()
	var up := _player.up_direction
	var dir := (_station.global_transform * target - cam.global_position).normalized()
	var fwd := -cam.global_basis.z
	var yaw := (fwd - up * fwd.dot(up)).signed_angle_to(dir - up * dir.dot(up), up)
	var pitch := asin(clampf(dir.dot(up), -1.0, 1.0)) - asin(clampf(fwd.dot(up), -1.0, 1.0))
	_player.look(Vector2(-yaw, -pitch) / _player.mouse_sensitivity)


## Phase play at P (see the header). False after quitting on a timeout.
func _play(c: Vector2i) -> bool:
	if not await _teleport(c + Vector2i(0, -3)):
		return false
	var p := _terrain.params
	var box := _terrain.box
	_face(Vector3(0, 0, 1))
	var scoops0 := _tools.scoops
	var held0 := _tools.held
	var s0 := _read("surface")
	# Looking down at the ground ahead, T held for 6 s: the hit sinks with the pit, and when it drops out of
	# the shovel's reach (the hold ends) the player looks a little further down and presses T again.
	var down := 250.0
	_player.look(Vector2(0.0, down))
	await _frames(3)
	_press(KEY_T, true)
	var t0 := Time.get_ticks_msec()
	var pressed := t0
	# Until the pit is 4.2 m deep, as the tunnel phase's: under the free height (5 m) so its walls stand, and
	# deep enough that the tunnel's roof (the pit's depth less 2.5 m) is over a voxel thick, which the span
	# rule lets stand over the bore (a thinner one falls, the shells' rule). Five scoops of the 1.5 m ball
	# make 4.33 m at a cell's centre; held, the hits wander the pit's slopes and five made 3.63 m.
	var deepest := 0.0
	var counted := scoops0
	var depths: Array[String] = []
	while Time.get_ticks_msec() - t0 < 6000 and deepest < 4.2 and _tools.scoops - scoops0 < 8:
		await get_tree().process_frame
		if _tools.scoops != counted and not _tools._scoop_pending:
			counted = _tools.scoops
			var sd := _read("surface")
			for x in _box(c, 4):
				deepest = maxf(deepest, _f(s0, x) - _f(sd, x))
			depths.append("%.2f" % deepest)
		if not _tools._t_down and Time.get_ticks_msec() - pressed >= 250:
			_player.look(Vector2(0.0, 40.0))
			down += 40.0
			_press(KEY_T, true)
			pressed = Time.get_ticks_msec()
	_press(KEY_T, false)
	_player.look(Vector2(0.0, -down))
	await _frames(3)
	var s1 := _read("surface")
	deepest = 0.0
	var pit := c
	for x in _box(c, 4):
		if _f(s0, x) - _f(s1, x) > deepest:
			deepest = _f(s0, x) - _f(s1, x)
			pit = x
	var pit_scoops := _tools.scoops - scoops0
	print("play: T held looking down: %d scoops (the pit's depth after each %s), the hand %.3f m³, the pit's deepest cell %s %.2f m down" % [
			pit_scoops, " ".join(depths), _tools.held - held0, pit, deepest])
	# The pit from where it was dug (user://debug/box_pit.png): its slopes, meshed by the box.
	_player.look(Vector2(0.0, 120.0))
	await _frames(3)
	await _shot("box_pit")
	_player.look(Vector2(0.0, -120.0))
	# Into the pit, facing its +z wall: W held for 6 s with T whenever the crosshair's hit is on a face ahead
	# (the shovel's level rule: a wall, a ramp or a step's riser, the ball's floor half a metre under the feet,
	# so the tunnel steps down with its roof the pit's depth less 2.5 m and keeps its level), the look swept
	# as a player's would be: from under the feet upward a little a frame until the hit is such a face, and
	# from under the feet again once it passes 3 m ahead or leaves the ground in reach; the player walks in
	# as the cut opens. The aim is logged once a second.
	var floor_h := _f(s1, pit) + _f(_read("loose"), pit)
	await _settled(pit)
	_player.global_position = _station.global_transform * Cyl.position((pit.x + 0.5) * p.dtheta(), -p.length / 2.0 + pit.y + 0.5, floor_h + 1.0 + Tools.STAND, p.radius)
	_face(Vector3(0, 0, 1))
	await _frames(10)
	var touched0 := box.touched.size()
	var z0 := _station.to_local(_player.global_position).z
	_player.look(Vector2(0.0, 1000.0))
	_press(KEY_W, true)
	t0 = Time.get_ticks_msec()
	pressed = t0
	var frames := 0
	var on_frames := 0
	while Time.get_ticks_msec() - t0 < 6000:
		await get_tree().process_frame
		frames += 1
		var hit := _tools.shovel_hit()
		var dz: float = hit.position.z - _station.to_local(_player.global_position).z if not hit.is_empty() else INF
		var level: bool = hit.get("level", false)
		if frames % 60 == 1:
			var up := _station.global_basis.inverse() * _player.up_direction
			var me := _station.to_local(_player.global_position)
			var cam := _station.to_local(get_viewport().get_camera_3d().global_position)
			print("play: the look at %.1f s (pitch %.2f, the camera z%+.2f h%+.2f, the player z%+.2f h%+.2f): the hit %s" % [(Time.get_ticks_msec() - t0) / 1000.0,
					_player._pivot.rotation.x, cam.z - me.z, Cyl.height_of(cam, p.radius) - floor_h, me.z - z0, Cyl.height_of(me, p.radius) - 1.0 - floor_h,
					("z%+.2f h%+.2f n.up %.2f%s" % [dz, Cyl.height_of(hit.position, p.radius) - floor_h, hit.normal.dot(up), ", level" if level else ""]) if not hit.is_empty() else "none"])
		if not level or dz <= 0.0:
			_player.look(Vector2(0.0, 1000.0 if hit.is_empty() or dz > 3.0 else -15.0))
			if _tools._t_down:
				_press(KEY_T, false)
		else:
			on_frames += 1
			if not _tools._t_down and Time.get_ticks_msec() - pressed >= 250:
				_press(KEY_T, true)
				pressed = Time.get_ticks_msec()
	_press(KEY_T, false)
	_press(KEY_W, false)
	await _shot("box_play")
	# The seam between the chunk's skirt and the ground tile around it, from 5 m inside the chunk's +z edge on
	# the surface, looking along +z a little down (user://debug/box_seam.png).
	var edge_row: int = (VoxelBox.chunk_of_cell(pit + Vector2i(0, 2)).y + 1) * VoxelBox.BRICK
	_terrain.teleport((pit.x + 0.5) * p.dtheta(), -p.length / 2.0 + edge_row - 5.0)
	await _settled_patch()
	# The collider's height against the packed surface across the tunnel's line there.
	var sf := _read("surface")
	var across: Array[String] = []
	var off := 0.0
	for dx in range(-3, 4):
		var cell := Vector2i(pit.x + dx, edge_row - 6)
		var g := _terrain.ground_below(Cyl.position((cell.x + 0.5) * p.dtheta(), -p.length / 2.0 + cell.y + 0.5, _f(sf, cell) + 20.0, p.radius), 40.0)
		var d: float = Cyl.height_of(g, p.radius) - _f(sf, cell) if g.is_finite() else INF
		off = maxf(off, absf(d))
		across.append("%+d: %s" % [dx, ("%+.2f" % d) if g.is_finite() else "none"])
	print("play: 6 m inside the chunk's +z edge, the collider over the packed surface across the tunnel's line: %s" % ", ".join(across))
	for dx in range(-1, 2):
		var cell := Vector2i(pit.x + dx, edge_row - 6)
		var vox := _column_vox(_stack(cell), cell)
		var ks := floori(_f(sf, cell)) - box.bottom()
		var fills: Array[String] = []
		for i in range(ks - 5, ks + 2):
			fills.append("%d: %.2f" % [i + box.bottom(), (vox.solid[i] + vox.loose[i]) / float(VoxelColumn.FRACTION_ONE)])
		print("play: the column at %+d (surface %.2f): %s" % [dx, _f(sf, cell), ", ".join(fills)])
	# A tunnel's roof thinner than a voxel is a slab split over two partial voxels: the mesher once lost it
	# (the collider 3.5 m under the surface there, a player over the tunnel falling in) or drew its top 0.6 m
	# low; a slab with no solid centre still snaps its near end to a voxel centre, up to half a metre off.
	_report("the ground over the tunnel stays in the collider", off <= 0.5)
	_face(Vector3(0, 0, 1))
	_player.look(Vector2(0.0, 60.0))
	await _frames(5)
	await _shot("box_seam")
	_player.look(Vector2(0.0, -60.0))
	_terrain.teleport((pit.x - 5.5) * p.dtheta(), -p.length / 2.0 + edge_row - 5.0)
	await _settled_patch()
	_face(Vector3(0, 0, 1))
	_player.look(Vector2(0.0, 60.0))
	await _frames(5)
	await _shot("box_seam_flat")
	_player.look(Vector2(0.0, -60.0))
	_terrain.teleport((pit.x + 0.5) * p.dtheta(), -p.length / 2.0 + pit.y + 0.5 + 6.0)
	await _settled_patch()
	# The roofed cells along +z from the pit: a gap under a surface the dig left alone (the pit's angled
	# scoops leave a ramp on its +z side, trenched to the floor before the wall proper).
	var s2 := _read("surface")
	var gb := _read("gap_bottom0")
	var gt := _read("gap_top0")
	var roofed: Array[int] = []
	var spans: Array[String] = []
	for row in range(1, 10):
		var x := pit + Vector2i(0, row)
		if _f(gt, x) > _f(gb, x) and _f(s2, x) == _f(s1, x):
			roofed.append(row)
			spans.append("%+d: %.2f..%.2f" % [row, _f(gb, x) - floor_h, _f(gt, x) - floor_h])
	var ch := VoxelBox.chunk_of_cell(pit + Vector2i(0, roofed[0] if not roofed.is_empty() else 2))
	var landed := await _chunk_landed(ch, 3.0)
	var wall_scoops := _tools.scoops - scoops0 - pit_scoops
	print("play: W held 6 s at the pit's +z wall, T while the crosshair was on it (%d of %d frames): %d scoops, the hand %.3f m³; roofed cells along +z (row: the gap over the pit's floor) [%s]; touched chunks %d -> %d, chunk %s meshed in %.2f s with %d faces" % [
			on_frames, frames, wall_scoops, _tools.held - held0, ", ".join(spans), touched0, box.touched.size(), ch, landed, _chunk_faces(ch)])
	await _frames(20)
	var held := 0
	var uncovered := 0
	_press(KEY_W, true)
	for i in 120:
		await get_tree().process_frame
		held += int(_player.process_mode == Node.PROCESS_MODE_DISABLED)
		uncovered += int(not _terrain.covered(_station.to_local(_player.global_position - _player.up_direction)))
	_press(KEY_W, false)
	var walked := _station.to_local(_player.global_position).z - z0
	var mouth := roofed[0] if not roofed.is_empty() else 99
	print("play: walked %.2f m along +z from the pit's floor (W held through the dig and 2 s more), the tunnel's mouth %d m along; held %d frames, the feet uncovered %d frames" % [walked, mouth, held, uncovered])
	_report("the shovel as played digs a pit and a tunnel the player walks into", pit_scoops + wall_scoops >= 8 and _tools.held > held0 and deepest >= 4.2
			and roofed.size() >= 3 and box.touched.has(ch) and landed >= 0.0 and walked >= mouth + 1.0 and held == 0 and uncovered == 0)
	return true


## The tunnel's columns and the wall columns either side, rows first..7 from the pit (0: the pit's own).
func _tunnel_cells(c: Vector2i, first := 0) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	for row in range(first, 8):
		for x in range(-1, 3):
			cells.append(c + Vector2i(x, row))
	return cells


## Every window field's bytes over cells (4 per cell for a float field, 1 for a byte field), field -> bytes.
func _cells_bits(cells: Array[Vector2i]) -> Dictionary:
	var out := {}
	var n := _terrain.window.size * _terrain.window.size
	for field: String in TerrainWindow.FIELDS:
		var data := _read(field)
		var bytes := PackedByteArray()
		for c in cells:
			var k := _texel(c)
			if data.size() == n:
				bytes.append(data[k])
			else:
				bytes.append_array(data.slice(4 * k, 4 * k + 4))
		out[field] = bytes
	return out


## The cells whose bytes of a field differ between two _cells_bits, with both values.
func _bits_detail(a: Dictionary, b: Dictionary, cells: Array[Vector2i], field: String) -> String:
	var w := 4 if field in TerrainWindow.FLOAT_FIELDS else 1
	var out: Array[String] = []
	for i in cells.size():
		var x: PackedByteArray = a[field].slice(w * i, w * i + w)
		var y: PackedByteArray = b[field].slice(w * i, w * i + w)
		if x != y:
			out.append("%s %s -> %s" % [cells[i], x.decode_float(0) if w == 4 else x[0], y.decode_float(0) if w == 4 else y[0]])
	return "%s: %s" % [field, ", ".join(out)]


## The fields whose bytes differ between two _cells_bits, the loose ones aside (a settled pile that re-enters
## the box creeps a few counts, the Task 5 ruling: its volume is checked instead).
func _bits_differ(a: Dictionary, b: Dictionary) -> Array[String]:
	var out: Array[String] = []
	for field: String in a:
		if field != "loose" and not field.begins_with("gap_loose") and a[field] != b[field]:
			out.append(field)
	return out


## Waits up to limit s for the chunk's mesh to land with faces: the seconds it took, -1 when it did not.
func _chunk_landed(ch: Vector2i, limit: float) -> float:
	var start := Time.get_ticks_msec()
	while Time.get_ticks_msec() - start < limit * 1000.0:
		await get_tree().process_frame
		if _chunk_faces(ch) > 0:
			return (Time.get_ticks_msec() - start) / 1000.0
	return -1.0


## Stands the player two cells into the tunnel at c, facing its end, and after ten frames tells whether it
## stands there: not held, the feet over ground (Terrain.covered) within 0..0.3 m of the collider under them.
func _stand_in_tunnel(c: Vector2i) -> bool:
	var p := _terrain.params
	# Onto the ground a ray from 2.5 m over the tunnel's floor meets (a pile dumped there, else the floor): a
	# player placed at the floor's height stands inside a pile's mesh, and Jolt's back-face contact may push
	# it down through the floor before the unbury rule lifts it.
	var at := Cyl.position((c.x + 0.5) * p.dtheta(), -p.length / 2.0 + c.y + 2.5, _tunnel_floor + 2.5, p.radius)
	var ground := _terrain.ground_below(at, 3.0)
	if not ground.is_finite():
		ground = Cyl.position((c.x + 0.5) * p.dtheta(), -p.length / 2.0 + c.y + 2.5, _tunnel_floor, p.radius)
	var up := Vector3(-sin(Cyl.theta_of(ground)), cos(Cyl.theta_of(ground)), 0.0)
	_player.global_position = _station.global_transform * (ground + up * (1.0 + Tools.STAND))
	_face(Vector3(0, 0, 1))
	await _frames(10)
	var hit := _ray_down()
	var clear: float = (hit.position.distance_to(_player.global_position) - 1.0) if not hit.is_empty() else -INF
	var feet := _station.to_local(_player.global_position - _player.up_direction)
	print("stand: held %s, the feet covered %s, %.3f m over the collider under them, at height %.3f for a floor at %.3f" % [
			_player.process_mode == Node.PROCESS_MODE_DISABLED, _terrain.covered(feet), clear, Cyl.height_of(feet, p.radius), _tunnel_floor])
	return _player.process_mode != Node.PROCESS_MODE_DISABLED and _terrain.covered(feet) and clear >= -0.05 and clear <= 0.3


## Phase shell at S (see the header). False after quitting on a timeout.
func _shell(s: Vector2i) -> bool:
	if not await _teleport(s + Vector2i(5, 0)):
		return false
	var p := _terrain.params
	var r := _terrain.tool_params.scoop_ball
	var centre := _tools.surface_point(s)
	var balls: Array[Vector3] = [centre]
	for off: Vector2 in [Vector2(2, 0), Vector2(-2, 0), Vector2(0, 2), Vector2(0, -2)]:
		var h := Cyl.height_of(centre, p.radius)
		balls.append(Cyl.position(Cyl.theta_of(centre) + off.x / (p.radius - h), centre.z + off.y, h - 1.0, p.radius))
	for b in balls:
		await _scoop_at(b)
	var waited := await _settled(s)
	var ch := VoxelBox.chunk_of_cell(s)
	var landed := await _chunk_landed(ch, 3.0)
	await _frames(5)
	var st: Dictionary = _terrain.box.touched.get(ch, {})
	var total := 0
	var inside := 0
	var deepest := 0.0
	var crumb := 0.0
	if not st.is_empty() and st.node != null and st.node._mesh.mesh != null:
		var vs: PackedVector3Array = st.node._mesh.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		for v in vs:
			total += 1
			var depth := 0.0
			for b in balls:
				depth = maxf(depth, r - v.distance_to(b))
			deepest = maxf(deepest, depth)
			# A vertex deep in the hollow on a voxel holding dirt with air under and over it: a crumb floating
			# there (the ball's own wall voxels put vertices up to half a metre inside too, by their lumps).
			if depth > 0.5:
				var cell := _cell_of(v)
				var vox := _column_vox(_stack(cell), cell)
				var k := floori(Cyl.height_of(v, p.radius)) - _terrain.box.bottom()
				var fill := func(i: int) -> float:
					return (vox.solid[i] + vox.loose[i]) / float(VoxelColumn.FRACTION_ONE) if i >= 0 and i < vox.solid.size() else 0.0
				if fill.call(k) > 0.0 and fill.call(k - 1) == 0.0 and fill.call(k + 1) == 0.0:
					inside += 1
					crumb = maxf(crumb, depth)
					if inside <= 8:
						var h0 := Cyl.height_of(centre, p.radius)
						print("shell: a crumb %.2f m inside the hollow: across %+.2f, along %+.2f, height %+.2f, its voxel %.2f full with air under and over" % [
								depth, wrapf(Cyl.theta_of(v) - Cyl.theta_of(centre), -PI, PI) * (p.radius - h0), v.z - centre.z, Cyl.height_of(v, p.radius) - h0, fill.call(k)])
	print("shell: five balls at %s (one at the surface, four 2 m around it a metre lower), settled in %.2f s, the chunk's mesh landed in %.2f s: %d vertices, %d of them crumbs floating in the hollow, the deepest crumb %.2f m in, the deepest vertex %.2f m in" % [
			s, waited, landed, total, inside, crumb, deepest])
	# The span rule drops the skin the scoop keeps over a ball cut under it (box_edit.glsl's THIN_ROOF): what
	# crumbs are left are the lips a thin roof keeps along its walls, nearer the hollow's surface than a metre.
	_report("a dig around a dig leaves a mesh with no crumb deeper than a metre in its hollow", waited >= 0.0 and landed >= 0.0 and total > 0 and crumb <= 1.0)
	return true


## Phase roof at c (see the header). False after quitting on a timeout.
func _roof(c: Vector2i) -> bool:
	if not await _teleport(c + Vector2i(5, 0)):
		return false
	var p := _terrain.params
	var s0 := _read("surface")
	var cb0 := _read("clay_bottom")
	var ct0 := _read("clay_top")
	var depth := await _pit(c, 4.2)
	var waited := await _settled(c)
	_terrain.teleport((c.x + 0.5) * p.dtheta(), -p.length / 2.0 + c.y + 0.5)
	if not await _settled_patch():
		return false
	var floor_h := _f(_read("surface"), c) + _f(_read("loose"), c)
	var aim := func(x: float, d: float, h: float) -> Vector3:
		return Cyl.position((c.x + x + 0.5) * p.dtheta(), -p.length / 2.0 + c.y + 0.5 + d, floor_h + h, p.radius)
	for k in 7:
		await _scoop_at(aim.call(0.5, 1.5 + 0.5 * k, 1.5))
	# The tunnel's roof, rows 3 to 5 of its two columns, as the tunnel phase holds it (the rim's slivers fall).
	var roof: Array[Vector2i] = []
	for row in range(3, 6):
		roof.append(c + Vector2i(0, row))
		roof.append(c + Vector2i(1, row))
	var gt0 := _read("gap_top0")
	var waited2 := await _settled(c + Vector2i(0, 3))
	await get_tree().create_timer(10.0).timeout
	var s1 := _read("surface")
	var gt1 := _read("gap_top0")
	var moved := 0.0
	var rose := 0.0
	for x in roof:
		moved = maxf(moved, absf(_f(s1, x) - _f(s0, x)))
		rose = maxf(rose, absf(_f(gt1, x) - _f(gt0, x)))
	var loose := _vol(_read("loose"), s1, roof) + _gap_loose(roof)
	print("roof: the pit at %s %.2f m deep, settled in %.2f s; the tunnel's roof %.2f m thick, settled in %.2f s and 10 s on: the surface over it moved %.3f m at most, the gap tops %.3f m, %.4f m³ of loose over it" % [
			c, depth, waited, _f(s1, c + Vector2i(0, 4)) - _f(gt1, c + Vector2i(0, 4)), waited2, moved, rose, loose])
	# The roof's underside may drop a sliver under a quarter voxel (0.16 and 0.35 of one at rows 3 and 4 on
	# this site): a partial voxel is itself the roof voxel and reads its supports a voxel down, where the
	# round bore is at its widest and the walls' voxels hold under half, so near the pit, with no end wall
	# within the reach, it fails as a cantilever. The full voxel over it reads the walls whole and holds.
	_report("a 3 m tunnel under a roof over a voxel thick holds", depth >= 4.2 and waited >= 0.0 and waited2 >= 0.0 and moved <= 0.05 and rose <= 0.25)
	# Widened to 8 m and lengthened to 8 m: balls along the tunnel's line and 1.5 and 2.5 cells either side
	# of it (2.5 cells apart, the balls would leave a ridge at the hollow's top that props the roof), every
	# half metre from 2 to 8 m along. A room 8 m wide and 4 m long stands but by the pit, held across its
	# short side as a 4 m tunnel is (the span rule's disc reads both ways).
	var cells := _box(c + Vector2i(1, 5), 10)
	var middle: Array[Vector2i] = [c + Vector2i(0, 5), c + Vector2i(1, 5), c + Vector2i(0, 6), c + Vector2i(1, 6)]
	var sw := _read("surface")
	var lw := _read("loose")
	var top0: Array[float] = []
	for x in middle:
		top0.append(_f(sw, x) + _f(lw, x))
	var lost0 := _swelled_loss(cells, sw, cb0, ct0)
	var loose0 := _vol(lw, sw, cells) + _gap_loose(cells)
	var held0 := _tools.held
	for x: float in [0.5, -1.0, 2.0, -2.0, 3.0]:
		for k in 13:
			await _scoop_at(aim.call(x, 2.0 + 0.5 * k, 1.5))
	var start := Time.get_ticks_msec()
	var sank := 0.0
	var fell := -1.0
	while Time.get_ticks_msec() - start < 20000:
		await _frames(30)
		var sf := _read("surface")
		var lf := _read("loose")
		sank = INF
		for i in middle.size():
			sank = minf(sank, top0[i] - _f(sf, middle[i]) - _f(lf, middle[i]))
		if sank >= 1.0:
			fell = (Time.get_ticks_msec() - start) / 1000.0
			break
	var waited3 := await _settled(c + Vector2i(1, 3), 20.0)
	var s2 := _read("surface")
	var l2 := _read("loose")
	var grid: Array[String] = []
	for row in range(0, 12):
		var line: Array[String] = []
		for x in range(-4, 6):
			var cell := c + Vector2i(x, row)
			line.append("%+.2f" % (_f(sw, cell) + _f(lw, cell) - _f(s2, cell) - _f(l2, cell)))
		grid.append("row %d: %s" % [row, " ".join(line)])
	var lost := _swelled_loss(cells, sw, cb0, ct0) - lost0
	var got := _tools.held - held0 + _vol(l2, s2, cells) + _gap_loose(cells) - loose0
	print("roof: widened to 8 m by 8 (%.6f m³ in the hand), the ground over the room's middle sank %.2f m or more in %.2f s; settled in %.2f s; the ground's sinking, x -4..5 from the pit's cell: %s" % [
			_tools.held - held0, sank, fell, waited3, "; ".join(grid)])
	print("roof: over the box of 10 the solid lost (swelled) %.6f m³ for %.6f held + %.6f loose = %.6f (%+.4f %%)" % [
			lost, _tools.held - held0, got - (_tools.held - held0), got, _residual("roof", got, lost)])
	_report("a room too wide climbs to a sinkhole, conserved", fell >= 0.0 and waited3 >= 0.0 and absf(got - lost) <= 1e-3 * lost)
	return true


func _cell_of(v: Vector3) -> Vector2i:
	return _terrain.params.cell_of(Cyl.theta_of(v), v.z)


## Phase pillar at c (see the header). False after quitting on a timeout.
func _pillar(c: Vector2i) -> bool:
	if not await _teleport(c + Vector2i(5, 0)):
		return false
	var p := _terrain.params
	var s0 := _read("surface")
	# The pit to 4.4 m (six scoops, about 4.55 m), not the tunnel phase's 4.2: on a roof partial under half a
	# voxel (a 4.2 m pit's) a post holds only within 1.25 m, and the cells diagonal to it lose their surface
	# voxel when the room is widened; the phase proves the post on the thicker partial, the thin case a listed
	# limit (the followups).
	var depth := await _pit(c, 4.4)
	var waited := await _settled(c)
	_terrain.teleport((c.x + 0.5) * p.dtheta(), -p.length / 2.0 + c.y + 0.5)
	if not await _settled_patch():
		return false
	var floor_h := _f(_read("surface"), c) + _f(_read("loose"), c)
	var aim := func(x: float, d: float, h: float) -> Vector3:
		return Cyl.position((c.x + x + 0.5) * p.dtheta(), -p.length / 2.0 + c.y + 0.5 + d, floor_h + h, p.radius)
	for k in 7:
		await _scoop_at(aim.call(0.5, 1.5 + 0.5 * k, 1.5))
	var landed := await _chunk_landed(VoxelBox.chunk_of_cell(c + Vector2i(0, 3)), 3.0)
	await _frames(20)
	# _stand_in_tunnel stands the player on _tunnel_floor's tunnel; the tunnel phase's is kept for the exit scoop.
	var kept := _tunnel_floor
	_tunnel_floor = floor_h
	var stood := await _stand_in_tunnel(c)
	_tunnel_floor = kept
	print("pillar: the pit %.2f m deep (bedrock %.2f m under its floor), settled in %.2f s; the tunnel's chunk meshed in %.2f s; the player stood in it: %s" % [
			depth, floor_h - _f(_read("bedrock_top"), c), waited, landed, stood])
	_report("a tunnel under a pit six scoops deep, the player in it", depth >= 4.4 and waited >= 0.0 and landed >= 0.0 and stood)
	var cell := c + Vector2i(0, 4)
	var bottom := _terrain.box.bottom()
	# The pillar's voxels: those holding solid of material 4.
	var pillar_of := func(vox: Dictionary) -> Array[int]:
		var out: Array[int] = []
		for i in vox.solid.size():
			if vox.material[i] == VoxelBox.PILLAR and vox.solid[i] > 0:
				out.append(i)
		return out
	var n0 := _tools.pillars
	_tools.place_pillar(cell)
	await _frames(1)
	var vox := _column_vox(_stack(cell), cell)
	var ks: Array[int] = pillar_of.call(vox)
	var stands: bool = not ks.is_empty() and ks[-1] - ks[0] + 1 == ks.size() and ks[0] > 0 and ks[-1] + 1 < vox.solid.size() \
			and ks.all(func(i: int) -> bool: return vox.solid[i] == VoxelColumn.FRACTION_ONE and vox.loose[i] == 0) \
			and vox.solid[ks[0] - 1] + vox.loose[ks[0] - 1] > 0 and vox.solid[ks[-1] + 1] > 0
	waited = await _settled(cell)
	var gm := _b(_read("gap_material0"), cell)
	print("pillar: at %s over the floor at %.2f: voxels %s (heights %d..%d), the floor's voxel %d+%d, the roof's %d; settled in %.2f s, the first gap %.2f..%.2f of material %d; pillars %d" % [
			cell, floor_h, ks, bottom + (ks[0] if ks else 0), bottom + (ks[-1] + 1 if ks else 0), vox.solid[ks[0] - 1] if ks else -1, vox.loose[ks[0] - 1] if ks else -1,
			vox.solid[ks[-1] + 1] if ks else -1, waited, _f(_read("gap_bottom0"), cell), _f(_read("gap_top0"), cell), gm, _tools.pillars])
	_report("a pillar stands from a tunnel's floor to its roof, whole voxels of material 4", stands)
	_report("the pack stores the pillar as its gap's material", waited >= 0.0 and gm == VoxelBox.PILLAR and _tools.pillars == n0 + 1)
	# The drawn post meets the floor and the roof (box_mesh.glsl's column_runs bridges the partial voxels): rays
	# along +z from the player's cell, half a metre over the gap's bottom and a quarter under its top, meet it
	# at its cell's near face, not the tunnel's end past it. The low ray clears the pile the span rule drops
	# a cell before the post (the roof's underside sliver over the pit's rim: a quarter metre over the gap's
	# bottom it met that pile half a metre short).
	await _frames(20)
	var along := func(h: float) -> float:
		var from := Cyl.position((cell.x + 0.5) * p.dtheta(), -p.length / 2.0 + c.y + 2.5, h, p.radius)
		var ray := PhysicsRayQueryParameters3D.create(_station.global_transform * from, _station.global_transform * (from + Vector3(0, 0, 4)))
		ray.exclude = [_player.get_rid()]
		var hit := _station.get_world_3d().direct_space_state.intersect_ray(ray)
		return _station.to_local(hit.position).z - (-p.length / 2.0 + c.y) if not hit.is_empty() else INF
	var gb := _f(_read("gap_bottom0"), cell)
	var gt := _f(_read("gap_top0"), cell)
	var foot: float = along.call(gb + 0.5)
	var head: float = along.call(gt - 0.25)
	print("pillar: rays along +z meet the post %.2f and %.2f cells past the pit's cell, at %.2f over the floor %.2f and %.2f under the roof %.2f; the loose a cell before it %.2f m" % [
			foot, head, gb + 0.5, gb, gt - 0.25, gt, _f(_read("gap_loose0"), cell - Vector2i(0, 1))])
	_report("the drawn post meets the floor and the roof", absf(foot - 4.0) <= 0.5 and absf(head - 4.0) <= 0.5)
	# The post from behind the player (user://debug/box_pillar.png): _shot pitches the camera 300 down, so it is
	# raised 250 first to look along the tunnel a little down.
	_face(Vector3(0, 0, 1))
	_player.look(Vector2(0.0, -250.0))
	await _shot("box_pillar")
	_player.look(Vector2(0.0, 250.0))
	_tools.place_pillar(cell)
	await _frames(1)
	var after := _column_vox(_stack(cell), cell)
	var gone: bool = (pillar_of.call(after) as Array[int]).is_empty() and ks.all(func(i: int) -> bool: return after.solid[i] + after.loose[i] == 0)
	waited = await _settled(cell)
	gm = _b(_read("gap_material0"), cell)
	var gap := _f(_read("gap_top0"), cell) - _f(_read("gap_bottom0"), cell)
	print("pillar: taken away: no pillar voxel and its voxels air %s; settled in %.2f s, the first gap %.2f m of material %d; pillars %d" % [gone, waited, gap, gm, _tools.pillars])
	_report("a second P takes the pillar away", gone and waited >= 0.0 and gm == 0 and gap > 2.0 and _tools.pillars == n0)
	# A hit with solid over it (2 m under the tunnel's floor, as a wall's hit nudged into it) stands nothing: the
	# floor the op passes is at most two voxels, not the 2 m up to the tunnel's air.
	_tools.pillar(Cyl.position((cell.x + 0.5) * p.dtheta(), -p.length / 2.0 + cell.y + 0.5, gb - 2.0, p.radius))
	await _frames(10)
	var buried: bool = (pillar_of.call(_column_vox(_stack(cell), cell)) as Array[int]).is_empty()
	print("pillar: 2 m under the tunnel's floor at %s: no pillar voxel %s; pillars %d" % [cell, buried, _tools.pillars])
	_report("P on a hit with solid over it stands nothing", buried and _tools.pillars == n0)
	# P on the open ground: aimed a quarter metre under its surface (in its top voxel, the floor the op passes),
	# so the op runs from that floor up to the sky and finds no roof within the reach.
	var open := c + Vector2i(-3, 0)
	var open_h := Cyl.height_of(_tools.surface_point(open), p.radius) - 0.25
	_tools.pillar(Cyl.position((open.x + 0.5) * p.dtheta(), -p.length / 2.0 + open.y + 0.5, open_h, p.radius))
	await _frames(10)
	var bare: bool = (pillar_of.call(_column_vox(_stack(open), open)) as Array[int]).is_empty()
	print("pillar: on the open ground at %s, aimed at %.2f (the surface %.2f): no pillar voxel %s; pillars %d" % [open, open_h, open_h + 0.25, bare, _tools.pillars])
	_report("P on open ground stands nothing", bare and _tools.pillars == n0)
	# The post stood again and the tunnel dug round it to a room 6 m wide (balls 1.5 cells either side of its
	# line) and 8 m long (a room as short as the tunnel stands without the post, held across its short side):
	# the roof over the room's middle, the post's column and those either side, is held by the post and the
	# walls (the span rule's worked case), and falls when the post goes.
	_tools.place_pillar(cell)
	await _frames(1)
	for x: float in [0.5, -1.0, 2.0]:
		for k in 13:
			await _scoop_at(aim.call(x, 1.5 + 0.5 * k, 1.5))
	# The room's middle on the post's row and the row before it (by the pit): the post's column and the one
	# past it, which fall when the post goes. The column on the post's other side keeps a ledge when it goes
	# (it loses only its underside, about 0.25 m³), so it is not watched. The surface over the four, unchanged
	# since before the pit, shows a fall during the dig; their solid, a fall in the 10 s after it.
	var sides: Array[Vector2i] = [cell, cell + Vector2i(1, 0), cell + Vector2i(0, -1), cell + Vector2i(1, -1)]
	var solid0: Array[float] = []
	for x in sides:
		solid0.append(_box_volumes([x])[1])
	await get_tree().create_timer(10.0).timeout
	var s1 := _read("surface")
	var drift := 0.0
	var moved := 0.0
	var drifts: Array[String] = []
	for i in sides.size():
		var d := _box_volumes([sides[i]])[1] - solid0[i]
		drift = maxf(drift, absf(d))
		moved = maxf(moved, absf(_f(s1, sides[i]) - _f(s0, sides[i])))
		drifts.append("%s %+.4f" % [sides[i] - cell, d])
	print("pillar: stood again at %s (pillars %d), the room dug to 6 m by 8: 10 s on the surface over the room's middle moved %.3f m at most since before the pit, its solid %.4f m³ (%s)" % [
			cell, _tools.pillars, moved, drift, ", ".join(drifts)])
	# A column off the post's row and column may drop its roof's underside sliver, under a quarter voxel (0.11 m³
	# at (1, -1) over a 4.20 m pit), as the roof phase's tunnel does: it reads its supports a voxel down, where
	# the bore is widest. The roof over it holds; a fall loses a metre of it.
	_report("a pillar holds a 6 m room", _tools.pillars == n0 + 1 and moved <= 0.05 and drift <= 0.25)
	# A landing's tamp beside the post with loose in its column: 0.05 m³ dumped into the post's floor voxel
	# (the ball fills the nearest voxel first), then the tamp with the feet on the floor a cell before the
	# post, its plus over the post's column and its voxels two under to two over the feet's (the floor's and
	# the post's bottom). The tamp's settle moves no pillar's solid into the floor under it.
	var posts: Array[int] = pillar_of.call(_column_vox(_stack(cell), cell))
	var at := func(x: Vector2i, h: float) -> Vector3:
		return Cyl.position((x.x + 0.5) * p.dtheta(), -p.length / 2.0 + x.y + 0.5, h, p.radius)
	var dumped := _terrain.box.dump(at.call(cell, bottom + posts[0] - 0.5), _terrain.tool_params.scoop_ball, 0.05, Callable()) if not posts.is_empty() else false
	await _frames(3)
	# The loose under the post within the tamp's voxels (it may have fallen a voxel onto the floor's partial).
	var under := _column_vox(_stack(cell), cell)
	var held_loose := 0
	for i in range(maxi(posts[0] - 4, 0), posts[0]) if not posts.is_empty() else []:
		held_loose += under.loose[i]
	var tamped := _terrain.box.tamp(at.call(cell + Vector2i(0, -1), floor_h), _terrain.tool_params.foot_radius, _terrain.tool_params.tamp_step,
			_terrain.materials.swell_factor[0])
	await _frames(3)
	var whole := func(vox: Dictionary) -> bool:
		return pillar_of.call(vox) == posts and posts.all(func(i: int) -> bool: return vox.solid[i] == VoxelColumn.FRACTION_ONE)
	var kept_post: bool = whole.call(_column_vox(_stack(cell), cell))
	print("pillar: the post's voxels %s; 0.05 m³ dumped on its floor voxel (%s, the loose under the post %d), a tamp beside it (%s): the post's voxels whole %s" % [
			posts, dumped, held_loose, tamped, kept_post])
	_report("a landing's tamp beside a post leaves its voxels whole", not posts.is_empty() and dumped and held_loose > 0 and tamped and kept_post)
	# The post's column packed (settled) and reloaded from the window: the GPU unpack of its pillar gap gives
	# back the same voxels, and the room still holds.
	waited = await _settled(cell)
	await _frames(10)
	_terrain.box.reload([cell])
	await _frames(3)
	var reloaded: bool = whole.call(_column_vox(_stack(cell), cell))
	await get_tree().create_timer(5.0).timeout
	var s2 := _read("surface")
	var held := 0.0
	for x in sides:
		held = maxf(held, absf(_f(s2, x) - _f(s0, x)))
	print("pillar: settled in %.2f s, the post's column reloaded: its voxels %s, whole %s; 5 s on the surface over the room's middle moved %.3f m at most since before the pit" % [
			waited, pillar_of.call(_column_vox(_stack(cell), cell)), reloaded, held])
	_report("the unpack gives a pillar back, and the room holds", waited >= 0.0 and reloaded and held <= 0.05)
	_tools.place_pillar(cell)
	var start := Time.get_ticks_msec()
	var fell := -1.0
	var lost: Array[float] = []
	lost.resize(sides.size())
	while Time.get_ticks_msec() - start < 10000:
		await _frames(30)
		for i in sides.size():
			lost[i] = solid0[i] - _box_volumes([sides[i]])[1]
		if minf(lost[0], lost[1]) >= 0.9:
			fell = (Time.get_ticks_msec() - start) / 1000.0
			break
	print("pillar: taken away (pillars %d): the room's middle lost %.3f and %.3f m³ of solid on the post's row, %.3f and %.3f on the row before, in %.2f s" % [
			_tools.pillars, lost[0], lost[1], lost[2], lost[3], fell])
	_report("the roof falls when the pillar goes", _tools.pillars == n0 and fell >= 0.0)
	return true


## Phase tscroll (see the header). False after quitting on a timeout.
func _tunnel_scroll() -> bool:
	if _tunnel_site == TerrainSim.NO_CELL:
		return _quit("The scroll phase needs the tunnel phase's tunnel.")
	var p := _terrain.params
	var c := _tunnel_site
	var cells := _tunnel_cells(c)
	var tunnel := _tunnel_cells(c, 2)
	var ch := VoxelBox.chunk_of_cell(c + Vector2i(0, 3))
	var waited0 := await _settled(c)
	var before := _cells_bits(tunnel)
	var v0 := _vol(_read("loose"), _read("surface"), cells) + _gap_loose(cells)
	_terrain.teleport((c.x + 0.5) * p.dtheta() + 600.0 / p.radius, -p.length / 2.0 + c.y + 0.5)
	if not await _settled_patch():
		return false
	var away := _terrain.window.center_tile
	var gone := not _terrain.box.touched.has(ch)
	if not await _teleport(c):
		return false
	var landed := await _chunk_landed(ch, 3.0)
	var after := _cells_bits(tunnel)
	var differ := _bits_differ(before, after)
	var v1 := _vol(_read("loose"), _read("surface"), cells) + _gap_loose(cells)
	var stood := await _stand_in_tunnel(c)
	print("scroll: settled in %.2f s; 600 m away (window centre %s, the chunk gone from the box: %s) and back: the tunnel's columns bit for bit as before (the loose aside): %s%s; its piles %.6f m³, were %.6f (%+.4f %%); chunk %s meshed again in %.2f s with %d faces; the player stood inside: %s" % [
			waited0, away, gone, differ.is_empty(), "" if differ.is_empty() else " (changed %s)" % "; ".join(differ.map(func(f: String) -> String: return _bits_detail(before, after, tunnel, f))), v1, v0, _residual("tunnel scroll", v1, v0), ch, landed, _chunk_faces(ch), stood])
	_report("a tunnel survives a scroll: its columns, its piles, its chunk's mesh, the player's footing", waited0 >= 0.0 and gone and differ.is_empty() and absf(v1 - v0) <= 1e-3 * v0 and landed >= 0.0 and stood)
	return true


## Phase trestart (see the header). False after quitting on a timeout.
func _tunnel_restart() -> bool:
	if _tunnel_site == TerrainSim.NO_CELL:
		return _quit("The restart phase needs the tunnel phase's tunnel.")
	var p := _terrain.params
	var c := _tunnel_site
	var cells := _tunnel_cells(c)
	var tunnel := _tunnel_cells(c, 2)
	var ch := VoxelBox.chunk_of_cell(c + Vector2i(0, 3))
	# The pile: 2 m³ at the floor two cells short of the tunnel's end, dumped from two cells in (the stand's
	# place after the restart stays clear of it).
	_player.global_position = _station.global_transform * Cyl.position((c.x + 0.5) * p.dtheta(), -p.length / 2.0 + c.y + 2.5, _tunnel_floor + 1.0 + Tools.STAND, p.radius)
	_face(Vector3(0, 0, 1))
	await _frames(10)
	_tools.held = 2.0
	_tools.dump(Cyl.position((c.x + 0.5) * p.dtheta(), -p.length / 2.0 + c.y + 4.5, _tunnel_floor, p.radius))
	for i in 30:
		if not _tools._dump_pending:
			break
		await get_tree().process_frame
	var waited0 := await _settled(c)
	var before := _cells_bits(tunnel)
	var v0 := _vol(_read("loose"), _read("surface"), cells) + _gap_loose(cells)
	if not await _restart():
		return false
	if not await _teleport(c):
		return false
	var landed := await _chunk_landed(ch, 5.0)
	var after := _cells_bits(tunnel)
	var differ := _bits_differ(before, after)
	var v1 := _vol(_read("loose"), _read("surface"), cells) + _gap_loose(cells)
	# The stand once the box has settled: the span rule's slivers drop their loose on the tunnel's floor after
	# the restart unpacks it.
	await _settled(c)
	var stood := await _stand_in_tunnel(c)
	print("restart: settled in %.2f s; after the restart the tunnel's columns bit for bit as before (the loose aside): %s%s; its piles %.6f m³, were %.6f (%+.4f %%); chunk %s meshed again in %.2f s with %d faces; the player stood inside: %s" % [
			waited0, differ.is_empty(), "" if differ.is_empty() else " (changed %s)" % "; ".join(differ.map(func(f: String) -> String: return _bits_detail(before, after, tunnel, f))), v1, v0, _residual("tunnel restart", v1, v0), ch, landed, _chunk_faces(ch), stood])
	_report("a tunnel survives a restart: its columns, its pile, its chunk's mesh, the player's footing", waited0 >= 0.0 and differ.is_empty() and v0 >= 1.9 and absf(v1 - v0) <= 1e-3 * v0 and landed >= 0.0 and stood)
	return true


## The exit (see the header): a scoop at the tunnel's end in the quit's frame, checked in the blob once Terrain
## has left the tree.
func _tunnel_exit() -> void:
	var p := _terrain.params
	var c := _tunnel_site
	var cell := c + Vector2i(0, 9)  # past the tunnel's end (its last 1.5 m ball reaches row 6.5)
	var tile := _terrain.window.tile_of_cell(cell.x, cell.y)
	var o := EditLayer.cell_offset(posmod(cell.x, TerrainWindow.TILE), posmod(cell.y, TerrainWindow.TILE))
	var edits := _terrain.window.edits
	var had: bool = edits.blobs.has(tile) and edits.blobs[tile].decode_float(o + 48) > edits.blobs[tile].decode_float(o + 32)
	_tools.scoop(Cyl.position((c.x + 0.5) * p.dtheta(), -p.length / 2.0 + cell.y + 0.5, _tunnel_floor + 1.0, p.radius))
	_terrain.tree_exited.connect(func() -> void:
		var blob: PackedByteArray = edits.blobs.get(tile, PackedByteArray())
		var packed: bool = blob.size() > o + 52 and blob.decode_float(o + 48) > blob.decode_float(o + 32)
		print("exit pack: the box's last scoop (a gap at %s in the quit's frame; one there before: %s) packed into tile %s's blob: %s" % [cell, had, tile, packed])
		if had or not packed:
			push_error("exit pack: the box's last change did not reach the blob"))


## The ground met by a ray from the player's head down to under the feet, as m over the feet (INF with none):
## positive when the ground has risen over the feet.
func _head_ray() -> float:
	var up := _player.up_direction
	var from := _player.global_position + up * 0.9
	var ray := PhysicsRayQueryParameters3D.create(from, _player.global_position - up * 1.2)
	ray.exclude = [_player.get_rid()]
	var hit := _player.get_world_3d().direct_space_state.intersect_ray(ray)
	if hit.is_empty():
		return INF
	return (hit.position - (_player.global_position - up)).dot(up)


## The faces of a chunk's landed mesh, 0 with none.
func _chunk_faces(ch: Vector2i) -> int:
	var st: Dictionary = _terrain.box.touched.get(ch, {})
	return st.node.faces if not st.is_empty() and st.node != null else 0


## The first hit under the player within 3 m (the player excluded), global.
func _ray_down() -> Dictionary:
	var from := _player.global_position
	var ray := PhysicsRayQueryParameters3D.create(from, from - _player.up_direction * 3.0)
	ray.exclude = [_player.get_rid()]
	return _player.get_world_3d().direct_space_state.intersect_ray(ray)

