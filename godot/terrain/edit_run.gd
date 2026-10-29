## Windowed check of the edit layer and of the collider following it (the terrain edits plan, Tasks 5 and 7).
## Instantiates main.tscn and, once the first collider patch is live:
## 1. teleports to theta = 0 on the spawn's row, so a dig there straddles the seam (tiles 127 and 0);
## 2. drops a 1 m box 3 m over the ground 2 m spinward of the player and lets it come to rest, then digs: 30
##    stamps of -STEP, then raises: 20 of +STEP, RADIUS cells, 10 a second (net -2.5 m at the centre),
##    through Terrain.edit directly (DebugEdit aims where the camera looks; its keys are checked by hand),
##    recording the player's and the box's clearance to the collider every frame: both must go down with the
##    ground and back up with it over the edit shape, never held and never sunk into it;
## 3. reads the window's surface and edit_mask at the centre cell and 3 cells west, across the seam;
## 4. teleports 600 m spinward: both tiles must leave the window;
## 5. teleports back: both cells must come back bitwise equal and masked (the apply pass, from the blobs), and
##    the collider must have the pit (the hole plus the edit shape); saves user://debug/edit_pit.png;
## 6. slides the box along the axis from the big patch alone, past the edit shape's edge and the hole's rim,
##    onto the edit shape alone (decision 8's one body, two shapes);
## 7. trench: after a 1 s run-up holds W for TRENCH s more digging under the player's own feet 10 times a
##    second, so the zone moves about every second: never held, never under the collider; then forces the
##    in-flight cases: two zone moves in consecutive frames, and an in-zone edit followed by a zone move in
##    the next frame; over the whole run, every big bake's hole lands after an edit bake for its zone
##    (decision 8's issue order);
## 8. prints a summary against the budgets, reported and not asserted: per GPU pass (edit, apply per tile,
##    bake_edit, bake, detail per tile) count, median, p90, max and the count over budget, walking (the
##    trench) and standing apart (Vulkan only: Metal reports zeros, shown as n/a); the CPU time of each kind
##    of bake landing; the frame interval and the GPU frame per phase; holds, falls and survived.
## Prints PASS and exits 0 when every check holds, else FAIL and 1. persist_edits is off, so nothing is saved.
## After editing a .glsl run `godot --headless --path . --import` first (the suite does it).
## Run: godot --rendering-driver vulkan --path . res://terrain/edit_run.tscn
extends Node

const Smoke := preload("res://terrain/smoke_run.gd")
const RADIUS := 5.0
const STEP := 0.25
## The rim crossing: where the box starts along the axis from the pit centre (past the edit shape's 32 m),
## where the push stops (well inside the hole's 22 cells), the push in m/s^2 and the start speed in m/s.
const RIM_START := 34.0
const RIM_INSIDE := 18.0
const RIM_PUSH := 1.0
const RIM_SPEED := 3.0
## Seconds of walking while digging.
const TRENCH := 6.0
## Frame intervals over this many ms are listed for the trench.
const SLOW := 16.0
## The GPU budget of each timed pass in ms (apply and detail per tile, the others per compute list), and the
## tighter time the two bakes are expected to come in under.
const BUDGET := {"edit": 0.5, "apply": 0.5, "bake_edit": 1.0, "bake": 1.0, "detail": 2.0}
const EXPECTED := {"bake_edit": 0.1, "bake": 0.2}
## A phase whose lowest clearance to the collider, in m, is under this counts as a fall.
const FELL := -1.0

var _station: Station
var _terrain: Terrain
var _player: Player
var _box: Box
var _started := false
var _ok := true
## Every timed GPU list from the route's start, in order: {name, ms, walking (the trench)}. How many tiles each
## apply list covered and each detail dispatch generated, in order, to pair with them.
var _timed: Array[Dictionary] = []
var _applied: Array[int] = []
var _tiles: Array[int] = []
var _listening := false
var _survived := false
## Per phase, the frame intervals and the GPU frame times in ms.
var _frames := {}
## Every bake landing in order: {kind, ms (CPU), frame, zone (the edit shape's, or the big patch's hole), phase}.
var _landings: Array[Dictionary] = []
## How many times Terrain held the player, and in which phase ("between" outside them: the scroll's teleports).
var _holds := 0
var _held_in := {}
## The phase being recorded ("" between phases) and, per phase, the lowest clearance to the collider (m,
## negative when under it) of the player's origin, the box's centre and the box's lowest corner.
var _phase := ""
var _low := {}
## Frame intervals over SLOW ms in the trench.
var _slow: Array[float] = []


func _ready() -> void:
	Offscreen.apply()
	var main: Node = load("res://main.tscn").instantiate()
	_station = main.get_node("Station")
	_terrain = _station.get_node("Terrain")
	_terrain.persist_edits = false
	_player = _station.get_node("Player")
	main.get_node("Panel/Box/Timing").timed.connect(func(pass_name: String, ms: float) -> void:
		if _listening:
			_timed.append({"name": pass_name, "ms": ms, "walking": _phase == "trench"}))
	_terrain.collider_live.connect(_route, CONNECT_ONE_SHOT)
	add_child(main)
	for i in 1200:
		if _started:
			return
		await get_tree().process_frame
	push_error("The first collider patch did not go live in 1200 frames.")
	get_tree().quit(1)


## The route is scripted: a stray click must not capture the mouse, nor mouse movement turn the player.
func _input(event: InputEvent) -> void:
	if event is InputEventMouse:
		get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	if _phase.is_empty():
		return
	var f: Dictionary = _frames.get_or_add(_phase, {"cpu": [], "gpu": []})
	f.cpu.append(delta * 1000.0)
	f.gpu.append(RenderingServer.viewport_get_measured_render_time_gpu(get_viewport().get_viewport_rid()))
	if _phase == "trench" and delta * 1000.0 > SLOW:
		_slow.append(delta * 1000.0)
	var low: Dictionary = _low.get_or_add(_phase, {"player": INF, "box": INF, "corner": INF})
	low.player = minf(low.player, _clearance(_station.to_local(_player.global_position)))
	if is_instance_valid(_box):
		low.box = minf(low.box, _clearance(_station.to_local(_box.global_position)))
		low.corner = minf(low.corner, _corner_clearance())


func _route() -> void:
	_started = true
	# collider_live fires inside the patch's readback landing, where no GPU work may be issued.
	await get_tree().process_frame
	var p := _terrain.params
	var z := _terrain.maps.spawn.y
	var window := _terrain.window
	var patch := _terrain.patch
	# The startup dispatches' timestamps arrive within a few frames; from here on the detail lists are the
	# windows' moves, which tiles_generated counts.
	for i in 10:
		await get_tree().process_frame
	window.tiles_generated.connect(func(tiles: Array[Vector2i]) -> void:
		_tiles.append(tiles.size())
		var n := tiles.filter(func(t: Vector2i) -> bool: return window.edits.blobs.has(t)).size()
		if n > 0:
			_applied.append(n))
	_terrain.far.window.tiles_generated.connect(func(tiles: Array[Vector2i]) -> void: _tiles.append(tiles.size()))
	_listening = true
	_terrain.teleport(0.0, z)
	if not await _settled():
		return

	_terrain.body_held.connect(func(held: bool) -> void:
		_holds += int(held)
		if held:
			var at := _phase if not _phase.is_empty() else "between"
			_held_in[at] = _held_in.get(at, 0) + 1)
	# Inside the readback flush: CPU only. An edit landing is for the last zone requested (no other edit
	# bake goes out before it lands); a big landing's hole is the one it was baked with.
	patch.baked.connect(func(kind: String, ms: float) -> void:
		_landings.append({"kind": kind, "ms": ms, "frame": Engine.get_process_frames(), "phase": _phase,
				"zone": patch._issued_zone if kind == "edit" else patch.hole_zone}))
	_box = load("res://box.tscn").instantiate()
	_box.station = _station
	_box.setup(1.0, 8.0, 0.0)
	_station.add_child(_box)
	var spinward := patch.transform.basis.x
	_box.global_position = _station.to_global(patch.surface_point(_local(_player) + spinward * 2.0, 3.0))
	_box.global_rotation = _station.global_rotation
	await get_tree().create_timer(2.0).timeout
	var box_slept := _box.sleeping

	var c := p.cell_of(0.0, z)
	var cells: Array[Vector2i] = [c, Vector2i(posmod(c.x - 3, p.n_theta()), c.y)]
	var before := _read(cells)
	var holds := _holds
	var h_start := Cyl.height_of(_local(_player), p.radius)
	var h_dig_end := 0.0
	_phase = "dig"
	for i in 50:
		if i == 30:
			h_dig_end = Cyl.height_of(_local(_player), p.radius)
			_phase = "raise"
		if not _terrain.edit(0.0, z, RADIUS, -STEP if i < 30 else STEP):
			print("edit %d refused" % i)
			_ok = false
			break
		await get_tree().create_timer(0.1).timeout
	for i in 3:
		await get_tree().process_frame
	var dug := _read(cells)
	await get_tree().create_timer(0.5).timeout
	_phase = ""
	var end_player := _clearance(_local(_player))
	var end_box := _clearance(_local(_box))
	var under := minf(minf(_low.dig.player, _low.raise.player), minf(_low.dig.box, _low.raise.box))
	print("dig and raise: player down %.2f m in the dig, ends %.2f m over the collider, box %.2f m (asleep before the dig: %s); lowest player %.2f m, box %.2f m; held %d" % [
			h_start - h_dig_end, end_player, end_box, box_slept, minf(_low.dig.player, _low.raise.player),
			minf(_low.dig.box, _low.raise.box), _holds - holds])
	_report("collider followed the edit", _holds == holds and h_start - h_dig_end >= 2.0
			and end_player >= 0.5 and end_player <= 2.5 and end_box >= 0.0 and end_box <= 1.5 and under >= -1.0
			and _in_hole(_local(_player)) and _in_hole(_local(_box)))
	for k in cells.size():
		print("%s %s: before %.4f m, after %.4f m (%+.4f), macro %.2f m, mask %d" % [["h_dug", "h_west"][k], cells[k],
				before[k].h, dug[k].h, dug[k].h - before[k].h, _terrain.height_at((cells[k].x + 0.5) * p.dtheta(), z), dug[k].mask])
	# 0.25 m less 1 - (3 / 5)^2 at the west cell.
	_expect(absf(dug[0].h - before[0].h + 2.5) < 0.01 and absf(dug[1].h - before[1].h + 1.6) < 0.01, "dug depth")
	_expect(dug[0].mask == 255 and dug[1].mask == 255, "mask after the dig")

	@warning_ignore("integer_division")
	var row := c.y / TerrainWindow.TILE
	_terrain.teleport(600.0 / p.radius, z)
	if not await _settled():
		return
	var left := not window.is_resident(Vector2i(0, row)) and not window.is_resident(Vector2i(127, row))
	print("left the window: %s" % ("ok" if left else "FAILED, tiles 0 and 127 resident: %s %s" % [
			window.is_resident(Vector2i(0, row)), window.is_resident(Vector2i(127, row))]))
	_ok = _ok and left

	_terrain.teleport(0.0, z)
	if not await _settled():
		return
	var back := _read(cells)
	var same := true
	for k in cells.size():
		same = same and back[k].bits == dug[k].bits and back[k].mask == 255
	_survived = same
	if same:
		print("survived the scroll: ok")
	else:
		print("survived the scroll: FAILED, %s then %s" % [dug, back])
		_ok = false
	var pit := _cell_point(c, dug[0].h)
	var h_pit := Cyl.height_of(patch.surface_point(pit, 0.0), p.radius)
	print("pit centre: collider %.3f m, window %.3f m" % [h_pit, dug[0].h])
	_report("collider has the pit", absf(h_pit - dug[0].h) <= 0.3 and _in_hole(pit))

	_player.look(Vector2(0.0, 300.0))  # tilt the camera down onto the pit
	for i in 6:
		await get_tree().process_frame
	DirAccess.make_dir_recursive_absolute("user://debug")
	get_viewport().get_texture().get_image().save_png("user://debug/edit_pit.png")

	await _rim(c)
	_box.queue_free()
	await _trench()
	await _deferred()
	_report("hole never unbacked", _unbacked().is_empty())

	# Let the last timestamps arrive.
	for i in 6:
		await get_tree().process_frame
	_summary()
	print("PASS" if _ok else "FAIL")
	get_tree().quit(0 if _ok else 1)


## Slides the box along the axis toward the pit centre (cell c) from RIM_START m out, where only the big
## patch holds it: frictionless and pushed until RIM_INSIDE m out, then with friction until it stops. It
## must end on the edit shape alone (over the hole, inside the shape's extent), within 5 cm of the surface,
## its lowest corner never more than 5 cm under the collider on the way.
func _rim(c: Vector2i) -> void:
	var patch := _terrain.patch
	var start := _cell_point(c, 0.0) + Vector3(0, 0, RIM_START)
	_box.global_transform = _station.global_transform * Transform3D(patch.transform.basis, patch.surface_point(start, 0.55))
	_box.linear_velocity = _station.global_basis * Vector3(0, 0, -RIM_SPEED)
	_box.angular_velocity = Vector3.ZERO
	var slick := PhysicsMaterial.new()
	slick.friction = 0.0
	_box.physics_material_override = slick
	_box.constant_force = _station.global_basis * Vector3(0, 0, -RIM_PUSH * _box.mass)
	var started_alone := not _in_hole(_local(_box)) and not _in_edit_extent(_local(_box))
	_phase = "rim"
	var t := 0.0
	var pushed := 0.0
	while t < 10.0:
		await get_tree().process_frame
		t += get_process_delta_time()
		var along := _local(_box).z - _cell_point(c, 0.0).z
		if pushed == 0.0 and along < RIM_INSIDE:
			pushed = t
			_box.constant_force = Vector3.ZERO
			var rough := PhysicsMaterial.new()
			rough.friction = 0.5
			_box.physics_material_override = rough
		if pushed > 0.0 and t > pushed + 1.0 and _box.linear_velocity.length() < 0.05:
			break
	_phase = ""
	var b := _local(_box)
	var end := _corner_clearance()
	print("rim: box from %.1f m (big patch alone: %s) to %.1f m in %.1f s (pushed %.1f s), on the edit shape alone: %s; lowest corner ends %.3f m over the collider, lowest on the way %.3f m" % [
			RIM_START, started_alone, b.z - _cell_point(c, 0.0).z, t, pushed, _in_hole(b) and _in_edit_extent(b), end,
			_low.rim.corner])
	_report("rim crossed", started_alone and pushed > 0.0 and _in_hole(b) and _in_edit_extent(b)
			and absf(end) <= 0.05 and _low.rim.corner >= -0.05)


## Holds W for a 1 s run-up out of the pit, then TRENCH s more while digging at the player's own cell 10
## times a second (from a standstill it would dig itself in: airborne over each new crater, it cannot gather
## speed), then releases W and waits 1 s.
func _trench() -> void:
	var holds := _holds
	var first := _landings.size()
	var refused := 0
	_phase = "trench"
	_press(KEY_W, true)
	await get_tree().create_timer(1.0).timeout
	var start := _local(_player)
	for i in roundi(TRENCH * 10.0):
		var q := _local(_player)
		refused += int(not _terrain.edit(Cyl.theta_of(q), q.z, RADIUS, -STEP))
		await get_tree().create_timer(0.1).timeout
	_press(KEY_W, false)
	await get_tree().create_timer(1.0).timeout
	_phase = ""
	var trench := _landings.slice(first)
	var bigs := trench.filter(func(l: Dictionary) -> bool: return l.kind == "big")
	var holes := {}
	for l in bigs:
		holes[l.zone] = true
	print("trench: walked %.0f m digging, %d edits refused, %d big bakes (%d zones), %d edit bakes, held %d, lowest player %.2f m; frame intervals over %.0f ms: %s" % [
			_local(_player).distance_to(start), refused, bigs.size(), holes.size(), trench.size() - bigs.size(),
			_holds - holds, _low.trench.player, SLOW, _slow])
	_report("zone moves while walking", _holds == holds and refused == 0 and holes.size() >= 3 and _low.trench.player >= 0.5)


## Every big landing of the run whose hole has no edit landing for its zone before it.
func _unbacked() -> Array[Dictionary]:
	var shaped := {}
	var out: Array[Dictionary] = []
	for l in _landings:
		if l.kind == "edit":
			shaped[l.zone] = true
		elif l.zone != ColliderPatch.NO_HOLE and not shaped.has(l.zone):
			out.append(l)
	if not out.is_empty():
		print("unbacked holes: %s" % [out])
	return out


## The in-flight cases of decision 8, digging 20 cells apart along theta behind the player: (1) two zone
## moves in consecutive frames, the first zone's bakes both in flight at the second; (2) an in-zone edit,
## then a zone move in the next frame while only its edit bake is in flight. Either way the second zone's
## edit bake must land before the big bake carrying its hole, and the player never sink under the collider.
func _deferred() -> void:
	var n := _terrain.params.n_theta()
	var at := _terrain.viewer_cell()
	var a := Vector2i(posmod(at.x - 40, n), at.y)
	var b := Vector2i(posmod(at.x - 20, n), at.y)
	# The forced edits need a quiet collider: until the trench's tiles settle, the player's last pushes are
	# re-touched while their tile is active (Terrain._retouch), and the last of those touches may still be
	# waiting in the throttle, or its bake in flight, a few frames after.
	var patch := _terrain.patch
	var quiet := false
	for i in 600:
		quiet = not (_terrain.sim.has_active() or _terrain._touch_radius >= 0 or patch._pending or patch._pending_edit
				or patch._again_edit or patch._again_big)
		if quiet:
			break
		await get_tree().process_frame
	if not quiet:
		print("deferred: the collider was not quiet after 600 frames; the forced edits run anyway")
	_phase = "deferred"
	var both_moves := await _forced(a, b, false)
	var big_idle := await _forced(b, at, true)
	_phase = ""
	print("deferred: lowest player %.2f m" % _low.deferred.player)
	_report("deferred zone move", both_moves and _low.deferred.player >= 0.0)
	_report("deferred zone move, big bake idle", big_idle and _low.deferred.player >= 0.0)


## Digs at cell first, then at cell second in the next frame, and waits 1 s. True when first's edit bake was
## in flight at the second edit (and the big bake idle, if big_idle), and second's edit bake landed before
## the first big bake with its hole.
func _forced(first: Vector2i, second: Vector2i, big_idle: bool) -> bool:
	var from := _landings.size()
	await get_tree().process_frame
	var ok := _dig_cell(first)
	await get_tree().process_frame
	var patch := _terrain.patch
	var big_pending := patch._pending
	var in_flight := patch._pending_edit and patch._issued_zone == first and big_pending != big_idle
	ok = _dig_cell(second) and ok
	await get_tree().create_timer(1.0).timeout
	var edit_at := -1
	var big_at := -1
	var trace: Array[String] = []
	for i in range(from, _landings.size()):
		var l := _landings[i]
		trace.append("%s %s f%d" % [l.kind, l.zone, l.frame])
		if l.zone == second:
			if l.kind == "edit" and edit_at < 0:
				edit_at = i
			elif l.kind == "big" and big_at < 0:
				big_at = i
	print("forced %s -> %s: first's edit bake in flight at the second edit: %s (big bake %s); landings %s" % [
			first, second, in_flight, "pending" if big_pending else "idle", trace])
	return ok and in_flight and edit_at >= 0 and big_at > edit_at


func _dig_cell(cell: Vector2i) -> bool:
	var p := _terrain.params
	return _terrain.edit((cell.x + 0.5) * p.dtheta(), -p.length / 2.0 + cell.y + 0.5, RADIUS, -STEP)


## Feeds a physical key through Input, as the player's own input code reads it.
func _press(key: Key, pressed: bool) -> void:
	var e := InputEventKey.new()
	e.keycode = key
	e.physical_keycode = key
	e.pressed = pressed
	Input.parse_input_event(e)


func _local(node: Node3D) -> Vector3:
	return _station.to_local(node.global_position)


## The station-space point h m over the hull at the centre of cell.
func _cell_point(cell: Vector2i, h: float) -> Vector3:
	var p := _terrain.params
	return Cyl.position((cell.x + 0.5) * p.dtheta(), -p.length / 2.0 + cell.y + 0.5, h, p.radius)


## Height of station-space point q over the collider under it, along the patch's up; negative when under it.
func _clearance(q: Vector3) -> float:
	var patch := _terrain.patch
	return (q - patch.surface_point(q, 0.0)).dot(patch.transform.basis.y)


## The lowest clearance among the box's eight corners.
func _corner_clearance() -> float:
	var low := INF
	for i in 8:
		var corner := Vector3(i & 1, (i >> 1) & 1, (i >> 2) & 1) - Vector3.ONE * 0.5
		low = minf(low, _clearance(_station.to_local(_box.global_transform * corner)))
	return low


## Whether the big patch has its hole under station-space point q, so that only the edit shape holds it there.
func _in_hole(q: Vector3) -> bool:
	var patch := _terrain.patch
	var l := patch.transform.affine_inverse() * q
	var big: HeightMapShape3D = (patch.get_node("CollisionShape3D") as CollisionShape3D).shape
	return is_nan(ColliderPatch._bilinear(big.map_data, ColliderPatch.SAMPLES, l.x + ColliderPatch._MID,
			l.z + ColliderPatch._MID))


## Whether station-space point q lies over the edit shape's extent.
func _in_edit_extent(q: Vector3) -> bool:
	var e := _terrain.patch.edit_frame.affine_inverse() * q
	return maxf(absf(e.x), absf(e.z)) <= ColliderPatch._EDIT_MID


func _report(what: String, ok: bool) -> void:
	print("%s: %s" % [what, "ok" if ok else "FAILED"])
	_ok = _ok and ok


func _expect(ok: bool, what: String) -> void:
	if not ok:
		print("%s: FAILED" % what)
		_ok = false


## The timing summary, reported against the budgets and never asserted.
func _summary() -> void:
	var vp := get_viewport()
	print("---- edit run ----")
	print("machine: %s, %s" % [OS.get_processor_name(), RenderingServer.get_video_adapter_name()])
	print("driver: %s, window %s, viewport %s, display %.0f Hz, vsync mode %d" % [
			RenderingServer.get_current_rendering_driver_name(), DisplayServer.window_get_size(),
			vp.get_visible_rect().size, DisplayServer.screen_get_refresh_rate(), DisplayServer.window_get_vsync_mode()])
	print("GPU passes in ms (Vulkan only; per list, apply and detail per tile; walking = the trench, standing = the rest):")
	for pass_name: String in BUDGET:
		var per_tile := pass_name in ["apply", "detail"]
		var counts: Array[int] = []
		if per_tile:
			counts = _applied if pass_name == "apply" else _tiles
		var lists := _timed.filter(func(t: Dictionary) -> bool: return t.name == pass_name).size()
		var label := pass_name + ("/tile" if per_tile else "")
		if per_tile and lists > 0 and lists != counts.size():
			print("  %-11s per tile n/a (%d lists timed, %d dispatches)" % [label, lists, counts.size()])
			continue
		for state: String in ["standing", "walking"]:
			print("  %-11s %-8s %s%s" % [label, state, Smoke._stat(_series(pass_name, state == "walking", counts), BUDGET[pass_name]),
					"" if state == "walking" or not EXPECTED.has(pass_name) else " (expected under %.1f)" % EXPECTED[pass_name]])
	print("bakes timed while walking can read higher on the GPU than standing ones (a clock or timestamp effect, also seen with the old shader); reported apart, not tuned")
	for kind: String in ["edit", "big"]:
		var ms: Array[float] = []
		for l in _landings:
			if l.kind == kind:
				ms.append(l.ms)
		print("baked %s CPU (map_data): %s (expected %s)" % [kind, Smoke._stat(ms, 4.0),
				"under 0.5 ms" if kind == "edit" else "about 2.8 ms"])
	print("frames per phase (CPU = frame interval; GPU = viewport render time, budget 6 ms):")
	for phase in ["dig", "raise", "trench"]:
		print("  %-7s %s" % [phase, Smoke._times(_frames[phase].cpu, _frames[phase].gpu)])
	var falls := 0
	for phase: String in _low:
		var l: Dictionary = _low[phase]
		falls += int(minf(minf(l.player, l.box), l.corner) < FELL)
	print("held %d times (by phase: %s), fell in %d phases (lowest clearance under %.0f m), survived the scroll: %s" % [
			_holds, _held_in, falls, FELL, _survived])


## The GPU times in ms of one pass, walking or standing, each divided by its tile count when it has them.
func _series(pass_name: String, walking: bool, counts: Array[int]) -> Array[float]:
	var out: Array[float] = []
	var i := 0
	for t in _timed:
		if t.name != pass_name:
			continue
		if t.walking == walking:
			out.append(t.ms / (counts[i] if not counts.is_empty() else 1))
		i += 1
	return out


## Waits until the live patch covers the player and no bake is in flight, then 1 s. False after quitting on
## a timeout.
func _settled() -> bool:
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


## The window's surface (m and its bits) and edit_mask (0..255) at each cell, read synchronously.
func _read(cells: Array[Vector2i]) -> Array[Dictionary]:
	var w := _terrain.window
	var bytes: Array[PackedByteArray] = []
	RenderingServer.call_on_render_thread(func() -> void:
		var rd := RenderingServer.get_rendering_device()
		bytes.append(rd.texture_get_data(w.texture_rid("surface"), 0))
		bytes.append(rd.texture_get_data(w.texture_rid("edit_mask"), 0)))
	var out: Array[Dictionary] = []
	for c in cells:
		# Tile t sits in slot t mod slots, so cell c is texel c mod size.
		var k := posmod(c.y, w.size) * w.size + posmod(c.x, w.size)
		out.append({"h": bytes[0].decode_float(4 * k), "bits": bytes[0].decode_u32(4 * k), "mask": bytes[1][k]})
	return out
