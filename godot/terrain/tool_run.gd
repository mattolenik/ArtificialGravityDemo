## Windowed check of the slice 3 tools (the terrain slice 3 plan, decision 13), grown phase by phase.
## Instantiates main.tscn and, once the first collider patch is live, runs each phase at its site, a cell
## spawn_cell + (0, 40 k) on the spawn's column, every stamp through Terrain.stamp_tool with tool_params
## values, reading the window synchronously three frames after each stamp. Phases:
## stamps (k = 1, S1; Task 2):
## 1. a 1.5 m³ deposit of spoil_radius: the loose volume over the box of 6 around S1 is 1.5 m³, the disc
##    fresh (compaction 0) and masked;
## 2. three pushes of radius 2 along +z: the loose volume over the box holds and its centre moves forward;
## 3. four tamps of radius 2: after three the loose cells' compaction is 0.75, after the fourth they are folded
##    (loose, compaction and material 0) and the surface gained the disc's loose volume over the swell;
## 4. a 0.5 m³ spill at S1 + (0, 10): the window's sheet water plus its pore water grew by 0.5 m³;
## 5. 30 bore ticks at S1 + (0, 20), 10 a second: the counter's landings add up to the annulus between the
##    surfaces before and after, no tick wet, the disc 1 m down, its clay under the surface, its material by
##    the strata;
## 6. pack_tiles of six resident tiles, S1's first: two lists, the second reusing slot 0; every blob lands,
##    and S1's tile holds the window's loose.
## slump (k = 2, S2; Task 3): from here on the sim lists' GPU time per active tile and the active tile count
## are recorded every frame.
## 1. a wall (an obstacle of radius 1 at S2 + (0, 3)), then a 30 m³ deposit of radius 1 (a 5.6 m column),
##    left to settle: the loose volume over the box of 24 is 30 m³, the steepest slope from a loose cell to a
##    neighbour it may flow into is at repose (dry, 35°), the pile reached S2 - (0, 3) on its open side and
##    none of it the wall, and the tile is packed (its blob holds the window's loose at S2);
## 2. the wall lifted: the pile slumps on into the wall's cells, volume and repose kept.
## seam (θ = 0 on the spawn's row): a 20 m³ deposit of radius 2 at cell (0, row) settles with its volume kept
##    over the box of 24, and both tiles of the seam, 127 and 0, were active.
## ends (the station's last rows): a radius-2 deposit at row n_z - 2 is refused (it would leave the
##    station); a 20 m³ one at n_z - 3 settles against the end with its volume kept.
## sheet (k = -1, S3): a 2 m³ spill of water spreads (after 3 s, the cells over 5 mm deep are counted) and
##    soaks: the window's sheet water, its pore water and what reservoirs absorbed add up to 2 m³ within 2 %,
##    and every cell whose saturation rose is dirt-topped and within 3.05 m of a cell that was wet. A water
##    read every 0.5 s marks the wet cells: this phase carries the driver's own synchronous reads. The player
##    stands 12 m before S3 facing it (the sheet runs about 8 m down the slope toward it), and 7 s after the
##    spill, a sheet still standing (it has soaked away by the time it settles) and the dirt round it
##    darkened, the shot (below) saves user://debug/tool_puddle.png.
## walk (k = -2, S4; Task 4): a 12 m³ deposit of radius 2 settles; the player, stood 8 m before it along -z
##    and facing +z, holds W for 1.5 s and walks over it: at least 10 pushes, no landing counted, the loose
##    volume over the box of 24 kept within 0.5 %, its loose-weighted mean row 0.1 cells further on, and the
##    feet (1 m under the player's origin) never more than 0.3 m under surface + loose at their cell. The
##    feet are sampled every 0.1 s of the walk, a synchronous surface and loose read each: this phase too
##    carries the driver's own reads.
## jumps (S4): stood on the pile's highest cell, the player jumps four times 1.2 s apart: at least four
##    tamps, the solid gained over the box above 0.1 m³ and, times the swell, the loose lost within 1 %, and
##    at least one cell folded (no loose, surface risen).
## The auger (Task 5), back at the spawn, at A = spawn_cell + (6, 0), its spoil side (1, 0):
## bore: an auger placed at A bores to depth in 30 ± 2 s: the counter's landings add up to the annulus between
##    the surfaces within 0.1 %, the loose over the box of 24 is that times the swell and what it deposited
##    within 0.5 %, the shaft is 10 m down and bare, no loose within 2 cells of A (decision 6), the pile at
##    repose, no tick refused; the edit-shape landings at most 5 a second over the bore and at most one zone
##    move (printed and asserted). Then, the auger still standing, the player at the spawn faces spinward
##    onto the pile and the shot saves user://debug/tool_pile.png.
## box: a 1 m box dropped 2 m over the pile's top comes to rest within 8 s (a cube cannot balance on the apex,
##    so it may roll down), its lowest corner on the collider and at surface + loose of the cell where it
##    rests, inside the pile's box of 24.
## pickup: the auger picked up, the shaft stays bare for 1 s; a 2 m³ column on the cell beside the shaft's
##    rim slumps into the open hole, the box's loose growing by 2 m³.
## pause: an auger at A + (0, 20), a second one refused; with the player 600 m spinward its ticks are refused
##    and stop, and resume when it is back; it is picked up while its ticks are in flight (no ERROR line).
## pump (Task 7): at the first of the five lakes nearest the spawn whose four cells from the shore on are dirt
##    (the shore found along the column of the player, stood 6 m past the lake's +z rim, outward from the
##    lake's centre row), an auger three cells into the water, its spoil side (0, 1), pumps onto the bank for
##    10 s: its mode reads pump, at least 8 m³ pumped, and the cells holding sheet water as it stops stand on
##    average no higher than the spoil disc (it ran downhill; once settled, the sheet has soaked in or run into
##    the lake). Picked up and settled (at most 15 s): the window's sheet, pore and absorbed water add up to
##    what was pumped within 2 %, water_surface bitwise unchanged, every cell whose saturation rose dirt-topped
##    and within 3.05 m of a cell that was wet or a reservoir. A water read every 0.5 s marks the wet cells, as
##    in sheet.
## rock: at NoiseReport.rock_site, first 1 m³ spilled on the lowest all-rock spoil disc within 3 cells of the
##    player's cell + (0, 4) pools in that rock hollow: after 3 s the saturation is bitwise unchanged, nothing
##    absorbed, the window's sheet 1 m³ within 2 %. Then an auger 3 cells spinward of the player stops at rock
##    before 10 m, its counter matching the annulus, every shaft cell at its bedrock_top; then back to the spawn.
## Persistence (Task 8), back at the spawn:
## scroll (k = 3, S6): a 20 m³ deposit of radius 2, 0.3 s on still slumping (a tile active), is read over the
##    box of 24; the player goes 600 m spinward (S6's tile evicted, packed as it leaves) and back: the pile's
##    volume is kept within 0.1 % at once (its blob re-applied) and within 0.5 % once settled, at repose; the
##    window's water (sheet plus pore water, the sheet phase's puddle among it), read before and after over the
##    same wanted set, within 2 %.
## restart (S7 = spawn_cell + (-6, 0)): an auger bores there, its spoil side (-1, 0); 8 s on, mid-bore, the
##    terrain restarts in-process (_restart): the edited tiles load from the world copy, no auger stands, and
##    stood at S7 the hole's surface is within two bore steps, the loose over the box of 24 within 0.3 m³ + 1 %
##    (one tick's spoil at most) and the window's water within 2 % of what they were before.
## A shot tilts the camera down under the light bar's noon, waits 6 frames, saves the screenshot and levels the
## camera, then runs the P dump (debug_window_dump.gd) and checks its loose volume against the driver's over the
## window within 1 %.
## Then prints the GPU times of the edit (stamp), pack and sim lists against their budget, reported and not
## asserted (Vulkan only: Metal reports zeros, shown as n/a), and PASS and exits 0 when every check holds,
## else FAIL and 1. The driver runs on WORLD, a copy of the default world (params.tres and maps.res copied when
## missing, its tiles/ emptied at every start) with persist_edits on, so the default world's saved edits are
## neither loaded nor written, and the restart has its own tiles to load. Last, a small deposit makes a tile
## active and the run quits at once, so Terrain._exit_tree packs it synchronously during the engine's quit (the
## path an in-process restart does not take); the line printed then says whether its blob landed, and an ERROR
## line fails the run when it did not.
## After editing a .glsl run `godot --headless --path . --import` first (the suite does it).
## Run: godot --rendering-driver vulkan --path . res://terrain/tool_run.tscn
extends Node

const Smoke := preload("res://terrain/smoke_run.gd")
## The GPU budget of the edit and pack lists in ms, and of the sim list per active tile.
const BUDGET := {"edit": 0.5, "pack": 0.5}
const SIM_BUDGET := 0.25
## The edge neighbours in sim.glsl's order, then the diagonal ones, which loose slumps to as well.
const DIR4: Array[Vector2i] = [Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(0, -1)]
const DIAG: Array[Vector2i] = [Vector2i(1, 1), Vector2i(-1, 1), Vector2i(-1, -1), Vector2i(1, -1)]
## The world the driver runs on, under user://worlds/.
const WORLD := "tool_run"

## The instance of main.tscn, and its nodes the driver uses (_open_main binds them, again after _restart).
var _main: Node
var _station: Station
var _terrain: Terrain
var _ok := true
## Every timed GPU list in order: {name, ms}.
var _timed: Array[Dictionary] = []
## The bore's counter landings: m³ summed, how many landed, whether any tick pumped.
var _bored := 0.0
var _bore_landed := 0
var _bore_wet := false
var _player: Player
var _tools: Tools
## The phase running from slump on ("" before): the active tile count every frame, every tile seen active, and
## per phase each sim list's GPU time per active tile (when the count held for the five frames before it was
## timed) and the most tiles active at once.
var _phase := ""
var _counts: Array[int] = []
var _seen := {}
var _sim_ms := {}
var _active_max := {}
## The edit-shape landings and zone moves counted while the bore phase records them, and the last zone seen.
var _edit_bakes := 0
var _zone_moves := 0
var _last_zone := Vector2i.ZERO
## The sim steps of the terrains _restart freed.
var _steps := 0


func _ready() -> void:
	_fresh_world()
	if await _open_main():
		_route()


## Copies the default world's params.tres and maps.res into WORLD when missing and removes every file under its
## tiles/; the default world is only read.
func _fresh_world() -> void:
	var dir := "user://worlds/%s/" % WORLD
	DirAccess.make_dir_recursive_absolute(dir + "tiles")
	for file: String in ["params.tres", "maps.res"]:
		if not FileAccess.file_exists(dir + file) and DirAccess.copy_absolute("user://worlds/default/" + file, dir + file) != OK:
			push_error("Copying the default world's %s into %s failed." % [file, dir])
	for file in DirAccess.get_files_at(dir + "tiles"):
		DirAccess.remove_absolute(dir + "tiles/" + file)


## Instantiates main.tscn on WORLD with persist_edits on, binds the driver to its nodes and its overlay's timed,
## adds it and waits for its first collider patch, then a frame (collider_live fires inside the patch's readback
## landing, where no GPU work may be issued). False after quitting when the patch is not live in 1200 frames.
func _open_main() -> bool:
	_main = load("res://main.tscn").instantiate()
	_station = _main.get_node("Station")
	_terrain = _station.get_node("Terrain")
	_terrain.world_name = WORLD
	_terrain.persist_edits = true
	_player = _station.get_node("Player")
	_tools = _main.get_node("Tools")
	_main.get_node("Panel/Box/Timing").timed.connect(_on_timed)
	var live := [false]
	_terrain.collider_live.connect(func() -> void: live[0] = true, CONNECT_ONE_SHOT)
	add_child(_main)
	for i in 1200:
		await get_tree().process_frame
		if live[0]:
			await get_tree().process_frame
			return true
	return _quit("The first collider patch did not go live in 1200 frames.")


## The in-process restart: frees main.tscn (Terrain._exit_tree packs its active tiles and saves the edits) and,
## two frames on, opens it again (_open_main). False after quitting on a timeout.
func _restart() -> bool:
	_steps += _terrain.sim.steps
	_main.queue_free()
	await _frames(2)
	return await _open_main()


## A timed GPU list, and for a sim list its time per active tile when the count held for the five frames before.
func _on_timed(pass_name: String, ms: float) -> void:
	_timed.append({"name": pass_name, "ms": ms})
	var recent := _counts.slice(-5)
	if pass_name == "sim" and not _phase.is_empty() and recent.size() == 5 and recent.min() == recent.max() and recent[0] > 0:
		_per_tile(_phase).append(ms / recent[0])


## The route is scripted: a stray click must not capture the mouse, nor mouse movement turn the player.
func _input(event: InputEvent) -> void:
	if event is InputEventMouse:
		get_viewport().set_input_as_handled()


func _process(_delta: float) -> void:
	# Within _restart, _terrain is freed until _open_main binds the next one.
	if _phase.is_empty() or not is_instance_valid(_terrain):
		return
	var active := _terrain.sim.active_tiles()
	_counts.append(active.size())
	_active_max[_phase] = maxi(_active_max.get(_phase, 0), active.size())
	for t in active:
		_seen[t] = true


## The sim times per active tile recorded in phase.
func _per_tile(phase: String) -> Array[float]:
	if not _sim_ms.has(phase):
		var fresh: Array[float] = []
		_sim_ms[phase] = fresh
	return _sim_ms[phase]


func _route() -> void:
	var p := _terrain.params
	var spawn := p.cell_of(_terrain.maps.spawn.x, _terrain.maps.spawn.y)
	await _stamps(spawn + Vector2i(0, 40))
	_phase = "slump"
	await _slump(spawn + Vector2i(0, 80))
	_phase = "seam"
	if not await _seam(spawn.y):
		return
	_phase = "ends"
	if not await _ends(spawn):
		return
	_phase = "sheet"
	if not await _sheet(spawn + Vector2i(0, -40)):
		return
	var s4 := spawn + Vector2i(0, -80)
	_phase = "walk"
	if not await _walk(s4):
		return
	_phase = "jumps"
	if not await _jumps(s4):
		return
	if not await _teleport(spawn):
		return
	var a := spawn + Vector2i(6, 0)
	_phase = "bore"
	if not await _bore(a):
		return
	_phase = "box"
	await _box_drop(a)
	_phase = "pickup"
	await _pickup(a)
	_phase = "pause"
	if not await _pause(a, spawn):
		return
	_phase = "pump"
	if not await _pump():
		return
	_phase = "rock"
	if not await _rock(spawn):
		return
	_phase = "scroll"
	if not await _scroll(spawn + Vector2i(0, 120), spawn):
		return
	_phase = "restart"
	if not await _restart_mid_bore(spawn + Vector2i(-6, 0)):
		return
	_phase = ""
	# Let the last timestamps arrive.
	await _frames(6)
	_summary()
	print("PASS" if _ok else "FAIL")
	await _quit_active(spawn + Vector2i(0, 40))


## Phase stamps at s1: deposit, push, tamp, spill, bore and the pack's slot reuse (see the header).
func _stamps(s1: Vector2i) -> void:
	var t := _terrain.tool_params
	var swell := _terrain.materials.swell_factor[0]
	var box := _box(s1, 6)

	_stamp(_op(s1, t.spoil_radius, EditLayer.MODE_DEPOSIT, 1.5))
	await _frames(3)
	var loose := _read("loose")
	var surface := _read("surface")
	var compaction := _read("compaction")
	var mask := _read("edit_mask")
	var deposited := _vol(loose, surface, box)
	var fresh := true
	for c in _disc(s1, t.spoil_radius):
		fresh = fresh and _b(compaction, c) == 0 and _b(mask, c) == 255
	print("deposit: %.6f m³ loose over the box for 1.5 m³ (%+.4f %%), disc fresh and masked: %s" % [
			deposited, (deposited / 1.5 - 1.0) * 100.0, fresh])
	_report("deposit conserves", absf(deposited - 1.5) <= 1.5e-3 and fresh)

	var row0 := _mean_row(loose, surface, box, s1)
	for i in 3:
		_stamp(_op(s1, 2, EditLayer.MODE_PUSH, t.push_share, Vector2i(0, 1), t.push_max))
		await _frames(3)
	loose = _read("loose")
	surface = _read("surface")
	var pushed := _vol(loose, surface, box)
	var row1 := _mean_row(loose, surface, box, s1)
	print("push: %.6f m³ loose over the box, was %.6f (%+.3f ppm); mean row %+.4f -> %+.4f cells" % [
			pushed, deposited, (pushed / deposited - 1.0) * 1e6, row0, row1])
	_report("push moves forward, conserves", absf(pushed - deposited) <= 1e-4 * deposited and row1 - row0 >= 0.05)

	var tamp_disc := _disc(s1, 2)
	for i in 3:
		_stamp(_op(s1, 2, EditLayer.MODE_TAMP, t.tamp_step, Vector2i.ZERO, swell))
		await _frames(3)
	loose = _read("loose")
	surface = _read("surface")
	compaction = _read("compaction")
	var tamped: Array[Vector2i] = []
	var bytes: Array[int] = []
	for c in tamp_disc:
		if _f(loose, c) > 1e-3:
			tamped.append(c)
			bytes.append(_b(compaction, c))
	var at_three := not tamped.is_empty() and bytes.all(func(k: int) -> bool: return absi(k - 191) <= 1)
	var disc_loose := _vol(loose, surface, tamp_disc)
	_stamp(_op(s1, 2, EditLayer.MODE_TAMP, t.tamp_step, Vector2i.ZERO, swell))
	await _frames(3)
	var loose4 := _read("loose")
	var surface4 := _read("surface")
	var compaction4 := _read("compaction")
	var material4 := _read("material")
	var folded := true
	for c in tamped:
		folded = folded and _f(loose4, c) == 0.0 and _b(compaction4, c) == 0 and _b(material4, c) == 0
	var gain := 0.0
	for c in tamp_disc:
		gain += (_f(surface4, c) - _f(surface, c)) * _area(_f(surface, c))
	var want := disc_loose / swell
	print("tamp: %d loose cells, compaction bytes after three %s; after four folded: %s, solid gained %.6f m³ for %.6f m³ loose / %.2f = %.6f (%+.4f %%)" % [
			tamped.size(), bytes, folded, gain, disc_loose, swell, want, (gain / want - 1.0) * 100.0])
	_report("tamp folds with the swell", at_three and folded and absf(gain - want) <= 1e-3 * want)

	var sat0 := _read("saturation")
	var water0 := _sum(_read("water_depth"), _read("surface"))
	_stamp(_op(s1 + Vector2i(0, 10), 2, EditLayer.MODE_SPILL, 0.5))
	await _frames(3)
	surface = _read("surface")
	var sheet := _sum(_read("water_depth"), surface) - water0
	var pore := _pore(sat0, _read("saturation"), _read("material"), _read("loose"), surface)
	print("spill: sheet %+.6f m³, pore %+.6f m³ for 0.5 m³ (%+.4f %%)" % [sheet, pore, ((sheet + pore) / 0.5 - 1.0) * 100.0])
	_report("spill conserves", absf(sheet + pore - 0.5) <= 0.02 * 0.5)

	var b := s1 + Vector2i(0, 20)
	var bore_box := _box(b, 3)
	var s0 := _read("surface")
	for i in 30:
		var op := _op(b, t.bore_radius, EditLayer.MODE_BORE, t.bore_step, Vector2i.ZERO, t.pump_rate / t.bore_rate)
		op.counted = _on_bored
		_stamp(op)
		await get_tree().create_timer(1.0 / t.bore_rate).timeout
	await _frames(5)
	var s30 := _read("surface")
	var bedrock := _read("bedrock_top")
	var clay_bottom := _read("clay_bottom")
	var clay_top := _read("clay_top")
	var material := _read("material")
	var removed := _removed(s0, s30, bore_box)
	var drops: Array[String] = []
	var dropped := true
	var strata := true
	for c in _disc(b, t.bore_radius):
		var s := _f(s30, c)
		var top := 2 if _f(bedrock, c) >= s - 0.01 else (1 if _f(clay_top, c) >= s - 0.01 else 0)
		drops.append("%.5f" % (_f(s0, c) - s))
		dropped = dropped and absf(_f(s0, c) - s - 1.0) <= 1e-3
		strata = strata and _f(clay_top, c) <= s and _f(clay_bottom, c) <= s and _b(material, c) == top
	print("bore: %d of 30 ticks landed, counter %.6f m³, annulus %.6f m³ (%+.4f %%), wet %s; drops %s m, strata and material by the rule: %s" % [
			_bore_landed, _bored, removed, (_bored / removed - 1.0) * 100.0, _bore_wet, drops, strata])
	_report("bore counts what it cut", _bore_landed == 30 and absf(_bored - removed) <= 1e-3 * removed and not _bore_wet
			and dropped and strata)

	var window := _terrain.window
	var tile := window.tile_of_cell(s1.x, s1.y)
	var tiles: Array[Vector2i] = [tile]
	for r in window.resident_tiles():
		if tiles.size() < 6 and r != tile:
			tiles.append(r)
	for r in tiles:
		window.edits.blobs.erase(r)
	window.edits.pack_tiles(window, tiles)
	await _frames(4)
	loose = _read("loose")
	# S1 itself was folded by the tamp: the cell of S1's tile with the most loose in the box stands for it.
	var probe := s1
	for c in box:
		if window.tile_of_cell(c.x, c.y) == tile and _f(loose, c) > _f(loose, probe):
			probe = c
	var landed := tiles.all(func(x: Vector2i) -> bool: return window.edits.blobs.has(x))
	var same := false
	if landed:
		var o := EditLayer.cell_offset(posmod(probe.x, TerrainWindow.TILE), posmod(probe.y, TerrainWindow.TILE))
		var blob: PackedByteArray = window.edits.blobs[tile]
		same = _f(loose, probe) > 0.0 and blob.decode_u32(o + 24) == loose.decode_u32(4 * _texel(probe)) \
				and blob.decode_u32(o + 20) >> 24 == 255
	print("pack: %d tiles %s, all landed: %s; %s in %s: %.6f m loose, blob matches the window and is masked: %s" % [
			tiles.size(), tiles, landed, probe, tile, _f(loose, probe), same])
	_report("pack slots reused across lists", landed and same)


## Phase slump at s2: a pile settles at repose against a wall, then slumps on once the wall goes (see the
## header).
func _slump(s2: Vector2i) -> void:
	var box := _box(s2, 24)
	var wall := s2 + Vector2i(0, 3)
	var walled := _disc(wall, 1)
	var repose := tan(deg_to_rad(_terrain.materials.repose_dry[0])) * 1.02
	var before := _vol(_read("loose"), _read("surface"), box)
	_terrain.set_obstacle(wall, 1)
	_stamp(_op(s2, 1, EditLayer.MODE_DEPOSIT, 30.0))
	var waited := await _settled(s2)
	var loose := _read("loose")
	var piled := _vol(loose, _read("surface"), box) - before
	var steep := _steepest(box, walled)
	var wall_max: float = walled.map(func(c: Vector2i) -> float: return _f(loose, c)).max()
	var tile := _terrain.window.tile_of_cell(s2.x, s2.y)
	print("slump: settled and packed in %.2f s; %.6f m³ over the box for 30 m³ (%+.4f %%); steepest %.4f, repose · 1.02 %.4f; %.4f m at S2 - (0, 3); wall cells' loose max %.6f m" % [
			waited, piled, (piled / 30.0 - 1.0) * 100.0, steep, repose, _f(loose, s2 - Vector2i(0, 3)), wall_max])
	_report("pile settles at repose against the mask, conserved, packed", waited >= 0.0 and absf(piled - 30.0) <= 0.005 * 30.0
			and steep <= repose and _f(loose, s2 - Vector2i(0, 3)) > 0.01 and wall_max < 1e-6 and not _terrain.sim.has_active()
			and _terrain.window.edits.blobs.has(tile))

	_terrain.set_obstacle(TerrainSim.NO_CELL, -1)
	waited = await _settled(s2)
	loose = _read("loose")
	var slumped := _vol(loose, _read("surface"), box) - before
	var steep2 := _steepest(box, [])
	var into: float = walled.map(func(c: Vector2i) -> float: return _f(loose, c)).max()
	print("mask lifted: settled in %.2f s; %.6f m³ over the box (%+.4f %% of the settled pile); wall cells' loose max %.4f m; steepest %.4f" % [
			waited, slumped, (slumped / piled - 1.0) * 100.0, into, steep2])
	_report("mask lifts, the pile slumps on", waited >= 0.0 and absf(slumped - piled) <= 0.005 * piled and into > 0.05
			and steep2 <= repose)
	print("slump: sim per active tile %s; active tiles max %d" % [Smoke._stat(_per_tile("slump"), SIM_BUDGET), _active_max.get("slump", 0)])


## Phase seam at θ = 0 on row: a pile across the seam keeps its volume, both seam tiles active.
func _seam(row: int) -> bool:
	_terrain.teleport(0.0, _terrain.maps.spawn.y)
	if not await _settled_patch():
		return false
	var site := Vector2i(0, row)
	var box := _box(site, 24)
	var before := _vol(_read("loose"), _read("surface"), box)
	_seen.clear()
	_stamp(_op(site, 2, EditLayer.MODE_DEPOSIT, 20.0))
	var waited := await _settled(site)
	var piled := _vol(_read("loose"), _read("surface"), box) - before
	@warning_ignore("integer_division")
	var tiles: Array[Vector2i] = [Vector2i(_terrain.window.tiles_around - 1, row / TerrainWindow.TILE), Vector2i(0, row / TerrainWindow.TILE)]
	var both := tiles.all(func(t: Vector2i) -> bool: return _seen.has(t))
	print("seam: settled in %.2f s; %.6f m³ over the box for 20 m³ (%+.4f %%); tiles %s seen active: %s" % [
			waited, piled, (piled / 20.0 - 1.0) * 100.0, tiles, both])
	_report("seam pile", waited >= 0.0 and absf(piled - 20.0) <= 0.005 * 20.0 and both)
	return true


## Phase ends at the station's last rows: a disc that would leave the station is refused, one on the last
## rows it may use settles against the end with its volume kept. Back to the spawn after.
func _ends(spawn: Vector2i) -> bool:
	var p := _terrain.params
	_terrain.teleport(_terrain.maps.spawn.x, -p.length / 2.0 + p.n_z() - 4)
	if not await _settled_patch():
		return false
	var refused := not _terrain.stamp_tool(_op(Vector2i(spawn.x, p.n_z() - 2), 2, EditLayer.MODE_DEPOSIT, 20.0))
	var site := Vector2i(spawn.x, p.n_z() - 3)
	var box := _box(site, 24)
	var before := _vol(_read("loose"), _read("surface"), box)
	_stamp(_op(site, 2, EditLayer.MODE_DEPOSIT, 20.0))
	var waited := await _settled(site)
	var piled := _vol(_read("loose"), _read("surface"), box) - before
	print("ends: row %d refused: %s; row %d settled in %.2f s, %.6f m³ over the box for 20 m³ (%+.4f %%)" % [
			p.n_z() - 2, refused, site.y, waited, piled, (piled / 20.0 - 1.0) * 100.0])
	_report("end rows", refused and waited >= 0.0 and absf(piled - 20.0) <= 0.005 * 20.0)
	_terrain.teleport(_terrain.maps.spawn.x, _terrain.maps.spawn.y)
	return await _settled_patch()


## Phase sheet at s3: a spill spreads, soaks and wets dirt within the wetting distance, its water accounted
## for over the whole window (see the header). False after quitting on a timeout.
func _sheet(s3: Vector2i) -> bool:
	if not await _teleport(s3 - Vector2i(0, 12)):
		return false
	_face(Vector3(0, 0, 1))
	var surface := _read("surface")
	var sheet0 := _sum(_read("water_depth"), surface)
	var sat0 := _read("saturation")
	var absorbed0 := _terrain.sim.absorbed
	var wet := PackedByteArray()
	wet.resize(sat0.size())
	_mark_wet(wet)
	_stamp(_op(s3, 2, EditLayer.MODE_SPILL, 2.0))
	var start := Time.get_ticks_msec()
	var sampling := [true]
	_sample_wet(wet, sampling)
	await get_tree().create_timer(3.0).timeout
	var deep := Array(_read("water_depth").to_float32_array()).filter(func(d: float) -> bool: return d > 0.005).size()
	# The shot 7 s after the spill: a sheet still stands and the dirt round it has darkened (see the header).
	await get_tree().create_timer(4.0).timeout
	await _shot("tool_puddle")
	var waited := await _settled(s3, 12.0)
	sampling[0] = false
	_mark_wet(wet)
	surface = _read("surface")
	var sheet := _sum(_read("water_depth"), surface) - sheet0
	var sat1 := _read("saturation")
	var material := _read("material")
	var loose := _read("loose")
	var pore := _pore(sat0, sat1, material, loose, surface)
	var absorbed := _terrain.sim.absorbed - absorbed0
	var total := sheet + pore + absorbed
	# The cells whose saturation rose, and the wet ones, over a box around the site; none may rise outside it.
	var risen: Array[Vector2i] = []
	var wet_cells: Array[Vector2i] = []
	for c in _box(s3, 48):
		var k := _texel(c)
		if sat1[k] > sat0[k]:
			risen.append(c)
		if wet[k]:
			wet_cells.append(c)
	var risen_all := 0
	for k in sat1.size():
		risen_all += int(sat1[k] > sat0[k])
	var far := 0.0
	var dirt := true
	for c in risen:
		dirt = dirt and (_f(loose, c) > 0.01 or _b(material, c) == 0)
		far = maxf(far, _nearest(c, wet_cells, surface))
	print("sheet: %d cells over 5 mm after 3 s; settled in %.2f s (%.1f s after the spill); sheet %+.6f, pore %+.6f, absorbed %+.6f m³: %.6f for 2 m³ (%+.3f %%)" % [
			deep, waited, (Time.get_ticks_msec() - start) / 1000.0, sheet, pore, absorbed, total, (total / 2.0 - 1.0) * 100.0])
	print("sheet: %d cells wet, %d saturation rose (%d in the window), all dirt-topped: %s, farthest from a wet cell %.3f m" % [
			wet_cells.size(), risen.size(), risen_all, dirt, far])
	_report("water spreads and soaks within 3 m", deep >= 15 and absf(total - 2.0) <= 0.02 * 2.0 and risen.size() == risen_all
			and not risen.is_empty() and dirt and far <= 3.05)
	return true


## Phase walk at s4: the player walks over a settled pile, pushing it on and standing on it (see the header).
## False after quitting on a timeout.
func _walk(s4: Vector2i) -> bool:
	var box := _box(s4, 24)
	_stamp(_op(s4, 2, EditLayer.MODE_DEPOSIT, 12.0))
	var waited := await _settled(s4)
	var surface := _read("surface")
	var loose := _read("loose")
	var v0 := _vol(loose, surface, box)
	var row0 := _mean_row(loose, surface, box, s4)
	if not await _teleport(s4 - Vector2i(0, 8)):
		return false
	_face(Vector3(0, 0, 1))
	await get_tree().create_timer(0.5).timeout
	var pushes0 := _tools.pushes
	var tamps0 := _tools.tamps
	var low := INF
	_press(KEY_W, true)
	for i in 15:
		await get_tree().create_timer(0.1).timeout
		low = minf(low, _feet_clearance())
	_press(KEY_W, false)
	await get_tree().create_timer(2.0).timeout
	var waited2 := await _settled(s4)
	surface = _read("surface")
	loose = _read("loose")
	var v1 := _vol(loose, surface, box)
	var row1 := _mean_row(loose, surface, box, s4)
	var pushes := _tools.pushes - pushes0
	print("walk: pile settled in %.2f s, again in %.2f s after; %d pushes, %d landings counted; %.6f m³ loose over the box, was %.6f (%+.4f %%); mean row %+.4f -> %+.4f cells (%+.4f); lowest feet %+.3f m" % [
			waited, waited2, pushes, _tools.tamps - tamps0, v1, v0, (v1 / v0 - 1.0) * 100.0, row0, row1, row1 - row0, low])
	_report("walking pushes forward, conserves, stands on it", waited >= 0.0 and waited2 >= 0.0 and pushes >= 10
			and _tools.tamps == tamps0 and absf(v1 - v0) <= 0.005 * v0 and row1 - row0 >= 0.1 and low >= -0.3)
	return true


## Phase jumps at s4: four landings on the pile's top fold it, the solid gained accounting for the loose lost
## (see the header). False after quitting on a timeout.
func _jumps(s4: Vector2i) -> bool:
	var box := _box(s4, 24)
	var surface := _read("surface")
	var loose := _read("loose")
	var top := s4
	for c in box:
		if _f(surface, c) + _f(loose, c) > _f(surface, top) + _f(loose, top):
			top = c
	if not await _teleport(top):
		return false
	var waited := await _settled(top)
	var s0 := _read("surface")
	var l0 := _read("loose")
	var tamps0 := _tools.tamps
	for i in 4:
		var gap := get_tree().create_timer(1.2)
		_press(KEY_SPACE, true)
		await _frames(3)
		_press(KEY_SPACE, false)
		if i < 3:
			await gap.timeout
	await get_tree().create_timer(2.0).timeout
	var waited2 := await _settled(top)
	var s1 := _read("surface")
	var l1 := _read("loose")
	var solid_gain := 0.0
	var loose_lost := 0.0
	var folded := 0
	for c in box:
		var area := _area(_f(s0, c))
		solid_gain += (_f(s1, c) - _f(s0, c)) * area
		loose_lost += (_f(l0, c) - _f(l1, c)) * area
		folded += int(_f(l1, c) == 0.0 and _f(s1, c) > _f(s0, c))
	var swell := _terrain.materials.swell_factor[0]
	var tamps := _tools.tamps - tamps0
	print("jumps: at %s (%.3f m loose), settled in %.2f s, again in %.2f s after; %d tamps; solid gained %.6f m³ · %.2f = %.6f for %.6f m³ loose lost (%+.4f %%); %d cells folded" % [
			top, _f(l0, top), waited, waited2, tamps, solid_gain, swell, solid_gain * swell, loose_lost,
			(solid_gain * swell / loose_lost - 1.0) * 100.0, folded])
	_report("four landings fold the patch, volume accounted", waited >= 0.0 and waited2 >= 0.0 and tamps >= 4
			and solid_gain > 0.1 and absf(solid_gain * swell - loose_lost) <= 0.01 * loose_lost and folded > 0)
	return true


## Phase bore at a: an auger bores to depth and heaps its spoil beside itself, conserved and clear of the rim,
## the collider following at most 5 times a second (see the header). False after quitting on a timeout.
func _bore(a: Vector2i) -> bool:
	var t := _terrain.tool_params
	var swell := _terrain.materials.swell_factor[0]
	var box := _box(a, 24)
	var shaft := _disc(a, t.bore_radius)
	var s0 := _read("surface")
	var l0 := _vol(_read("loose"), s0, box)
	_edit_bakes = 0
	_zone_moves = 0
	_last_zone = _terrain.patch.zone
	var zone0 := _last_zone
	_terrain.patch.baked.connect(_on_baked)
	var start := Time.get_ticks_msec()
	var at := _center(a)
	var auger := _tools.place(at.x, at.y, Vector2i(1, 0))
	if auger == null:
		return _quit("The auger was not placed at %s." % a)
	var reason := await _stopped(auger, 40.0)
	var wall := (Time.get_ticks_msec() - start) / 1000.0
	_terrain.patch.baked.disconnect(_on_baked)
	if reason.is_empty():
		return _quit("The auger did not stop in 40 s.")
	var waited := await _settled(auger.spoil_cell())
	var s1 := _read("surface")
	var loose := _read("loose")
	var removed := _removed(s0, s1, shaft)
	var piled := _vol(loose, s1, box) - l0
	var drops: Array[String] = []
	var bare := true
	for c in shaft:
		drops.append("%.4f" % (_f(s0, c) - _f(s1, c)))
		bare = bare and _f(loose, c) < 1e-6 and absf(_f(s0, c) - _f(s1, c) - t.bore_depth) <= 0.05
	# The most loose within 2 cells of a (the shaft and its rim ring), and where.
	var rim_at := a
	for c in _disc(a, 2):
		if _f(loose, c) > _f(loose, rim_at):
			rim_at = c
	var rim := _f(loose, rim_at)
	# The pile's reach: how near A's centre the nearest cell holding over 1 cm of loose lies, in m.
	var piled_cells: Array[Vector2i] = []
	piled_cells.assign(box.filter(func(c: Vector2i) -> bool: return _f(loose, c) > 0.01))
	var reach := _nearest(a, piled_cells, s1)
	var steep := _steepest(box, shaft)
	var repose := tan(deg_to_rad(_terrain.materials.repose_dry[0])) * 1.02
	print("bore: stopped (%s) after %.2f s, %d ticks, depth %.4f m, %d refused; settled in %.2f s; counter %.6f m³, annulus %.6f m³ (%+.4f %%)" % [
			reason, wall, auger.ticks, auger.depth, auger.refused, waited, auger.removed, removed, (auger.removed / removed - 1.0) * 100.0])
	print("bore: loose %.6f m³ over the box for %.6f · %.2f = %.6f (%+.4f %%), deposited %.6f (%+.4f %%); shaft drops %s m, bare: %s; loose within 2 cells max %.6f m at A %+d, %+d, the nearest over 1 cm %.2f m from A; steepest %.4f, repose · 1.02 %.4f" % [
			piled, removed, swell, removed * swell, (piled / (removed * swell) - 1.0) * 100.0, auger.deposited,
			(piled / auger.deposited - 1.0) * 100.0, drops, bare, rim, rim_at.x - a.x, rim_at.y - a.y, reach, steep, repose])
	var rate := _edit_bakes / wall
	print("bore: %d edit-shape landings in %.2f s: %.2f a second; %d zone moves (the zone was at %s, A is %s)" % [
			_edit_bakes, wall, rate, _zone_moves, zone0, a])
	_report("bore to depth, spoil conserved and clear of the rim", reason == "depth" and waited >= 0.0
			and absf(auger.removed - removed) <= 1e-3 * removed and absf(piled - removed * swell) <= 0.005 * removed * swell
			and absf(piled - auger.deposited) <= 0.005 * auger.deposited and bare and rim <= 0.01 and steep <= repose
			and auger.refused == 0)
	# The throttle lands the first touch at once and then one per 0.2 s: 1 + floor(wall / 0.2) at most.
	_report("bore in 30 ± 2 s, edit-shape landings at most 5 a second, at most one zone move", absf(wall - 30.0) <= 2.0
			and rate <= 5.0 + 1.0 / wall and _zone_moves <= 1)
	var theta := Cyl.theta_of(_station.to_local(_player.global_position))
	_face(Vector3(cos(theta), sin(theta), 0))
	await _shot("tool_pile")
	return true


## Counts the edit-shape landings and the zone moves among them for the bore phase. Inside the readback flush:
## stores only. An edit landing is for the last zone requested (edit_run's rule).
func _on_baked(kind: String, _ms: float) -> void:
	if kind != "edit":
		return
	_edit_bakes += 1
	if _terrain.patch._issued_zone != _last_zone:
		_zone_moves += 1
		_last_zone = _terrain.patch._issued_zone


## Phase box: a 1 m box dropped 2 m over the pile's top comes to rest on the collider where it ends up, by the
## pile (see the header).
func _box_drop(a: Vector2i) -> void:
	var loose := _read("loose")
	var top := a
	for c in _box(a, 24):
		if _f(loose, c) > _f(loose, top):
			top = c
	var patch := _terrain.patch
	var box: Box = load("res://box.tscn").instantiate()
	box.station = _station
	box.setup(1.0, 8.0, 0.0)
	_station.add_child(box)
	var at := _center(top)
	box.global_transform = _station.global_transform * Transform3D(patch.transform.basis,
			patch.surface_point(Cyl.position(at.x, at.y, 0.0, _terrain.params.radius), 2.0))
	# Still: under 0.05 m/s for 0.25 s on end, from 0.5 s on (it starts at rest in the air); at most 8 s.
	var start := Time.get_ticks_msec()
	var still_since := -1
	while Time.get_ticks_msec() - start < 8000:
		await get_tree().process_frame
		var now := Time.get_ticks_msec()
		if now - start < 500 or box.linear_velocity.length() >= 0.05:
			still_since = -1
		elif still_since < 0:
			still_since = now
		elif now - still_since >= 250:
			break
	var waited := (Time.get_ticks_msec() - start) / 1000.0
	var q := _station.to_local(box.global_position)
	var c := _terrain.params.cell_of(Cyl.theta_of(q), q.z)
	# Its bottom: its lowest corner's height, which is centre - 0.5 for a level box; it may rest tilted against
	# the pile's foot. The tilt is from the nearest of its axes to the local up.
	var bottom := INF
	for i in 8:
		var corner := Vector3(i & 1, (i >> 1) & 1, (i >> 2) & 1) - Vector3.ONE * 0.5
		bottom = minf(bottom, Cyl.height_of(_station.to_local(box.global_transform * corner), _terrain.params.radius))
	var up := -_station.down_at(box.global_position)
	var b := box.global_basis.orthonormalized()
	var tilt := rad_to_deg(acos(minf(maxf(maxf(absf(b.x.dot(up)), absf(b.y.dot(up))), absf(b.z.dot(up))), 1.0)))
	loose = _read("loose")
	var ground := _f(_read("surface"), c) + _f(loose, c)
	var corner := _corner_clearance(box)
	var speed := box.linear_velocity.length()
	print("box: dropped over %s (%.3f m loose), after %.2f s at %s, top %+d, %+d (%.3f m loose): %.4f m/s, tilted %.1f°, lowest corner %+.4f m over the collider, bottom %+.4f m over surface + loose" % [
			top, _f(loose, top), waited, c, c.x - top.x, c.y - top.y, _f(loose, c), speed, tilt, corner, bottom - ground])
	_report("box comes to rest on the collider by the pile", speed < 0.05 and corner >= -0.05 and corner <= 0.1
			and absf(bottom - ground) <= 0.1 and _box(a, 24).has(c))
	box.queue_free()


## Phase pickup at a: the picked-up auger's shaft stays bare, and a column beside its rim slumps into it (see
## the header).
func _pickup(a: Vector2i) -> void:
	var box := _box(a, 24)
	var shaft := _disc(a, _terrain.tool_params.bore_radius)
	var before := _vol(_read("loose"), _read("surface"), box)
	_tools.pickup()
	await get_tree().create_timer(1.0).timeout
	var loose := _read("loose")
	var held: float = shaft.map(func(c: Vector2i) -> float: return _f(loose, c)).max()
	var gone := _tools.auger == null
	# Settled at the column's own cell: the shaft's centre holds no loose before the column slumps, so its
	# blob would match the window before the column's activity flag has even landed.
	var column := a + Vector2i(0, 2)
	_stamp(_op(column, 0, EditLayer.MODE_DEPOSIT, 2.0))
	var waited := await _settled(column)
	loose = _read("loose")
	var after := _vol(loose, _read("surface"), box)
	var fell: float = shaft.map(func(c: Vector2i) -> float: return _f(loose, c)).max()
	print("pickup: auger gone: %s, shaft loose max %.6f m after 1 s; a 2 m³ column at %s settled in %.2f s: %.6f m³ over the box, was %.6f + 2 (%+.4f %%); shaft loose max %.4f m" % [
			gone, held, column, waited, after, before, (after / (before + 2.0) - 1.0) * 100.0, fell])
	_report("pickup opens the hole", gone and held < 1e-6 and waited >= 0.0 and absf(after - before - 2.0) <= 0.005 * (before + 2.0)
			and fell > 0.05)


## Phase pause at a + (0, 20): one auger at a time; its ticks are refused while the player is 600 m away and
## resume when it is back; picked up with ticks in flight (see the header). False after quitting on a timeout.
func _pause(a: Vector2i, spawn: Vector2i) -> bool:
	var at := _center(a + Vector2i(0, 20))
	var first := _tools.place(at.x, at.y, Vector2i(0, 1))
	at = _center(a)
	var second := _tools.place(at.x, at.y, Vector2i(1, 0))
	_report("one auger at a time", first != null and second == null and _tools.auger == first)
	if first == null:
		return true
	await get_tree().create_timer(1.0).timeout
	var bored := first.ticks
	var away := spawn + Vector2i(roundi(600.0 / (_terrain.params.radius * _terrain.params.dtheta())), 0)
	if not await _teleport(away):
		return false
	var ticks0 := first.ticks
	await get_tree().create_timer(1.0).timeout
	var ticks1 := first.ticks
	var refused := first.refused
	if not await _teleport(spawn):
		return false
	var ticks2 := first.ticks
	await get_tree().create_timer(2.0).timeout
	var ticks3 := first.ticks
	print("pause: %d ticks in the first second; 600 m away at %s: ticks %d -> %d over 1 s, %d refused; back: ticks %d -> %d over 2 s" % [
			bored, away, ticks0, ticks1, refused, ticks2, ticks3])
	_tools.pickup()
	_report("pause and resume", bored > 0 and refused > 0 and ticks1 == ticks0 and ticks3 > ticks2)
	return true


## Phase pump at the first of the five lakes nearest the spawn with dirt past its shore: an auger three cells
## into the water pumps onto the bank for 10 s; the water runs downhill and soaks dirt within 3 m, the lake's
## water_surface is unchanged, and the sheet, pore and absorbed water add up to what was pumped (see the
## header). False after quitting on a timeout.
func _pump() -> bool:
	var found: Array[Vector2i] = [TerrainSim.NO_CELL]
	if not await _lake_shore(found):
		return false
	var a := found[0]
	if a == TerrainSim.NO_CELL:
		_report("pumped water runs downhill, soaks dirt within 3 m, lake unchanged (no lake with a dirt bank)", false)
		return true
	var surface := _read("surface")
	var sat0 := _read("saturation")
	var ws0 := _read("water_surface")
	var sheet0 := _sum(_read("water_depth"), surface)
	var absorbed0 := _terrain.sim.absorbed
	var wet := PackedByteArray()
	wet.resize(sat0.size())
	_mark_wet(wet)
	var sampling := [true]
	_sample_wet(wet, sampling)
	var at := _center(a)
	var auger := _tools.place(at.x, at.y, Vector2i(0, 1))
	if auger == null:
		sampling[0] = false
		return _quit("The auger was not placed at %s." % a)
	await get_tree().create_timer(10.0).timeout
	var mode := auger.mode
	var pumped := auger.spilled
	var ticks := auger.ticks
	var spoil := auger.spoil_cell()
	# It ran downhill: the mean ground under the sheet as the pump stops against the spoil disc's (once settled
	# the sheet has soaked in or run into the lake, a film on a cell or two left at most). Pumping changes
	# neither the surface nor the loose.
	var loose := _read("loose")
	var d := _read("water_depth").to_float32_array()
	var s := surface.to_float32_array()
	var l := loose.to_float32_array()
	var held := 0
	var held_ground := 0.0
	for k in d.size():
		if d[k] > 0.0:
			held += 1
			held_ground += s[k] + l[k]
	held_ground /= maxi(held, 1)
	var disc := _disc(spoil, _terrain.tool_params.spoil_radius)
	var spoil_ground := 0.0
	for c in disc:
		spoil_ground += _f(surface, c) + _f(loose, c)
	spoil_ground /= disc.size()
	_tools.pickup()
	var waited := await _settled(spoil, 15.0)
	sampling[0] = false
	_mark_wet(wet)
	surface = _read("surface")
	loose = _read("loose")
	var material := _read("material")
	var depth := _read("water_depth")
	var sat1 := _read("saturation")
	var sheet := _sum(depth, surface) - sheet0
	var pore := _pore(sat0, sat1, material, loose, surface)
	var absorbed := _terrain.sim.absorbed - absorbed0
	var total := sheet + pore + absorbed
	# The cells whose saturation rose, and the wet and reservoir ones, over a box around A; none may rise
	# outside it.
	var risen: Array[Vector2i] = []
	var near: Array[Vector2i] = []
	for c in _box(a, 48):
		var k := _texel(c)
		if sat1[k] > sat0[k]:
			risen.append(c)
		if wet[k] or _f(ws0, c) > _f(surface, c) + _f(loose, c) + 1e-3:
			near.append(c)
	var risen_all := 0
	for k in sat1.size():
		risen_all += int(sat1[k] > sat0[k])
	var far := 0.0
	var dirt := true
	for c in risen:
		dirt = dirt and (_f(loose, c) > 0.01 or _b(material, c) == 0)
		far = maxf(far, _nearest(c, near, surface))
	var lake_kept := _read("water_surface") == ws0
	print("pump: at %s, spoil at %s; mode %s, %d ticks, pumped %.6f m³; settled in %.2f s; sheet %+.6f, pore %+.6f, absorbed %+.6f m³: %.6f for %.6f (%+.3f %%)" % [
			a, spoil, mode, ticks, pumped, waited, sheet, pore, absorbed, total, pumped, (total / pumped - 1.0) * 100.0])
	print("pump: %d cells wet or reservoir by A, %d saturation rose (%d in the window), all dirt-topped: %s, farthest from a wet or reservoir cell %.3f m; water_surface unchanged: %s; %d cells held sheet water as the pump stopped, mean ground %.3f m, the spoil disc's %.3f m" % [
			near.size(), risen.size(), risen_all, dirt, far, lake_kept, held, held_ground, spoil_ground])
	_report("pumped water runs downhill, soaks dirt within 3 m, lake unchanged", mode == "pump" and pumped >= 8.0
			and absf(total - pumped) <= 0.02 * pumped and lake_kept and not risen.is_empty() and risen.size() == risen_all
			and dirt and far <= 3.05 and held > 0 and held_ground <= spoil_ground)
	return true


## For the five lakes nearest the spawn, nearest first: the player is teleported 6 m past the lake's +z rim
## and the shore found along its column, the first dry cell (water_surface at most surface + 1 mm) after a
## wet run outward from the lake's centre row; the first lake whose four cells from the shore on are dirt
## gives out[0] = three cells into the water from its shore. Prints each lake tried; out[0] stays NO_CELL when
## none qualifies. False after quitting on a timeout.
func _lake_shore(out: Array[Vector2i]) -> bool:
	var p := _terrain.params
	var window := _terrain.window
	var spawn := _terrain.maps.spawn
	var from_spawn := func(l: Dictionary) -> float:
		return Vector2(wrapf(l.theta - spawn.x, -PI, PI) * p.radius, l.z - spawn.y).length()
	var lakes := _terrain.maps.lakes.duplicate()
	lakes.sort_custom(func(l: Dictionary, m: Dictionary) -> bool: return from_spawn.call(l) < from_spawn.call(m))
	for lake: Dictionary in lakes.slice(0, 5):
		_terrain.teleport(lake.theta, lake.z + lake.radius + 6.0)
		if not await _settled_patch():
			return false
		var ws := _read("water_surface")
		var surface := _read("surface")
		var material := _read("material")
		var c := Vector2i(_tools.player_cell().x, p.cell_of(lake.theta, lake.z).y)
		var wet := false
		var shore := -1
		while window.is_resident(window.tile_of_cell(c.x, c.y)):
			if _f(ws, c) > _f(surface, c) + 1e-3:
				wet = true
			elif wet:
				shore = c.y
				break
			c.y += 1
		var banks: Array[int] = []
		if shore >= 0:
			for i in 4:
				banks.append(_b(material, Vector2i(c.x, shore + i)))
		print("pump: lake %s, %.0f m from the spawn: shore row %d on column %d, materials %s" % [
				lake, from_spawn.call(lake), shore, c.x, banks])
		if banks.count(0) == 4:
			out[0] = Vector2i(c.x, shore - 3)
			return true
	return true


## rock_spill, in the rock phase before its auger: 1 m³ spilled as the pump spills (a spoil_radius disc) on the
## lowest cell within 3 of the player's cell + (0, 4) whose disc is all rock pools on the rock: after 3 s the
## saturation is bitwise unchanged, nothing was absorbed and the window's sheet holds the 1 m³ within 2 %. The
## site's 1 m detail leaves dirt pockets (2 cm covers) among the rock and its summit is flat, so a sheet
## spilled elsewhere there reaches dirt within 3 s and soaks, as dirt should; a hollow keeps it on the rock.
func _rock_spill() -> void:
	var r := _terrain.tool_params.spoil_radius
	var surface := _read("surface")
	var material := _read("material")
	var from := _tools.player_cell() + Vector2i(0, 4)
	var spill := TerrainSim.NO_CELL
	for c in _box(from, 3):
		if _disc(c, r).all(func(d: Vector2i) -> bool: return _b(material, d) >= 2) \
				and (spill == TerrainSim.NO_CELL or _f(surface, c) < _f(surface, spill)):
			spill = c
	if spill == TerrainSim.NO_CELL:
		_report("rock does not soak (no all-rock disc within 3 cells of %s)" % from, false)
		return
	var sat0 := _read("saturation")
	var absorbed0 := _terrain.sim.absorbed
	var water0 := _sum(_read("water_depth"), surface)
	_stamp(_op(spill, r, EditLayer.MODE_SPILL, 1.0))
	await get_tree().create_timer(3.0).timeout
	var depth := _read("water_depth")
	var water := _sum(depth, _read("surface")) - water0
	var held := Array(depth.to_float32_array()).filter(func(d: float) -> bool: return d > 0.0).size()
	var dry := _read("saturation") == sat0
	var absorbed := _terrain.sim.absorbed - absorbed0
	print("rock spill: 1 m³ at %s (%+d, %+d from the player's cell + (0, 4), %.3f m below it); after 3 s the sheet %.6f m³ on %d cells (%+.4f %%), saturation unchanged: %s, absorbed %+.6f m³" % [
			spill, spill.x - from.x, spill.y - from.y, _f(surface, from) - _f(surface, spill), water, held, (water - 1.0) * 100.0, dry, absorbed])
	_report("rock does not soak", dry and absorbed == 0.0 and absf(water - 1.0) <= 0.02)


## Phase rock at NoiseReport.rock_site: spilled water pools on bare rock without soaking (_rock_spill), then an
## auger stops at rock before its depth, every shaft cell at its bedrock_top (see the header). Back to the
## spawn after. False after quitting on a timeout.
func _rock(spawn: Vector2i) -> bool:
	var site := NoiseReport.rock_site(_terrain.maps, _terrain.params)
	_terrain.teleport(site.x, site.y)
	if not await _settled_patch():
		return false
	await _rock_spill()
	var t := _terrain.tool_params
	var c := _tools.player_cell() + Vector2i(3, 0)
	var shaft := _disc(c, t.bore_radius)
	var s0 := _read("surface")
	var bedrock := _read("bedrock_top")
	var at := _center(c)
	var start := Time.get_ticks_msec()
	var auger := _tools.place(at.x, at.y, Vector2i(1, 0))
	if auger == null:
		return _quit("The auger was not placed at the rock site %s." % c)
	var reason := await _stopped(auger, 10.0)
	var wall := (Time.get_ticks_msec() - start) / 1000.0
	var s1 := _read("surface")
	var removed := _removed(s0, s1, shaft)
	var cover: Array[String] = []
	var floored := true
	for x in shaft:
		cover.append("%.3f" % (_f(s0, x) - _f(bedrock, x)))
		floored = floored and absf(_f(s1, x) - _f(bedrock, x)) <= 1e-3
	print("rock: at %s, cover %s m; stopped (%s) after %.2f s at depth %.4f m, %d ticks; counter %.6f m³, annulus %.6f m³ (%+.4f %%); shaft at bedrock_top: %s" % [
			c, cover, reason, wall, auger.depth, auger.ticks, auger.removed, removed,
			(auger.removed / removed - 1.0) * 100.0 if removed > 0.0 else 0.0, floored])
	_report("rock floors the bore", reason == "rock" and auger.depth < t.bore_depth and absf(auger.removed - removed) <= 1e-3 * removed
			and floored)
	_tools.pickup()
	return await _teleport(spawn)


## Phase scroll at s6, from the spawn: a pile mid-slump is packed as the window scrolls away from it and
## re-applied when it comes back, and the window's water is kept (see the header). False after quitting on a
## timeout.
func _scroll(s6: Vector2i, spawn: Vector2i) -> bool:
	var window := _terrain.window
	var box := _box(s6, 24)
	_stamp(_op(s6, 2, EditLayer.MODE_DEPOSIT, 20.0))
	await get_tree().create_timer(0.3).timeout
	var slumping := _terrain.sim.active_tiles()
	var l0 := _vol(_read("loose"), _read("surface"), box)
	var w0 := _water()
	var away := spawn + Vector2i(roundi(600.0 / (_terrain.params.radius * _terrain.params.dtheta())), 0)
	if not await _teleport(away):
		return false
	var tile := window.tile_of_cell(s6.x, s6.y)
	var evicted := not window.is_resident(tile)
	if not await _teleport(spawn):
		return false
	var l1 := _vol(_read("loose"), _read("surface"), box)
	var w1 := _water()
	var waited := await _settled(s6)
	var l2 := _vol(_read("loose"), _read("surface"), box)
	var steep := _steepest(box, [])
	var repose := tan(deg_to_rad(_terrain.materials.repose_dry[0])) * 1.02
	print("scroll: active 0.3 s after a 20 m³ deposit at %s: %s; %.6f m³ over the box; 600 m away at %s, %s evicted: %s; back: %.6f m³ at once (%+.4f %%), settled in %.2f s %.6f m³ (%+.4f %%), steepest %.4f, repose · 1.02 %.4f" % [
			s6, slumping, l0, away, tile, evicted, l1, (l1 / l0 - 1.0) * 100.0, waited, l2, (l2 / l0 - 1.0) * 100.0, steep, repose])
	print("scroll: the window's water %.6f m³ before, %.6f m³ back (%+.4f %%)" % [w0, w1, (w1 / w0 - 1.0) * 100.0])
	_report("pile survives a scroll mid-slump", not slumping.is_empty() and evicted and absf(l1 - l0) <= 1e-3 * l0
			and waited >= 0.0 and absf(l2 - l0) <= 0.005 * l0 and steep <= repose and w0 > 0.0 and absf(w1 - w0) <= 0.02 * w0)
	return true


## Phase restart at s7: an auger stopped mid-bore by an in-process restart (_restart) leaves its hole and pile,
## and the window keeps its water, from the tiles saved at the exit; no auger stands after (see the header).
## False after quitting on a timeout.
func _restart_mid_bore(s7: Vector2i) -> bool:
	var step := _terrain.tool_params.bore_step
	var box := _box(s7, 24)
	var ground := _f(_read("surface"), s7)
	var at := _center(s7)
	var auger := _tools.place(at.x, at.y, Vector2i(-1, 0))
	if auger == null:
		return _quit("The auger was not placed at %s." % s7)
	var spoil := auger.spoil_cell()
	await get_tree().create_timer(8.0).timeout
	var depth0 := auger.depth
	var surface := _read("surface")
	var hole0 := _f(surface, s7)
	var l0 := _vol(_read("loose"), surface, box)
	var w0 := _water()
	var center0 := _terrain.window.center_tile
	if not await _restart():
		return false
	var blobs := _terrain.window.edits.blobs.size()
	var gone := _tools.auger == null
	if not await _teleport(s7):
		return false
	surface = _read("surface")
	var hole1 := _f(surface, s7)
	var l1 := _vol(_read("loose"), surface, box)
	var w1 := _water()
	var waited := await _settled(spoil)
	print("restart: auger at %s, %.4f m bored after 8 s; after the restart %d blobs loaded, no auger: %s; the hole %.4f m deep, was %.4f (%+.4f m, two steps %.4f); %.6f m³ loose over the box, was %.6f (%+.6f m³, allowed %.6f); window %s, was %s" % [
			s7, depth0, blobs, gone, ground - hole1, ground - hole0, hole0 - hole1, 2.0 * step, l1, l0, l1 - l0, 0.3 + 0.01 * l0,
			_terrain.window.center_tile, center0])
	print("restart: the window's water %.6f m³ after, %.6f m³ before (%+.4f %%); settled in %.2f s" % [w1, w0, (w1 / w0 - 1.0) * 100.0, waited])
	_report("restart mid-bore keeps the hole, the pile and the puddle", blobs >= 3 and gone and absf(hole1 - hole0) <= 2.0 * step
			and absf(l1 - l0) <= 0.3 + 0.01 * l0 and w0 > 0.0 and absf(w1 - w0) <= 0.02 * w0 and waited >= 0.0)
	return true


## Waits for auger's stopped signal, at most limit s: its reason, "" on a timeout.
func _stopped(auger: Auger, limit: float) -> String:
	var reason: Array[String] = [""]
	auger.stopped.connect(func(r: String) -> void: reason[0] = r)
	var start := Time.get_ticks_msec()
	while reason[0].is_empty() and Time.get_ticks_msec() - start < limit * 1000.0:
		await get_tree().process_frame
	return reason[0]


## Fails the run at once with what: false, for the phase to return.
func _quit(what: String) -> bool:
	push_error(what)
	get_tree().quit(1)
	return false


## Tilts the camera down onto what the player faces, under the light bar's noon, waits 6 frames, saves
## user://debug/<file>.png and levels the camera; then runs the P dump as NoiseReport does and checks its loose
## volume against _sum over the window within 1 %.
func _shot(file: String) -> void:
	(_station.get_node("LightBar") as LightBar).theta = Cyl.theta_of(_station.to_local(_player.global_position))
	_player.look(Vector2(0.0, 300.0))
	await _frames(6)
	DirAccess.make_dir_recursive_absolute("user://debug")
	get_viewport().get_texture().get_image().save_png("user://debug/%s.png" % file)
	_player.look(Vector2(0.0, -300.0))
	var dump := preload("res://terrain/debug_window_dump.gd").new()
	dump.window = _terrain.window
	dump.center = _terrain.window.center_tile
	RenderingServer.call_on_render_thread(dump._dump)
	var want := _sum(_read("loose"), _read("surface"))
	print("%s: saved; the P dump's loose %.6f m³, the driver's %.6f m³ (%+.4f %%)" % [
			file, dump.loose_volume, want, (dump.loose_volume / want - 1.0) * 100.0])
	_report("P dump loose volume (%s)" % file, want > 0.0 and absf(dump.loose_volume - want) <= 0.01 * want)
	dump.free()


## The player's feet (1 m under its origin along its up) over surface + loose at their cell, from synchronous
## reads, in m: negative when they are in the ground.
func _feet_clearance() -> float:
	var q := _station.to_local(_player.global_position - _player.up_direction)
	var c := _terrain.params.cell_of(Cyl.theta_of(q), q.z)
	return Cyl.height_of(q, _terrain.params.radius) - _f(_read("surface"), c) - _f(_read("loose"), c)


## Teleports the player to the centre of cell c and waits for the collider under it (_settled_patch).
func _teleport(c: Vector2i) -> bool:
	var at := _center(c)
	_terrain.teleport(at.x, at.y)
	return await _settled_patch()


## Station-local (theta, z) of the centre of cell c.
func _center(c: Vector2i) -> Vector2:
	var p := _terrain.params
	return Vector2((c.x + 0.5) * p.dtheta(), -p.length / 2.0 + c.y + 0.5)


## Height of station-space point q over the collider under it, along the patch's up; negative when under it
## (edit_run's).
func _clearance(q: Vector3) -> float:
	var patch := _terrain.patch
	return (q - patch.surface_point(q, 0.0)).dot(patch.transform.basis.y)


## The lowest clearance among a 1 m box's eight corners (edit_run's, for any box).
func _corner_clearance(box: Node3D) -> float:
	var low := INF
	for i in 8:
		var corner := Vector3(i & 1, (i >> 1) & 1, (i >> 2) & 1) - Vector3.ONE * 0.5
		low = minf(low, _clearance(_station.to_local(box.global_transform * corner)))
	return low


## Turns the player upright to face station-space direction d (across its up), as Terrain._on_first_live
## stands it.
func _face(d: Vector3) -> void:
	var up := _station.global_basis.inverse() * -_station.down_at(_player.global_position)
	_player.global_basis = _station.global_basis * Basis(up.cross(-d), up, -d)


## Feeds a physical key through Input, as the player's own input code reads it (edit_run's).
func _press(key: Key, pressed: bool) -> void:
	var e := InputEventKey.new()
	e.keycode = key
	e.physical_keycode = key
	e.pressed = pressed
	Input.parse_input_event(e)


## Marks every texel holding sheet water in wet, from a synchronous read.
func _mark_wet(wet: PackedByteArray) -> void:
	var depth := _read("water_depth").to_float32_array()
	for k in depth.size():
		if depth[k] > 0.0:
			wet[k] = 1


## _mark_wet every 0.5 s while sampling[0] holds.
func _sample_wet(wet: PackedByteArray, sampling: Array) -> void:
	while sampling[0]:
		await get_tree().create_timer(0.5).timeout
		if sampling[0]:
			_mark_wet(wet)


## The distance in m between cell centres from c to the nearest of cells, across at the mean of the two
## cells' widths, theta the short way round.
func _nearest(c: Vector2i, cells: Array[Vector2i], surface: PackedByteArray) -> float:
	var p := _terrain.params
	var half := p.n_theta() >> 1
	var best := INF
	for w in cells:
		var across := wrapi(w.x - c.x, -half, half) * 0.5 * ((p.radius - _f(surface, c)) + (p.radius - _f(surface, w))) * p.dtheta()
		best = minf(best, Vector2(across, w.y - c.y).length())
	return best


## The engine-quit path: a small deposit at site makes a tile active, and the run quits at once, so
## Terrain._exit_tree packs it with pack_tiles_sync inside the engine's quit. The active tiles' blobs are
## dropped first; once Terrain has left the tree, the exit pack must have brought them back, else an ERROR
## line fails the run (its exit code is set before the quit).
func _quit_active(site: Vector2i) -> void:
	_stamp(_op(site, 1, EditLayer.MODE_DEPOSIT, 0.5))
	for i in 30:
		if _terrain.sim.has_active():
			break
		await get_tree().process_frame
	var tiles := _terrain.sim.active_tiles()
	var edits := _terrain.window.edits
	for t in tiles:
		edits.blobs.erase(t)
	_terrain.tree_exited.connect(func() -> void:
		var packed := not tiles.is_empty() and tiles.all(func(t: Vector2i) -> bool: return edits.blobs.has(t))
		print("exit pack: %d active tiles %s at quit, packed: %s" % [tiles.size(), tiles, packed])
		if not packed:
			push_error("exit pack: no active tile at quit, or its blob did not land"))
	get_tree().quit(0 if _ok else 1)


## A bore tick's counter landing, inside the readback flush: stores only.
func _on_bored(volume: float, wet: bool) -> void:
	_bored += volume
	_bore_landed += 1
	_bore_wet = _bore_wet or wet


## An Op with these fields that does not pack (the tools leave packing to the settle pack).
func _op(cell: Vector2i, radius: int, mode: int, amount: float, dir := Vector2i.ZERO, limit := 0.0) -> EditLayer.Op:
	var op := EditLayer.Op.new()
	op.cell = cell
	op.radius = radius
	op.mode = mode
	op.amount = amount
	op.dir = dir
	op.limit = limit
	op.pack = false
	return op


func _stamp(op: EditLayer.Op) -> void:
	if not _terrain.stamp_tool(op):
		print("stamp refused: mode %d at %s" % [op.mode, op.cell])
		_ok = false


## Waits until no tile is active and the settle pack of site's tile has landed: its blob holds the window's
## loose, water_depth and saturation at site. Returns the seconds waited, or -1 after `limit` s.
func _settled(site: Vector2i, limit := 10.0) -> float:
	var start := Time.get_ticks_msec()
	var edits := _terrain.window.edits
	var tile := _terrain.window.tile_of_cell(site.x, site.y)
	var o := EditLayer.cell_offset(posmod(site.x, TerrainWindow.TILE), posmod(site.y, TerrainWindow.TILE))
	var k := _texel(site)
	while Time.get_ticks_msec() - start < limit * 1000.0:
		await get_tree().process_frame
		if _terrain.sim.has_active() or not edits.blobs.has(tile):
			continue
		var blob: PackedByteArray = edits.blobs[tile]
		if blob.decode_u32(o + 24) == _read("loose").decode_u32(4 * k) and blob.decode_u32(o + 28) == _read("water_depth").decode_u32(4 * k) \
				and (blob.decode_u32(o + 20) >> 16) & 255 == _read("saturation")[k]:
			return (Time.get_ticks_msec() - start) / 1000.0
	print("not settled and packed at %s after %.0f s" % [site, limit])
	return -1.0


## Waits until the live patch covers the player and no bake is in flight, then 1 s (edit_run's _settled).
## False after quitting on a timeout.
func _settled_patch() -> bool:
	var frames := 0
	while not _terrain.patch.covers(_station.to_local(_player.global_position)) or _terrain.patch._pending:
		await get_tree().process_frame
		frames += 1
		if frames > 600:
			push_error("No collider patch under the player after 600 frames.")
			get_tree().quit(1)
			return false
	await get_tree().create_timer(1.0).timeout
	return true


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


## A window field's texture, read synchronously.
func _read(field: String) -> PackedByteArray:
	var out: Array[PackedByteArray] = []
	var rid := _terrain.window.texture_rid(field)
	RenderingServer.call_on_render_thread(func() -> void:
		out.append(RenderingServer.get_rendering_device().texture_get_data(rid, 0)))
	return out[0]


## The texel of cell c: tile t sits in slot t mod slots, so cell c is texel c mod size.
func _texel(c: Vector2i) -> int:
	var n := _terrain.window.size
	return posmod(c.y, n) * n + posmod(c.x, n)


## A float field's value at cell c.
func _f(bytes: PackedByteArray, c: Vector2i) -> float:
	return bytes.decode_float(4 * _texel(c))


## A byte field's value (0..255) at cell c.
func _b(bytes: PackedByteArray, c: Vector2i) -> int:
	return bytes[_texel(c)]


## The cells within half of center along each axis, theta wrapped, rows clamped to the station.
func _box(center: Vector2i, half: int) -> Array[Vector2i]:
	var p := _terrain.params
	var out: Array[Vector2i] = []
	for y in range(maxi(center.y - half, 0), mini(center.y + half, p.n_z() - 1) + 1):
		for x in range(center.x - half, center.x + half + 1):
			out.append(Vector2i(posmod(x, p.n_theta()), y))
	return out


## The cells of the disc of radius around center, as edit.glsl takes them.
func _disc(center: Vector2i, radius: int) -> Array[Vector2i]:
	var half := _terrain.params.n_theta() >> 1
	var out: Array[Vector2i] = []
	for c in _box(center, radius):
		var dx := posmod(c.x - center.x + half, 2 * half) - half
		if dx * dx + (c.y - center.y) ** 2 <= radius * radius:
			out.append(c)
	return out


## The area in m² of a cell whose surface is s.
func _area(s: float) -> float:
	return (_terrain.params.radius - s) * _terrain.params.dtheta()


## The steepest (H_c − H_n) / w from a cell of cells holding over 1 cm of loose to an edge or diagonal
## neighbour not in blocked, H = surface + loose and w sim.glsl's edge distance (the mean width across, 1 m
## along, sqrt(across² + 1) diagonally).
func _steepest(cells: Array[Vector2i], blocked: Array[Vector2i]) -> float:
	var p := _terrain.params
	var loose := _read("loose")
	var surface := _read("surface")
	var worst := -INF
	for c in cells:
		if _f(loose, c) <= 0.01:
			continue
		for d in DIR4 + DIAG:
			var n := Vector2i(posmod(c.x + d.x, p.n_theta()), c.y + d.y)
			if blocked.has(n):
				continue
			var across := 0.5 * ((p.radius - _f(surface, c)) + (p.radius - _f(surface, n))) * p.dtheta()
			var w := 1.0 if d.x == 0 else sqrt(across * across + d.y * d.y)
			worst = maxf(worst, (_f(surface, c) + _f(loose, c) - _f(surface, n) - _f(loose, n)) / w)
	return worst


## Σ v · (R − s) · Δθ over cells: the volume of a float field (loose or water_depth), in float64.
func _vol(field: PackedByteArray, surface: PackedByteArray, cells: Array[Vector2i]) -> float:
	var v := 0.0
	for c in cells:
		v += _f(field, c) * _area(_f(surface, c))
	return v


## _vol over every texel of the window.
func _sum(field: PackedByteArray, surface: PackedByteArray) -> float:
	var f := field.to_float32_array()
	var s := surface.to_float32_array()
	var v := 0.0
	for k in f.size():
		if f[k] != 0.0:
			v += f[k] * _area(s[k])
	return v


## The pore water gained between two saturation reads, over every texel: Σ (sat1 − sat0) / 255 · capacity ·
## (R − s) · Δθ, the capacity porosity · soak_column of the cell's top material, dirt where it holds loose.
func _pore(sat0: PackedByteArray, sat1: PackedByteArray, material: PackedByteArray, loose: PackedByteArray,
		surface: PackedByteArray) -> float:
	var porosity := _terrain.materials.porosity
	var column := _terrain.tool_params.soak_column
	var l := loose.to_float32_array()
	var s := surface.to_float32_array()
	var v := 0.0
	for k in sat1.size():
		if sat1[k] != sat0[k]:
			var m := 0 if l[k] > 0.01 else material[k]
			v += (sat1[k] - sat0[k]) / 255.0 * porosity[m] * column * _area(s[k])
	return v


## The window's water in m³: its sheet plus its pore water (_pore from dry ground; the detail pass leaves
## saturation 0).
func _water() -> float:
	var surface := _read("surface")
	var sat := _read("saturation")
	var dry := PackedByteArray()
	dry.resize(sat.size())
	return _sum(_read("water_depth"), surface) + _pore(dry, sat, _read("material"), _read("loose"), surface)


## The volume between surfaces s0 and s1 over cells, each cell the annulus Σ 0.5 · Δθ · (s0 − s1) ·
## (2 · (R − s0) + (s0 − s1)), the bore counter's product form.
func _removed(s0: PackedByteArray, s1: PackedByteArray, cells: Array[Vector2i]) -> float:
	var p := _terrain.params
	var v := 0.0
	for c in cells:
		var cut := _f(s0, c) - _f(s1, c)
		v += 0.5 * p.dtheta() * cut * (2.0 * (p.radius - _f(s0, c)) + cut)
	return v


## The loose-volume-weighted mean row of cells, from row origin.y.
func _mean_row(loose: PackedByteArray, surface: PackedByteArray, cells: Array[Vector2i], origin: Vector2i) -> float:
	var v := 0.0
	var moment := 0.0
	for c in cells:
		var dv := _f(loose, c) * _area(_f(surface, c))
		v += dv
		moment += dv * (c.y - origin.y)
	return moment / v


func _report(what: String, ok: bool) -> void:
	print("%s: %s" % [what, "ok" if ok else "FAILED"])
	_ok = _ok and ok


func _expect(ok: bool, what: String) -> void:
	if not ok:
		print("%s: FAILED" % what)
		_ok = false


## The timing summary, reported against the budgets and never asserted.
func _summary() -> void:
	print("---- tool run ----")
	print("machine: %s, %s; driver %s" % [OS.get_processor_name(), RenderingServer.get_video_adapter_name(),
			RenderingServer.get_current_rendering_driver_name()])
	print("GPU lists in ms (Vulkan only):")
	for pass_name: String in BUDGET:
		var ms: Array[float] = []
		for t in _timed:
			if t.name == pass_name:
				ms.append(t.ms)
		print("  %-5s %s" % [pass_name, Smoke._stat(ms, BUDGET[pass_name])])
	var all: Array[float] = []
	for phase: String in _sim_ms:
		all.append_array(_sim_ms[phase])
		print("  sim   %-5s per active tile %s; active tiles max %d" % [phase, Smoke._stat(_sim_ms[phase], SIM_BUDGET), _active_max[phase]])
	print("  sim   all   per active tile %s; %d steps" % [Smoke._stat(all, SIM_BUDGET), _steps + _terrain.sim.steps])
	print("  the sheet and pump phases carry the driver's own synchronous reads (a 1 MB water read every 0.5 s), and so does")
	print("  the walk phase (a 1 MB surface and a 1 MB loose read every 0.1 s, 15 of each)")
