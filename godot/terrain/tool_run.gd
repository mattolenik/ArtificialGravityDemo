## Windowed check of the slice 3 tools (the terrain slice 3 plan, decision 13), grown phase by phase.
## Instantiates main.tscn and, once the first collider patch is live, runs each phase at its site, a cell
## spawn_cell + (0, 40 k) on the spawn's column, every stamp through Terrain.stamp_tool with tool_params
## values, reading the window synchronously three frames after each stamp. Phases:
## stamps (k = 1, S1; Task 2):
## 1. a 1.5 m³ deposit of spoil_radius: the loose volume over the box of 6 around S1 is 1.5 m³, the disc
##    fresh (compaction 0) and masked;
## 2. four tamps of radius 2: after three the loose cells' compaction is 0.75, after the fourth they are folded
##    (loose, compaction and material 0) and the surface gained the disc's loose volume over the swell;
## 4. a 0.5 m³ spill at S1 + (0, 10): the window's sheet water plus its pore water grew by 0.5 m³;
## 5. 30 bore ticks at S1 + (0, 20), 10 a second: the counter's landings add up to the annulus between the
##    surfaces before and after over the disc (its tallest walls, where the relief stands over 1 m above the
##    floor, cave a little: slope stability), no tick wet, the disc 1 m down, its clay under the surface, its
##    material by the strata;
## 6. pack_tiles of six resident tiles, S1's first: two lists, the second reusing slot 0; every blob lands,
##    and S1's blob holds the window's surface and loose words at S1 bit for bit, the cell masked.
## slump (k = 2, S2; Task 3):
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
##    and facing +z, holds W for 1.5 s and walks over it: no landing counted, the loose volume over the box of 24 kept
##    within 0.5 % (the feet's push went 2026-11-04), and the feet (1 m under the player's origin) never more than 0.3 m under surface + loose at their cell. The
##    feet are sampled every 0.1 s of the walk, a synchronous surface and loose read each: this phase too
##    carries the driver's own reads.
## jumps (S4): stood on the pile's highest cell, the player jumps four times 1.2 s apart: at least four
##    tamps, the solid gained over the box above 0.1 m³ and, times the swell, the loose lost within 1 %, and
##    at least one cell folded (no loose, surface risen).
## shovel (k = 4, S8, the player 4 cells spinward of it), through Tools.scoop_cell and dump_cell (the ball of the
## tunnels design, centred on the cell's collider point, in the voxel box; the pile is reloaded into the box
## once settled):
## 1. a 20 m³ deposit of radius 2 settles (a cone 3 m wide at the base, deep enough under the apex for a
##    ball to take loose only); a scoop at S8 holds between 0.5 and 12 m³, the loose over the box
##    of 12 dropped by what it holds within 0.1 % and the surface is bitwise unchanged (loose first);
## 2. dumped at S8 + (0, 6), the shovel is empty and the loose over the box is back within 0.1 %;
## 3. a scoop of the bare ground at B = S8 - (0, 6) holds between 0.5 and 12 m³, the annulus cut over the box
##    of 4 times the swell is what it holds within 0.1 %, the box's loose unchanged within 1e-6 m³, the disc's
##    surface lower and its clay at most the surface;
## 4. dumped back at B, the box's loose gains what was held within 0.1 % once settled; two scoops, two dumps.
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
## pickup: the auger picked up, its casing gone, the shaft caves in (slope stability): within 1 s its cells
##    hold loose; a 2 m³ column on the cell beside the rim slumps in with it; settled, the loose over the box
##    of 24 has grown by 2 m³ plus the solid cut from the box times the swell within 0.5 %, cells beyond the
##    shaft are lower, and no surface stands over a neighbour's ground (surface + loose), nor any loose cell's
##    ground over a neighbour's, steeper than dirt's dry stand slope (stable_slope_dry, 45°, within 2 %). Then
##    the player, stood 3 cells antispinward of A facing it, has the shot save user://debug/tool_cave.png.
## pause: an auger at A + (0, 20), a second one refused; with the player 600 m spinward its ticks are refused
##    and stop, and resume when it is back; it is picked up while its ticks are in flight (no ERROR line).
## pump (Task 7): at the first of the five lakes nearest the spawn whose four cells from the shore on are dirt
##    (the shore found along the column of the player, stood 6 m past the lake's +z rim, outward from the
##    lake's centre row), an auger three cells into the water, its spoil side (0, 1), pumps onto the bank for
##    10 s: its mode reads pump, at least 8 m³ pumped, and the cells holding sheet water as it stops stand on
##    average no higher than the spoil disc (it ran downhill; once settled, the sheet has soaked in or run into
##    the lake). Picked up and settled (at most 15 s): the window's sheet, pore and absorbed water add up to
##    what was pumped within 2 %, the levels kept (the shore's cells under the lake's level join it), every cell
##    whose saturation rose dirt-topped
##    and within 3.05 m of a cell that was wet or a reservoir, and the window's surface bitwise unchanged (no
##    wetted bank caved: the generated banks hold at the saturated stand slope). A water read every 0.5 s
##    marks the wet cells, as in sheet.
## lake: a bore at the shore cell S, the first dry cell outward from the pump's lake cell A along its column
##    (found now: the pump phase let the shore's cells under the level join the lake), its five-cell plus cut
##    in one stamp to 0.5 m under the lake's level (the level of the wet cell before S): settled (at
##    most 15 s), every dry cell of the plus has joined the lake (a reservoir at that level, bitwise), the
##    levels are kept over the window (a water_surface changes only by joining a reservoir beside it, from
##    under its level) and the window's water budget (sheet, pore, absorbed) moved under 0.01 m³.
## rock: at NoiseReport.rock_site, first 1 m³ spilled on the lowest all-rock spoil disc within 3 cells of the
##    player's cell + (0, 4) pools in that rock hollow: after 3 s the saturation is bitwise unchanged, nothing
##    absorbed, the window's sheet 1 m³ within 2 %. Then a scoop on a disc of bare rock (every cell at its
##    bedrock_top) within 3 cells of the same cell is accepted and holds nothing. Then an auger 3 cells spinward
##    of the player stops at rock before 10 m, its counter matching the annulus, every shaft cell at its
##    bedrock_top; then back to the spawn.
## Persistence (Task 8), back at the spawn:
## scroll (k = 3, S6): a 20 m³ deposit of radius 2, 0.3 s on still slumping (a tile active), is read over the
##    box of 24; the player goes 600 m spinward (S6's tile evicted, packed as it leaves) and back: the pile's
##    volume is kept within 0.1 % at once (its blob re-applied) and within 0.5 % once settled, at repose; the
##    window's water (sheet plus pore water, the sheet phase's puddle among it), read before and after over the
##    same wanted set, within 2 %.
## evict (S9: the first row from spawn_cell + (0, 60) outward whose five-cell plus is dry land, and S9' the
##    same from 40 rows past it, both clear of the slump and scroll piles): a 1 m³ deposit of radius 1 at S9 and, in the same frame, the player 600 m antispinward (S9's tile
##    evicted with the stamp's flag in flight); the same at S9' with one frame between the stamp and the move.
##    Six frames after each move the tile that took the stamped tile's slot is quiet unless its own blob holds
##    a pile (the flag in flight woke no entering tile); back at the spawn each
##    box of 6 has gained its 1 m³ within 0.1 % at once (its tile was packed as it left, the blob re-applied)
##    and once settled, over what it held before the stamp. The stats readbacks over the moves are printed, not asserted.
## restart (S7 = spawn_cell + (-6, 0)): an auger bores there, its spoil side (-1, 0); 8 s on, mid-bore (the hole
##    over two bore steps deep, the auger short of its depth), the terrain restarts in-process (_restart): the edited tiles load from the world copy, no auger stands, and
##    stood at S7 and settled (the shaft, uncased, caves in) the hole's surface is within two bore steps, the
##    loose over the box of 24 within 0.3 m³ + 1 % (one tick's spoil at most) of what it was plus the solid cut
##    from the box outside the shaft times the swell, and the window's water within 2 % of what it was.
## A shot tilts the camera down under the light bar's noon, waits 6 frames, saves the screenshot and levels the
## camera, then runs the P dump (debug_window_dump.gd) and checks its loose volume against the driver's over the
## window within 1 %.
## Then prints a summary, reported and not asserted (GPU times are Vulkan only: Metal reports zeros, shown as
## n/a), over the lists timed and the frames run from the stamps to the restart: each GPU pass's times against
## its budget (sim per active tile, a frame's lists summed; apply and detail per tile; the others per list);
## per phase the active tiles, the edit-shape landings and zone moves, the frame intervals and GPU frame
## times, and the driver's own synchronous reads (stalls of its making); the bore's active tile count every 2 s;
## and every conservation residual in %. Then PASS and exits 0 when every check holds, else FAIL and 1.
## The driver runs on WORLD, a copy of the default world (params.tres and maps.res copied when
## missing, its tiles/ emptied at every start) with persist_edits on, so the default world's saved edits are
## neither loaded nor written, and the restart has its own tiles to load. Last, a small deposit makes a tile
## active and the run quits at once, so Terrain._exit_tree packs it synchronously during the engine's quit (the
## path an in-process restart does not take); the line printed then says whether its blob landed, and an ERROR
## line fails the run when it did not.
## After editing a .glsl run `godot --headless --path . --import` first (the suite does it).
## Run: godot --rendering-driver vulkan --path . res://terrain/tool_run.tscn
extends Node

const Smoke := preload("res://terrain/smoke_run.gd")
## The GPU budget of each timed pass in ms (apply and detail per tile, the others per list: a pack list holds
## 1 to 4 tiles, so its time bounds the per-tile one), and of the sim lists per active tile per frame.
const BUDGET := {"edit": 0.5, "pack": 0.5, "apply": 0.5, "bake_edit": 1.0, "bake": 1.0, "detail": 2.0}
const SIM_BUDGET := 0.25
## The phases the summary reports frame by frame.
const PHASES: Array[String] = ["slump", "sheet", "walk", "jumps", "bore", "pump", "lake", "scroll", "evict"]
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
## The pump phase's lake cell (three cells into the water from its shore), for the lake phase.
var _lake_cell := TerrainSim.NO_CELL
## Cells of the window whose water_surface changed in the last _levels_kept.
var _joined := 0
var _player: Player
var _tools: Tools
## The phase running ("stamps" first, "" once done): the active tile count every frame, every tile seen active,
## per phase the sim lists' GPU time per active tile, a frame's lists summed (when the count held for the five
## frames before they were timed), and per phase _stat_of's figures.
var _phase := ""
var _counts: Array[int] = []
var _seen := {}
var _sim_ms := {}
var _stats := {}
## Whether the summary's bookkeeping runs: from ten frames into the route (the startup lists are timed by then)
## to _restart. The sim lists timed since the last frame, summed.
var _listening := false
var _sim_frame := 0.0
## The tiles of each apply and detail list in order, to pair with their times (edit_run's rule).
var _apply_tiles: Array[int] = []
var _detail_tiles: Array[int] = []
## The edit-shape landings and the zone moves among them over the run, and the last zone landed.
var _edit_bakes := 0
var _zone_moves := 0
var _last_zone := Vector2i.ZERO
## The active tile count every 2 s of the bore, and every conservation residual in % by check, in order.
var _bore_trace: Array[int] = []
var _residuals := {}
## The sim steps of the terrains _restart freed.
var _steps := 0


func _ready() -> void:
	Offscreen.apply()
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
	if not DirAccess.get_files_at(dir + "tiles").is_empty():
		push_error("Emptying %stiles failed." % dir)


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
	_terrain.patch.baked.connect(_on_baked.bind(_terrain.patch))
	for i in 1200:
		await get_tree().process_frame
		if live[0]:
			await get_tree().process_frame
			return true
	return _quit("The first collider patch did not go live in 1200 frames.")


## The in-process restart: frees main.tscn (Terrain._exit_tree packs its active tiles and saves the edits) and,
## two frames on, opens it again (_open_main). The summary's bookkeeping stops here. False after quitting on a
## timeout.
func _restart() -> bool:
	_listening = false
	_steps += _terrain.sim.steps
	_main.queue_free()
	await _frames(2)
	return await _open_main()


## A timed GPU list while listening; the overlay reads one frame's lists at a time, so the sim ones since the
## last _process are one frame's.
func _on_timed(pass_name: String, ms: float) -> void:
	if not _listening:
		return
	_timed.append({"name": pass_name, "ms": ms})
	if pass_name == "sim":
		_sim_frame += ms


## The route is scripted: a stray click must not capture the mouse, nor mouse movement turn the player.
func _input(event: InputEvent) -> void:
	if event is InputEventMouse:
		get_viewport().set_input_as_handled()


## The summary's bookkeeping, a few scalars a frame. It runs before the overlay's _process (tree order), so the
## sim lists timed since the last one are the overlay's last read.
func _process(delta: float) -> void:
	if not _listening:
		return
	var active := _terrain.sim.active_tiles()
	# The frame's sim lists per active tile, when the count held for the five frames before (they are timed
	# two or three frames after they ran).
	var recent := _counts.slice(-5)
	if _sim_frame > 0.0 and recent.size() == 5 and recent.min() == recent.max() and recent[0] > 0:
		_per_tile(_phase).append(_sim_frame / recent[0])
	_sim_frame = 0.0
	_counts.append(active.size())
	for t in active:
		_seen[t] = true
	var s := _stat_of(_phase)
	s.time += delta
	s.active += active.size()
	s.busy += int(not active.is_empty())
	s.max = maxi(s.max, active.size())
	s.cpu.append(delta * 1000.0)
	s.gpu.append(RenderingServer.viewport_get_measured_render_time_gpu(get_viewport().get_viewport_rid()))


## The figures of phase: seconds, active tile counts summed over its frames, frames with any active tile, the
## most at once, each frame's interval and GPU frame time in ms, the driver's synchronous reads, and the
## edit-shape landings and zone moves.
func _stat_of(phase: String) -> Dictionary:
	return _stats.get_or_add(phase, {"time": 0.0, "active": 0, "busy": 0, "max": 0, "cpu": [], "gpu": [], "reads": 0,
			"bakes": 0, "moves": 0})


## The sim times per active tile recorded in phase.
func _per_tile(phase: String) -> Array[float]:
	if not _sim_ms.has(phase):
		var fresh: Array[float] = []
		_sim_ms[phase] = fresh
	return _sim_ms[phase]


func _route() -> void:
	var p := _terrain.params
	var spawn := p.cell_of(_terrain.maps.spawn.x, _terrain.maps.spawn.y)
	# The startup lists are timed within a few frames; from here on every list and window move is the route's.
	await _frames(10)
	var window := _terrain.window
	window.tiles_generated.connect(func(tiles: Array[Vector2i]) -> void:
		_detail_tiles.append(tiles.size())
		var n := tiles.filter(func(t: Vector2i) -> bool: return window.edits.blobs.has(t)).size()
		if n > 0:
			_apply_tiles.append(n))
	_terrain.far.window.tiles_generated.connect(func(tiles: Array[Vector2i]) -> void: _detail_tiles.append(tiles.size()))
	_phase = "stamps"
	_listening = true
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
	_phase = "shovel"
	if not await _shovel(spawn + Vector2i(0, 160)):
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
	_phase = "lake"
	if not await _lake_fill():
		return
	_phase = "rock"
	if not await _rock(spawn):
		return
	_phase = "scroll"
	if not await _scroll(spawn + Vector2i(0, 120), spawn):
		return
	_phase = "evict"
	if not await _evict(spawn + Vector2i(0, 60), spawn):
		return
	# Nothing but the teleports buried the player: the unbury rule (Tools._physics_process) never fired outside
	# _settled_patch (the restart makes a new Tools, so the count is checked again after it).
	_expect(_tools.lifts == 0, "no lift of the player before the restart (%d)" % _tools.lifts)
	_phase = "restart"
	if not await _restart_mid_bore(spawn + Vector2i(-6, 0)):
		return
	_phase = ""
	_expect(_tools.lifts == 0, "no lift of the player in the restart phase (%d)" % _tools.lifts)
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
			deposited, _residual("deposit", deposited, 1.5), fresh])
	_report("deposit conserves", absf(deposited - 1.5) <= 1.5e-3 and fresh)

	var tamp_disc := _disc(s1, 2)
	for i in 3:
		_expect(_terrain.box.tamp(_tools.surface_point(s1), 2, t.tamp_step, swell), "tamp %d dispatched" % i)
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
	_expect(_terrain.box.tamp(_tools.surface_point(s1), 2, t.tamp_step, swell), "the fourth tamp dispatched")
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
			tamped.size(), bytes, folded, gain, disc_loose, swell, want, _residual("tamp", gain, want)])
	_report("tamp folds with the swell", at_three and folded and absf(gain - want) <= 1e-3 * want)

	var sat0 := _read("saturation")
	var water0 := _sum(_read("water_depth"), _read("surface"))
	_stamp(_op(s1 + Vector2i(0, 10), 2, EditLayer.MODE_SPILL, 0.5))
	await _frames(3)
	surface = _read("surface")
	var sheet := _sum(_read("water_depth"), surface) - water0
	var pore := _pore(sat0, _read("saturation"), _read("material"), _read("loose"), surface)
	print("spill: sheet %+.6f m³, pore %+.6f m³ for 0.5 m³ (%+.4f %%)" % [sheet, pore, _residual("spill", sheet + pore, 0.5)])
	_report("spill conserves", absf(sheet + pore - 0.5) <= 0.02 * 0.5)

	var b := s1 + Vector2i(0, 20)
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
	var removed := _removed(s0, s30, _disc(b, t.bore_radius))
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
			_bore_landed, _bored, removed, _residual("bore ticks", _bored, removed), _bore_wet, drops, strata])
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
	# S1, folded by the tamp (its surface raised by the deposit, its loose 0): the blob's surface and loose
	# words are the window's, bit for bit, and the cell is masked.
	var probe := s1
	surface = _read("surface")
	var landed := tiles.all(func(x: Vector2i) -> bool: return window.edits.blobs.has(x))
	var same := false
	if landed:
		var o := EditLayer.cell_offset(posmod(probe.x, TerrainWindow.TILE), posmod(probe.y, TerrainWindow.TILE))
		var blob: PackedByteArray = window.edits.blobs[tile]
		same = blob.decode_u32(o) == surface.decode_u32(4 * _texel(probe)) and blob.decode_u32(o + 24) == loose.decode_u32(4 * _texel(probe)) \
				and blob.decode_u32(o + 20) >> 24 == 255
	print("pack: %d tiles %s, all landed: %s; %s in %s: surface %.4f m, %.6f m loose, blob matches the window and is masked: %s" % [
			tiles.size(), tiles, landed, probe, tile, _f(surface, probe), _f(loose, probe), same])
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
			waited, piled, _residual("slump", piled, 30.0), steep, repose, _f(loose, s2 - Vector2i(0, 3)), wall_max])
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
			waited, slumped, _residual("slump lifted", slumped, piled), into, steep2])
	_report("mask lifts, the pile slumps on", waited >= 0.0 and absf(slumped - piled) <= 0.005 * piled and into > 0.05
			and steep2 <= repose)
	print("slump: sim per active tile %s; active tiles max %d" % [Smoke._stat(_per_tile("slump"), SIM_BUDGET), _stat_of("slump").max])


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
			waited, piled, _residual("seam", piled, 20.0), tiles, both])
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
			p.n_z() - 2, refused, site.y, waited, piled, _residual("ends", piled, 20.0)])
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
			deep, waited, (Time.get_ticks_msec() - start) / 1000.0, sheet, pore, absorbed, total, _residual("sheet", total, 2.0)])
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
	print("walk: pile settled in %.2f s, again in %.2f s after; %d landings counted; %.6f m³ loose over the box, was %.6f (%+.4f %%); mean row %+.4f -> %+.4f cells (%+.4f); lowest feet %+.3f m" % [
			waited, waited2, _tools.tamps - tamps0, v1, v0, _residual("walk", v1, v0), row0, row1, row1 - row0, low])
	_report("walking over a pile conserves it and stands on it", waited >= 0.0 and waited2 >= 0.0
			and _tools.tamps == tamps0 and absf(v1 - v0) <= 0.005 * v0 and low >= -0.3)
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
			_residual("jumps", solid_gain * swell, loose_lost), folded])
	_report("four landings fold the patch, volume accounted", waited >= 0.0 and waited2 >= 0.0 and tamps >= 4
			and solid_gain > 0.1 and absf(solid_gain * swell - loose_lost) <= 0.01 * loose_lost and folded > 0)
	return true


## Phase shovel at s8: a scoop takes a pile's loose first and a dump gives it back; a scoop on bare ground bites
## the solid with the swell and a dump refills the dent (see the header). False after quitting on a timeout.
func _shovel(s8: Vector2i) -> bool:
	if not await _teleport(s8 + Vector2i(4, 0)):
		return false
	var t := _terrain.tool_params
	var swell := _terrain.materials.swell_factor[0]
	var scoops0 := _tools.scoops
	var dumps0 := _tools.dumps
	var box := _box(s8, 12)
	_stamp(_op(s8, 2, EditLayer.MODE_DEPOSIT, 30.0))
	var waited := await _settled(s8)
	_terrain.box.reload(box)
	await _frames(2)
	var s0 := _read("surface")
	var l0 := _vol(_read("loose"), s0, box)
	var timed0 := _timed.size()
	var held := await _scoop(s8)
	var edit_ms := _timed.slice(timed0).filter(func(e: Dictionary) -> bool: return e.name == "edit").map(func(e: Dictionary) -> float: return e.ms)
	var s1 := _read("surface")
	var l1 := _vol(_read("loose"), s1, box)
	print("shovel: a 30 m³ pile at %s settled in %.2f s; the scoop holds %.6f m³, the loose over the box of 12 dropped %.6f m³ (%+.4f %% of it), surface unchanged: %s; its edit list %s ms" % [
			s8, waited, held, l0 - l1, _residual("scoop loose", l0 - l1, held), s1 == s0, edit_ms])
	_report("scoop takes loose first", waited >= 0.0 and held > 0.5 and held < 12.0
			and absf(l0 - l1 - held) <= 1e-3 * held and s1 == s0)
	var emptied := await _dump(s8 + Vector2i(0, 6))
	var l2 := _vol(_read("loose"), _read("surface"), box)
	print("shovel: dumped at %s, empty: %s; the loose over the box %.6f m³, was %.6f before the scoop (%+.4f %%)" % [
			s8 + Vector2i(0, 6), emptied, l2, l0, _residual("dump", l2, l0)])
	_report("dump returns it", emptied and absf(l2 - l0) <= 1e-3 * l0)
	var waited2 := await _settled(s8)
	var b := s8 + Vector2i(0, -6)
	var bbox := _box(b, 6)
	s0 = _read("surface")
	var clay_top := _read("clay_top")
	var clay_bottom := _read("clay_bottom")
	var lb0 := _vol(_read("loose"), s0, bbox) + _gap_loose(bbox)
	var bit := await _scoop(b)
	s1 = _read("surface")
	var lb1 := _vol(_read("loose"), s1, bbox) + _gap_loose(bbox)
	var lost := _swelled_loss(bbox, s0, clay_bottom, clay_top)
	var dented := _disc(b, t.scoop_radius).all(func(c: Vector2i) -> bool:
		return _f(s1, c) < _f(s0, c) and _f(clay_top, c) <= _f(s1, c) and _f(clay_bottom, c) <= _f(s1, c))
	print("shovel: settled in %.2f s; bare ground at %s: the scoop holds %.6f m³, the solid lost over the box of 6 (the surfaces' annuli less the gaps', each height by its material's swell) %.6f m³ loose-equivalent (%+.4f %%), the loose over the box %+.9f m³, the disc dented under its clay: %s" % [
			waited2, b, bit, lost, _residual("scoop solid", lost, bit), lb1 - lb0, dented])
	_report("scoop bites solid dirt with the swell", waited2 >= 0.0 and bit > 0.5 and bit < 12.0
			and absf(lost - bit) <= 1e-3 * bit and absf(lb1 - lb0) <= 1e-6 and dented)
	emptied = await _dump(b)
	var waited3 := await _settled(b)
	var lb2 := _vol(_read("loose"), _read("surface"), bbox) + _gap_loose(bbox)
	print("shovel: dumped back at %s, empty: %s, settled in %.2f s: the loose over the box of 6 gained %.6f m³ for %.6f held (%+.4f %%); %d scoops, %d dumps" % [
			b, emptied, waited3, lb2 - lb0, bit, _residual("refill", lb2 - lb0, bit), _tools.scoops - scoops0, _tools.dumps - dumps0])
	_report("dump refills", emptied and waited3 >= 0.0 and absf(lb2 - lb0 - bit) <= 1e-3 * bit
			and _tools.scoops - scoops0 == 2 and _tools.dumps - dumps0 == 2)
	return true


## Scoops at c through Tools.scoop_cell, waits for its counter to land (at most 30 frames), then 3 frames: the
## m³ the shovel holds.
func _scoop(c: Vector2i) -> float:
	_tools.scoop_cell(c)
	return await _landed_scoop()


## Scoops the ball at station-local p (Tools.scoop) and waits as _scoop does.
func _scoop_at(p: Vector3) -> float:
	_tools.scoop(p)
	return await _landed_scoop()


func _landed_scoop() -> float:
	for i in 30:
		if not _tools._scoop_pending:
			break
		await get_tree().process_frame
	await _frames(3)
	return _tools.held


## Dumps at c through Tools.dump_cell and waits for the placing to land as _scoop does: whether the shovel is
## empty.
func _dump(c: Vector2i) -> bool:
	_tools.dump_cell(c)
	for i in 30:
		if not _tools._dump_pending:
			break
		await get_tree().process_frame
	await _frames(3)
	return _tools.held == 0.0


## Phase bore at a: an auger bores to depth and heaps its spoil beside itself, conserved and clear of the rim,
## the collider following at most 5 times a second (see the header). False after quitting on a timeout.
func _bore(a: Vector2i) -> bool:
	var t := _terrain.tool_params
	var swell := _terrain.materials.swell_factor[0]
	var box := _box(a, 24)
	var shaft := _disc(a, t.bore_radius)
	var s0 := _read("surface")
	var l0 := _vol(_read("loose"), s0, box)
	var bakes0 := _edit_bakes
	var moves0 := _zone_moves
	var zone0 := _terrain.patch.zone
	var start := Time.get_ticks_msec()
	var at := _center(a)
	var auger := _tools.place(at.x, at.y, Vector2i(1, 0))
	if auger == null:
		return _quit("The auger was not placed at %s." % a)
	var tracing := [true]
	_trace(tracing)
	var reason := await _stopped(auger, 40.0)
	var wall := (Time.get_ticks_msec() - start) / 1000.0
	tracing[0] = false
	var bakes := _edit_bakes - bakes0
	var moves := _zone_moves - moves0
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
			reason, wall, auger.ticks, auger.depth, auger.refused, waited, auger.removed, removed, _residual("bore counter", auger.removed, removed)])
	print("bore: loose %.6f m³ over the box for %.6f · %.2f = %.6f (%+.4f %%), deposited %.6f (%+.4f %%); shaft drops %s m, bare: %s; loose within 2 cells max %.6f m at A %+d, %+d, the nearest over 1 cm %.2f m from A; steepest %.4f, repose · 1.02 %.4f" % [
			piled, removed, swell, removed * swell, _residual("bore spoil", piled, removed * swell), auger.deposited,
			_residual("bore deposited", piled, auger.deposited), drops, bare, rim, rim_at.x - a.x, rim_at.y - a.y, reach, steep, repose])
	var rate := bakes / wall
	print("bore: %d edit-shape landings in %.2f s: %.2f a second; %d zone moves (the zone was at %s, A is %s)" % [
			bakes, wall, rate, moves, zone0, a])
	_report("bore to depth, spoil conserved and clear of the rim", reason == "depth" and waited >= 0.0
			and absf(auger.removed - removed) <= 1e-3 * removed and absf(piled - removed * swell) <= 0.005 * removed * swell
			and absf(piled - auger.deposited) <= 0.005 * auger.deposited and bare and rim <= 0.01 and steep <= repose
			and auger.refused == 0)
	# The throttle lands the first touch at once and then one per 0.2 s: 1 + floor(wall / 0.2) at most.
	_report("bore in 30 ± 2 s, edit-shape landings at most 5 a second, at most one zone move", absf(wall - 30.0) <= 2.0
			and rate <= 5.0 + 1.0 / wall and moves <= 1)
	var theta := Cyl.theta_of(_station.to_local(_player.global_position))
	_face(Vector3(cos(theta), sin(theta), 0))
	await _shot("tool_pile")
	return true


## Counts patch's edit-shape landings and the zone moves among them, over the run and per phase. Inside the
## readback flush: stores only. An edit landing is for the last zone requested (edit_run's rule).
func _on_baked(kind: String, _ms: float, patch: ColliderPatch) -> void:
	if kind != "edit":
		return
	var moved := patch._issued_zone != _last_zone
	_last_zone = patch._issued_zone
	_edit_bakes += 1
	_zone_moves += int(moved)
	var s := _stat_of(_phase)
	s.bakes += 1
	s.moves += int(moved)


## The active tile count every 2 s into _bore_trace while tracing[0] holds.
func _trace(tracing: Array) -> void:
	while tracing[0]:
		_bore_trace.append(_terrain.sim.active_tiles().size())
		await get_tree().create_timer(2.0).timeout


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
			_terrain.ground_point(Cyl.position(at.x, at.y, 0.0, _terrain.params.radius), 2.0))
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
	var swell := _terrain.materials.swell_factor[0]
	var s0 := _read("surface")
	var before := _vol(_read("loose"), s0, box) + _gap_loose(box)
	var solid0 := _solid_volume(box)
	_tools.pickup()
	await get_tree().create_timer(1.0).timeout
	var loose := _read("loose")
	var held: float = shaft.map(func(c: Vector2i) -> float: return _f(loose, c)).max()
	var gone := _tools.auger == null
	var column := a + Vector2i(0, 2)
	_stamp(_op(column, 0, EditLayer.MODE_DEPOSIT, 2.0))
	var waited := await _settled(column, 20.0)
	loose = _read("loose")
	var s1 := _read("surface")
	var after := _vol(loose, s1, box) + _gap_loose(box)
	var cut := solid0 - _solid_volume(box)
	var want := before + 2.0 + cut * swell
	var lowered := box.filter(func(c: Vector2i) -> bool: return not shaft.has(c) and _f(s1, c) < _f(s0, c) - 0.01).size()
	var stand := tan(deg_to_rad(_terrain.materials.stable_slope_dry[0])) * 1.02
	var free := _terrain.materials.roof_span_dry[0]
	var wall := _wall_excess(box, stand, free)
	var ground := _steepest(box, [])
	print("pickup: auger gone: %s, shaft loose max %.4f m after 1 s (the walls caving); a 2 m³ column at %s settled in %.2f s: %.6f m³ loose over the box (surfaces and gaps), was %.6f + 2 + %.6f m³ solid lost (surfaces' annuli less gaps') · %.2f = %.6f (%+.4f %%; the surfaces' annuli alone %.6f m³); %d cells beyond the shaft lowered; the tallest wall over max(stand · 1.02 · w, %.1f m free) %+.4f m, ground %.4f, stand · 1.02 %.4f" % [
			gone, held, column, waited, after, before, cut, swell, want, _residual("pickup", after, want), _removed(s0, s1, box), lowered, free, wall, ground, stand])
	_report("pickup caves the shaft in to a bowl at the stand slope under the free height", gone and held > 0.05 and waited >= 0.0 and absf(after - want) <= 0.005 * want
			and lowered > 0 and wall <= 0.02 and ground <= stand)
	if not await _teleport(a + Vector2i(-3, 0)):
		return
	var theta := Cyl.theta_of(_station.to_local(_player.global_position))
	_face(Vector3(cos(theta), sin(theta), 0))
	await _shot("tool_cave")


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
	_lake_cell = a
	var surface := _read("surface")
	var sat0 := _read("saturation")
	var ws0 := _read("water_surface")
	var surface0 := surface
	var loose0 := _read("loose")
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
	var lake_kept := _levels_kept(ws0, _read("water_surface"), surface0, loose0, surface, loose)
	# No bank caved: the wetted banks stand at the saturated stand slope, so the surface is bitwise unchanged.
	var s0 := surface0.to_float32_array()
	var s1 := surface.to_float32_array()
	var cut_cells := 0
	for k in s1.size():
		cut_cells += int(s1[k] != s0[k])
	print("pump: at %s, spoil at %s; mode %s, %d ticks, pumped %.6f m³; settled in %.2f s; sheet %+.6f, pore %+.6f, absorbed %+.6f m³: %.6f for %.6f (%+.3f %%)" % [
			a, spoil, mode, ticks, pumped, waited, sheet, pore, absorbed, total, pumped, _residual("pump", total, pumped)])
	print("pump: %d cells wet or reservoir by A, %d saturation rose (%d in the window), all dirt-topped: %s, farthest from a wet or reservoir cell %.3f m; levels kept: %s (%d cells joined the lake), %d cells' surface changed; %d cells held sheet water as the pump stopped, mean ground %.3f m, the spoil disc's %.3f m" % [
			near.size(), risen.size(), risen_all, dirt, far, lake_kept, _joined, cut_cells, held, held_ground, spoil_ground])
	_report("pumped water runs downhill, soaks dirt within 3 m, lake unchanged", mode == "pump" and pumped >= 8.0
			and absf(total - pumped) <= 0.02 * pumped and lake_kept and not risen.is_empty() and risen.size() == risen_all
			and dirt and far <= 3.05 and held > 0 and held_ground <= spoil_ground and cut_cells == 0)
	return true


## lake: a bore at the shore cell S, the first dry cell outward from the pump's lake cell A along its column,
## found now (the pump phase let the shore's cells under the level join the lake), its five-cell plus cut in
## one stamp to 0.5 m under the lake's level (the level of the wet cell before S): settled (at most
## 15 s), every dry cell of the plus has joined the lake (a reservoir at that level, bitwise), the levels are
## kept over the window (_levels_kept) and the window's water budget (sheet, pore and absorbed) moved under
## 0.01 m³: no water is made or lost.
func _lake_fill() -> bool:
	var a := _lake_cell
	if a == TerrainSim.NO_CELL:
		_report("a hole at the shore joins the lake at its level (no lake with a dirt bank)", false)
		return true
	var surface := _read("surface")
	var loose := _read("loose")
	var ws0 := _read("water_surface")
	var s := a
	while s.y < a.y + 64 and _f(ws0, s) > _f(surface, s) + _f(loose, s) + 1e-3:
		s += Vector2i(0, 1)
	var level := _f(ws0, s + Vector2i(0, -1))
	var dry: Array[Vector2i] = []
	var cut := 0.0
	for c in _disc(s, 1):
		if _f(ws0, c) > _f(surface, c) + _f(loose, c) + 1e-3:
			continue
		dry.append(c)
		cut = maxf(cut, _f(surface, c) + _f(loose, c) - level + 0.5)
	var water0 := _water()
	var absorbed0 := _terrain.sim.absorbed
	_stamp(_op(s, 1, EditLayer.MODE_BORE, cut))
	# A bore changes no field _settled compares, so let its flag land and activate the tile first.
	await _frames(6)
	var waited := await _settled(s, 15.0)
	var surface1 := _read("surface")
	var loose1 := _read("loose")
	var ws1 := _read("water_surface")
	var joined := 0
	for c in dry:
		if _f(ws1, c) == level and level > _f(surface1, c) + _f(loose1, c) + 1e-3:
			joined += 1
	var kept := _levels_kept(ws0, ws1, surface, loose, surface1, loose1)
	var moved := _water() - water0 + (_terrain.sim.absorbed - absorbed0)
	print("lake: a bore of %.3f m at the shore %s (level %.3f m; %d dry cells of the plus) settled in %.2f s; %d of them joined the lake at its level, %d cells of the window joined a reservoir, levels kept: %s; the water budget moved %+.6f m³" % [
			cut, s, level, dry.size(), waited, joined, _joined, kept, moved])
	_report("a hole at the shore joins the lake at its level", waited >= 0.0 and not dry.is_empty() and joined == dry.size() and kept and absf(moved) <= 0.01)
	return true


## Whether the reservoirs' levels are kept between two water_surface reads: a cell's level changes only by
## joining them, from no reservoir (by its ground before, s0 + l0) to one (by its ground after) at the level
## of a reservoir beside it (the texture is the window's torus, so texel neighbours are cell neighbours).
## Counts the changed cells in _joined.
func _levels_kept(ws0: PackedByteArray, ws1: PackedByteArray, s0: PackedByteArray, l0: PackedByteArray,
		s1: PackedByteArray, l1: PackedByteArray) -> bool:
	var n := TerrainWindow.TILE * _terrain.window.slots
	var a := ws0.to_float32_array()
	var b := ws1.to_float32_array()
	var g0 := s0.to_float32_array()
	var m0 := l0.to_float32_array()
	var g1 := s1.to_float32_array()
	var m1 := l1.to_float32_array()
	var ok := true
	_joined = 0
	for k in b.size():
		if a[k] == b[k]:
			continue
		_joined += 1
		var x := k % n
		@warning_ignore("integer_division")
		var y := k / n
		var beside := false
		for o in DIR4:
			var kk := posmod(y + o.y, n) * n + posmod(x + o.x, n)
			beside = beside or (b[kk] == b[k] and b[kk] > g1[kk] + m1[kk] + 1e-3)
		if a[k] > g0[k] + m0[k] + 1e-3 or b[k] <= g1[k] + m1[k] + 1e-3 or not beside:
			ok = false
	return ok


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
			spill, spill.x - from.x, spill.y - from.y, _f(surface, from) - _f(surface, spill), water, held, _residual("rock spill", water, 1.0), dry, absorbed])
	_report("rock does not soak", dry and absorbed == 0.0 and absf(water - 1.0) <= 0.02)


## The cells under the shovel's ball aimed at cell c's collider point (its bounding box in the voxel box;
## more than three across on high ground, where cells are narrower).
func _ball_footprint(c: Vector2i) -> Array[Vector2i]:
	var box := _terrain.box
	var bb := box.ball_box(box.grid_of(_tools.surface_point(c)), _terrain.tool_params.scoop_ball)
	var out: Array[Vector2i] = []
	for y in range(bb[0].y, bb[0].y + bb[1].y):
		for x in range(bb[0].x, bb[0].x + bb[1].x):
			out.append(Vector2i(posmod(x, _terrain.params.n_theta()), y))
	return out


## The first cell within 12 of `from` whose ball footprint is all bare rock (every cell's surface at its
## bedrock_top), or NO_CELL.
func _bare_rock_site(from: Vector2i) -> Vector2i:
	var surface := _read("surface")
	var bedrock := _read("bedrock_top")
	var bare := func(c: Vector2i) -> bool: return _f(surface, c) <= _f(bedrock, c)
	for c in _box(from, 12):
		var foot := _ball_footprint(c)
		if not foot.is_empty() and foot.all(bare):
			return c
	return TerrainSim.NO_CELL


## A scoop on the first cell within 12 of the player's cell + (0, 4) whose ball footprint is bare rock (every
## cell's surface at its bedrock_top): accepted, it holds nothing.
func _rock_scoop() -> void:
	var surface := _read("surface")
	var from := _tools.player_cell() + Vector2i(0, 4)
	var at := _bare_rock_site(from)
	if at == TerrainSim.NO_CELL:
		_report("rock gives nothing (no bare-rock ball footprint within 12 cells of %s)" % from, false)
		return
	var scoops0 := _tools.scoops
	var held := await _scoop(at)
	print("rock scoop: at %s, accepted: %s, landed: %s, holds %.6f m³, surface unchanged: %s" % [
			at, _tools.scoops == scoops0 + 1, not _tools._scoop_pending, held, _read("surface") == surface])
	_report("rock gives nothing", _tools.scoops == scoops0 + 1 and not _tools._scoop_pending and held == 0.0)


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
	await _rock_scoop()
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
			_residual("rock counter", auger.removed, removed) if removed > 0.0 else 0.0, floored])
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
			s6, slumping, l0, away, tile, evicted, l1, _residual("scroll at once", l1, l0), waited, l2, _residual("scroll settled", l2, l0), steep, repose])
	print("scroll: the window's water %.6f m³ before, %.6f m³ back (%+.4f %%)" % [w0, w1, _residual("scroll water", w1, w0)])
	_report("pile survives a scroll mid-slump", not slumping.is_empty() and evicted and absf(l1 - l0) <= 1e-3 * l0
			and waited >= 0.0 and absf(l2 - l0) <= 0.005 * l0 and steep <= repose and w0 > 0.0 and absf(w1 - w0) <= 0.02 * w0)
	return true


## Phase evict from `from`: a stamp made in the frame of a window move, and one a frame before it, survive the
## eviction (packed as the tile leaves) and wake no entering tile (see the header). False after quitting on
## a timeout.
func _evict(from: Vector2i, spawn: Vector2i) -> bool:
	var window := _terrain.window
	var p := _terrain.params
	var away := spawn - Vector2i(roundi(600.0 / (p.radius * p.dtheta())), 0)
	var sites: Array[Vector2i] = [_dry_site(from), _dry_site(from + Vector2i(0, 40))]
	var evicted := true
	var woke := 0
	var reads := 0
	var at_once: Array[float] = []
	var settled: Array[float] = []
	for k in 2:
		var site := sites[k]
		var reads0 := _terrain.sim.stats_reads
		var tile := window.tile_of_cell(site.x, site.y)
		var slot := window.slot_of(tile)
		var before := _vol(_read("loose"), _read("surface"), _box(site, 6))
		_stamp(_op(site, 1, EditLayer.MODE_DEPOSIT, 1.0))
		await _frames(k)
		var to := _center(away)
		_terrain.teleport(to.x, to.y)
		# Terrain._process moves the window in the next frame; the flag lands within three more.
		await _frames(6)
		var taker := window.tile_at(slot)
		if _terrain.sim.is_active(taker) and not _terrain.window.edits.blobs.has(taker):
			woke += 1
		evicted = evicted and not window.is_resident(tile)
		reads += _terrain.sim.stats_reads - reads0
		if not await _settled_patch():
			return false
		if not await _teleport(spawn):
			return false
		at_once.append(_vol(_read("loose"), _read("surface"), _box(site, 6)) - before)
		var waited := await _settled(site)
		settled.append(_vol(_read("loose"), _read("surface"), _box(site, 6)) - before if waited >= 0.0 else -1.0)
	print("evict: stamps at %s (same frame) and %s (a frame before the move), 600 m away at %s, evicted: %s; slot takers woken 6 frames after the moves %d; back: the boxes gained %.6f and %.6f m³ at once (%+.4f %%, %+.4f %%), settled %.6f and %.6f m³; stats readbacks over the two moves %d" % [
			sites[0], sites[1], away, evicted, woke, at_once[0], at_once[1], _residual("evict same frame", at_once[0], 1.0),
			_residual("evict a frame before", at_once[1], 1.0), settled[0], settled[1], reads])
	_report("a stamp survives an eviction within its readback latency", evicted and woke == 0
			and absf(at_once[0] - 1.0) <= 1e-3 and absf(at_once[1] - 1.0) <= 1e-3
			and absf(settled[0] - 1.0) <= 1e-3 and absf(settled[1] - 1.0) <= 1e-3)
	return true


## The first cell from c outward along +z whose five-cell plus is dry land (no static water over any of its
## cells), within 64 rows; c itself when none is.
func _dry_site(c: Vector2i) -> Vector2i:
	var surface := _read("surface")
	var loose := _read("loose")
	var ws := _read("water_surface")
	for i in 64:
		var s := c + Vector2i(0, i)
		var dry := true
		for d in _disc(s, 1):
			dry = dry and _f(ws, d) <= _f(surface, d) + _f(loose, d) + 1e-3
		if dry:
			return s
	return c


## Phase restart at s7: an auger stopped mid-bore by an in-process restart (_restart) leaves its hole and pile,
## and the window keeps its water, from the tiles saved at the exit; no auger stands after (see the header).
## False after quitting on a timeout.
func _restart_mid_bore(s7: Vector2i) -> bool:
	var t := _terrain.tool_params
	var step := t.bore_step
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
	# Mid-bore, so the hole check is not vacuous: deeper than the two steps it allows, short of the depth.
	var mid := ground - hole0 > 2.0 * step and depth0 < t.bore_depth
	var l0 := _vol(_read("loose"), surface, box)
	var w0 := _water()
	var center0 := _terrain.window.center_tile
	if not await _restart():
		return false
	var blobs := _terrain.window.edits.blobs.size()
	var gone := _tools.auger == null
	if not await _teleport(s7):
		return false
	# Settled first: the shaft, uncased, caves in; its walls' cut joins the loose with the swell.
	var waited := await _settled(spoil, 20.0)
	var surface1 := _read("surface")
	var hole1 := _f(surface1, s7)
	var shaft := _disc(s7, t.bore_radius)
	var walls: Array[Vector2i] = []
	walls.assign(box.filter(func(c: Vector2i) -> bool: return not shaft.has(c)))
	# Under the free height (4 m of dry dirt) the uncased 2.7 m shaft stands: its walls give no loose.
	var caved := _removed(surface, surface1, walls) * _terrain.materials.swell_factor[0]
	var l1 := _vol(_read("loose"), surface1, box)
	var w1 := _water()
	print("restart: auger at %s, %.4f m bored after 8 s; after the restart %d blobs loaded, no auger: %s; the hole %.4f m deep, was %.4f (%+.4f m, two steps %.4f); %.6f m³ loose over the box (the walls gave %.6f m³, standing under the free height), was %.6f (%+.6f m³, %+.4f %%, allowed %.6f); window %s, was %s" % [
			s7, depth0, blobs, gone, ground - hole1, ground - hole0, hole0 - hole1, 2.0 * step, l1, caved, l0, l1 - l0, _residual("restart loose", l1, l0), 0.3 + 0.01 * l0,
			_terrain.window.center_tile, center0])
	print("restart: the window's water %.6f m³ after, %.6f m³ before (%+.4f %%); settled in %.2f s" % [w1, w0, _residual("restart water", w1, w0), waited])
	_report("restart mid-bore keeps the hole, the pile and the puddle", mid and blobs >= 3 and gone and absf(hole1 - hole0) <= 2.0 * step
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
	# The screenshot and the dump's six field reads are synchronous reads too.
	_stat_of(_phase).reads += 7
	var want := _sum(_read("loose"), _read("surface"))
	print("%s: saved; the P dump's loose %.6f m³, the driver's %.6f m³ (%+.4f %%)" % [
			file, dump.loose_volume, want, _residual("P dump " + file, dump.loose_volume, want)])
	_report("P dump loose volume (%s)" % file, absf(dump.loose_volume - want) <= 0.01 * want)
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
	return (q - _terrain.ground_point(q, 0.0)).dot(_terrain.patch.transform.basis.y)


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
	var stamped := edits.stamped.keys().filter(func(t: Vector2i) -> bool: return _terrain.window.is_resident(t)).size()
	for t in tiles:
		edits.blobs.erase(t)
	_terrain.tree_exited.connect(func() -> void:
		var packed := not tiles.is_empty() and tiles.all(func(t: Vector2i) -> bool: return edits.blobs.has(t))
		print("exit pack: %d active tiles %s at quit, packed: %s; %d tiles held unpacked stamps, none left unpacked: %s" % [tiles.size(), tiles, packed, stamped, edits.stamped.is_empty()])
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
		if _terrain.sim.has_active() or _terrain.box.has_active() or not edits.blobs.has(tile):
			continue
		var blob: PackedByteArray = edits.blobs[tile]
		if blob.decode_u32(o + 24) == _read("loose").decode_u32(4 * k) and blob.decode_u32(o + 28) == _read("water_depth").decode_u32(4 * k) \
				and (blob.decode_u32(o + 20) >> 16) & 255 == _read("saturation")[k]:
			return (Time.get_ticks_msec() - start) / 1000.0
	var has_blob := edits.blobs.has(tile)
	print("not settled and packed at %s after %.0f s: sim active %s %s, box active %d bricks, blob %s%s" % [
			site, limit, _terrain.sim.has_active(), _terrain.sim.active_tiles(), _terrain.box.active_bricks().size(), "present" if has_blob else "missing",
			(": loose %d vs the window's %d, depth %d vs %d" % [edits.blobs[tile].decode_u32(o + 24), _read("loose").decode_u32(4 * k), edits.blobs[tile].decode_u32(o + 28), _read("water_depth").decode_u32(4 * k)]) if has_blob else ""])
	return -1.0


## Waits until the live patch covers the player and no bake is in flight, then 1 s (edit_run's _settled).
## False after quitting on a timeout.
func _settled_patch() -> bool:
	var frames := 0
	while not _terrain.patch.covers(_station.to_local(_player.global_position)) or _terrain.patch._pending:
		await get_tree().process_frame
		frames += 1
		if frames > 600:
			push_error("No collider patch under the player after 600 frames (bake pending %s, renderer stalled %s)." % [_terrain.patch._pending, _terrain.sim.stalled()])
			get_tree().quit(1)
			return false
	await get_tree().create_timer(1.0).timeout
	# A far teleport stands the body on the first patch covering it, baked before its tiles were generated, and
	# the unbury rule lifts it when the real bake lands (the slice 3 follow-ups): those lifts are not counted.
	_tools.lifts = 0
	return true


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


## A window field's texture, read synchronously (a stall), counted in the phase.
func _read(field: String) -> PackedByteArray:
	_stat_of(_phase).reads += 1
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


## The steepest (s_c − H_n) / w from a cell of cells to an edge or diagonal neighbour, s the surface and H
## surface + loose, w as _steepest: the slope stability rule's measure of a solid wall.
func _steepest_wall(cells: Array[Vector2i]) -> float:
	var p := _terrain.params
	var loose := _read("loose")
	var surface := _read("surface")
	var worst := -INF
	for c in cells:
		for d in DIR4 + DIAG:
			var n := Vector2i(posmod(c.x + d.x, p.n_theta()), c.y + d.y)
			var across := 0.5 * ((p.radius - _f(surface, c)) + (p.radius - _f(surface, n))) * p.dtheta()
			var w := 1.0 if d.x == 0 else sqrt(across * across + d.y * d.y)
			worst = maxf(worst, (_f(surface, c) - _f(surface, n) - _f(loose, n)) / w)
	return worst


## The tallest excess in m of a solid wall step over what stands: for every cell of cells and each edge or
## diagonal neighbour, (s_c − H_n) − max(stand_tan · w, free), s the surface, H surface + loose, w as
## _steepest; the slope stability rule with the free height (VoxelBox.wall_fails).
func _wall_excess(cells: Array[Vector2i], stand_tan: float, free: float) -> float:
	var p := _terrain.params
	var loose := _read("loose")
	var surface := _read("surface")
	var worst := -INF
	for c in cells:
		for d in DIR4 + DIAG:
			var n := Vector2i(posmod(c.x + d.x, p.n_theta()), c.y + d.y)
			var across := 0.5 * ((p.radius - _f(surface, c)) + (p.radius - _f(surface, n))) * p.dtheta()
			var w := 1.0 if d.x == 0 else sqrt(across * across + d.y * d.y)
			worst = maxf(worst, (_f(surface, c) - _f(surface, n) - _f(loose, n)) - maxf(stand_tan * w, free))
	return worst


## The window's loose lying in gaps over cells: each gap's loose, m over the area at its floor.
func _gap_loose(cells: Array[Vector2i]) -> float:
	var p := _terrain.params
	var v := 0.0
	for g in 4:
		var gb := _read("gap_bottom%d" % g)
		var gl := _read("gap_loose%d" % g)
		for c in cells:
			v += _f(gl, c) * (p.radius - _f(gb, c)) * p.dtheta()
	return v


## The window's solid over cells: each column's annulus from the hull to its surface less its gaps' annuli.
func _solid_volume(cells: Array[Vector2i]) -> float:
	var p := _terrain.params
	var surface := _read("surface")
	var gb: Array[PackedByteArray] = []
	var gt: Array[PackedByteArray] = []
	for g in 4:
		gb.append(_read("gap_bottom%d" % g))
		gt.append(_read("gap_top%d" % g))
	var v := 0.0
	for c in cells:
		v += Cyl.span_volume(0.0, _f(surface, c), p.radius, p.dtheta(), 1.0)
		for g in 4:
			if _f(gt[g], c) > _f(gb[g], c):
				v -= Cyl.span_volume(_f(gb[g], c), _f(gt[g], c), p.radius, p.dtheta(), 1.0)
	return v


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


## The measurement summary, reported against the budgets and never asserted (see the header).
func _summary() -> void:
	var vp := get_viewport()
	print("---- tool run ----")
	print("machine: %s, %s" % [OS.get_processor_name(), RenderingServer.get_video_adapter_name()])
	print("driver: %s, window %s, viewport %s, display %.0f Hz, vsync mode %d" % [
			RenderingServer.get_current_rendering_driver_name(), DisplayServer.window_get_size(),
			vp.get_visible_rect().size, DisplayServer.screen_get_refresh_rate(), DisplayServer.window_get_vsync_mode()])
	print("GPU passes in ms from the stamps to the restart (Vulkan only; sim per active tile, a frame's lists summed; apply and detail per tile; the others per list, a pack list being 1 to 4 tiles):")
	var all: Array[float] = []
	for phase: String in _sim_ms:
		all.append_array(_sim_ms[phase])
	print("  %-11s %s; %d steps" % ["sim/tile", Smoke._stat(all, SIM_BUDGET), _steps + _terrain.sim.steps])
	var tiles := {"apply": _apply_tiles, "detail": _detail_tiles}
	for pass_name: String in BUDGET:
		var ms: Array[float] = []
		for t in _timed:
			if t.name == pass_name:
				ms.append(t.ms)
		var label := pass_name + ("/tile" if tiles.has(pass_name) else "")
		if tiles.has(pass_name) and not ms.is_empty():
			var n: Array[int] = tiles[pass_name]
			if ms.size() != n.size():
				print("  %-11s n/a (%d lists timed, %d issued)" % [label, ms.size(), n.size()])
				continue
			for i in ms.size():
				ms[i] /= n[i]
		print("  %-11s %s" % [label, Smoke._stat(ms, BUDGET[pass_name])])
	for phase: String in _sim_ms:
		print("  sim/tile in %-6s %s" % [phase, Smoke._stat(_sim_ms[phase], SIM_BUDGET)])
	print("per phase: active tiles mean / max and the frames with any; edit-shape landings a second and zone moves; CPU = frame interval, GPU = viewport render time; the driver's own synchronous reads (whole fields of 0.25 or 1 MB, stalls of its making: walk samples the feet every 0.1 s, sheet and pump the water every 0.5 s):")
	for phase in PHASES:
		var s := _stat_of(phase)
		var frames: int = s.cpu.size()
		print("  %-6s %5.1f s, active %.2f / %d, %d of %d frames; %.2f landings a second, %d zone moves; %s; %d reads" % [
				phase, s.time, float(s.active) / frames, s.max, s.busy, frames, s.bakes / s.time, s.moves,
				Smoke._times(s.cpu, s.gpu), s.reads])
	print("bore: active tiles every 2 s from the placement %s" % [_bore_trace])
	var residuals := PackedStringArray()
	for what: String in _residuals:
		residuals.append("%s %+.4f" % [what, _residuals[what]])
	print("conservation residuals in %%: %s" % ", ".join(residuals))


## (got / want − 1) in %, recorded under what for the summary.
func _residual(what: String, got: float, want: float) -> float:
	_residuals[what] = (got / want - 1.0) * 100.0
	return _residuals[what]


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
