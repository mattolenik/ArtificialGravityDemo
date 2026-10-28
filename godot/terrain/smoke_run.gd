## Windowed smoke run of the terrain slice (spec section 13). Instantiates main.tscn unchanged and, once the
## first collider patch is live, holds still 2 s, runs the player spinward and then axially for `leg` s each
## (W and D through Input, so the player's own movement code does it), then toggles the fly camera (F) and
## flies 5 km along the axis, and prints a summary and quits. Frame times come from the process delta,
## GPU times from the timing overlay's pairs and the viewport's measured render time (zero where the backend
## reports none, shown as n/a).
## Run: godot --path . res://terrain/smoke.tscn [-- --legs=10]. If the window stops being drawn the collider
## stops following, the player is held, and the summary shows held frames and shorter legs.
## With `-- --blackout` the legs are replaced by a check of that hold: after the 2 s hold the render loop is
## stopped and W held for BLACKOUT s (frames still run, no bake can land), so the player must be held when it
## leaves the patch, stay exactly where it was held, and be released soon after the loop resumes.
extends Node

const HOLD := 2.0
## Seconds of process time the render loop stays stopped in --blackout, and how long after it resumes the
## release may take, and how long the player then has to show it stands.
const BLACKOUT := 10.0
const RELEASE_WITHIN := 3.0
const SETTLE := 1.0
const FLIGHT := 5000.0
## Flight speed in m/s and height above the macro surface in m.
const FLIGHT_SPEED := 400.0
const FLIGHT_HEIGHT := 120.0
## Frame intervals over this many ms are listed in the summary.
const SLOW := 30.0
## A phase whose lowest height above the macro surface is under this many m is marked as fallen.
const FELL := -20.0

## Seconds per running leg.
var leg := 60.0

var _station: Station
var _terrain: Terrain
var _player: Player
var _fly: FlyCamera
## The phase being measured ("" before and after), the node whose travel it logs, and its numbers.
var _phase := ""
var _tracked: Node3D
var _stats := {}
## Main-window and far-window detail lists and bakes in ms, and the tiles per detail dispatch in order.
var _detail: Array[float] = []
var _bake: Array[float] = []
var _tiles: Array[int] = []
var _listening := false
var _shifts := 0
## How many times Terrain held the player, whether it is holding it now, and for how many measured frames.
var _holds := 0
var _holding := false
var _held_frames := 0
## Frames over SLOW ms, as "phase t=..s ..ms".
var _slow: Array[String] = []
## Application focus changes, as "out/in phase t=..s".
var _focus: Array[String] = []
## --blackout: the route is on, the phase time and global position of the player at the first hold and the
## time of the next release (-1 until they happen), and how far it moved from there while held.
var _blackout := false
var _held_t := -1.0
var _held_at := Vector3.ZERO
var _released_t := -1.0
var _drift := 0.0


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--legs="):
			leg = float(arg.trim_prefix("--legs="))
		_blackout = _blackout or arg == "--blackout"
	var main: Node = load("res://main.tscn").instantiate()
	_station = main.get_node("Station")
	_terrain = _station.get_node("Terrain")
	_terrain.persist_edits = false  # a driver never writes edits into the default world
	_player = _station.get_node("Player")
	_fly = _station.get_node("FlyCamera")
	main.get_node("Panel/Box/Timing").timed.connect(_on_timed)
	_terrain.origin_shifted.connect(func(_shift: float) -> void: _shifts += 1)
	_terrain.body_held.connect(_on_body_held)
	_terrain.collider_live.connect(_route, CONNECT_ONE_SHOT)
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	add_child(main)


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_APPLICATION_FOCUS_IN:
		_focus.append("%s %s t=%.1fs" % ["out" if what == NOTIFICATION_APPLICATION_FOCUS_OUT else "in", _phase,
				_stats[_phase].time if _stats.has(_phase) else 0.0])


## The route is scripted: a stray click must not capture the mouse, nor mouse movement turn the player.
func _input(event: InputEvent) -> void:
	if event is InputEventMouse:
		get_viewport().set_input_as_handled()


func _route() -> void:
	await _run("hold", HOLD, KEY_NONE)
	if _blackout:
		await _run_blackout()
		return
	# The hold let the startup dispatches finish; from here on the detail lists are the window's moves.
	_listening = true
	_terrain.window.tiles_generated.connect(_on_tiles)
	_terrain.far.window.tiles_generated.connect(_on_tiles)
	await _run("spinward", leg, KEY_W)
	await _run("axial", leg, KEY_D)
	await _fly_over()
	# Let the last timestamps arrive.
	for i in 6:
		await get_tree().process_frame
	_phase = ""
	_summary()
	get_tree().quit()


## Runs W with the render loop stopped for BLACKOUT s, then resumes it, and checks the player was held once it
## left the patch, did not move while held, was released within RELEASE_WITHIN s of the loop resuming and
## stands after SETTLE s more. Times are the phase's, from the start of W. Prints the verdict and quits.
func _run_blackout() -> void:
	var start := _player.global_position
	_begin("blackout", _player)
	_press(KEY_W, true)
	RenderingServer.render_loop_enabled = false
	while _stats.blackout.time < BLACKOUT:
		await get_tree().process_frame
	RenderingServer.render_loop_enabled = true
	_press(KEY_W, false)
	var resumed: float = _stats.blackout.time
	while _released_t < 0.0 and _stats.blackout.time < resumed + RELEASE_WITHIN:
		await get_tree().process_frame
	var settled: float = _stats.blackout.time + SETTLE
	while _stats.blackout.time < settled:
		await get_tree().process_frame
	var standing := _clearance(_player.position)
	_phase = ""
	_summary()
	var held := _held_t >= 0.0
	var frozen := held and _drift < 1e-3
	var released := _released_t >= 0.0 and _released_t - resumed <= RELEASE_WITHIN
	print("---- blackout ----")
	print("held at t=%.2f s after %.0f m (render loop off from t=0 to %.2f s)" % [_held_t, start.distance_to(_held_at), resumed]
			if held else "NOT held: body_held(true) never fired")
	print("frozen: %s (moved %.6f m while held)" % ["ok" if frozen else "FAIL", _drift])
	print("released at t=%.3f s (%.3f s after the loop resumed)" % [_released_t, _released_t - resumed]
			if released else "NOT released within %.0f s of the loop resuming" % RELEASE_WITHIN)
	print("standing: %.2f m above the macro surface %.0f s after" % [standing, SETTLE])
	var ok := held and frozen and released and standing > -2.0
	print("BLACKOUT PASS" if ok else "BLACKOUT FAIL")
	get_tree().quit(0 if ok else 1)


## Holds `key` (none for KEY_NONE) for `seconds` of frame time.
func _run(phase: String, seconds: float, key: Key) -> void:
	_begin(phase, _player)
	if key != KEY_NONE:
		_press(key, true)
	while _stats[phase].time < seconds:
		await get_tree().process_frame
	if key != KEY_NONE:
		_press(key, false)


## F, then W held with the camera kept FLIGHT_HEIGHT above the macro surface, looking along +z, until it has
## moved FLIGHT m axially.
func _fly_over() -> void:
	_press(KEY_F, true)
	_press(KEY_F, false)
	for i in 3:
		await get_tree().process_frame
	if not _fly.active:
		push_error("The fly camera did not take over.")
		return
	var speed := _fly.speed
	_fly.speed = FLIGHT_SPEED
	_hold_height()
	_begin("flight", _fly)
	var z0 := _fly.position.z
	_fly.global_basis = Basis.looking_at(_station.global_basis * Vector3.BACK, -_station.down_at(_fly.global_position))
	_press(KEY_W, true)
	while _fly.position.z - z0 < FLIGHT:
		await get_tree().process_frame
	_press(KEY_W, false)
	_fly.speed = speed


## Feeds a physical key through Input, as the player's and the camera's own input code reads it.
func _press(key: Key, pressed: bool) -> void:
	var e := InputEventKey.new()
	e.keycode = key
	e.physical_keycode = key
	e.pressed = pressed
	Input.parse_input_event(e)


func _begin(phase: String, tracked: Node3D) -> void:
	_tracked = tracked
	_stats[phase] = {"time": 0.0, "path": 0.0, "start": tracked.position, "last": tracked.position, "cpu": [], "gpu": [],
			"low": INF, "high": -INF}
	_phase = phase


func _process(delta: float) -> void:
	if _phase.is_empty():
		return
	if _phase == "flight":
		_hold_height()
	_held_frames += int(_holding)
	if _blackout and _holding and _held_t >= 0.0:
		_drift = maxf(_drift, _player.global_position.distance_to(_held_at))
	var s: Dictionary = _stats[_phase]
	s.time += delta
	s.cpu.append(delta * 1000.0)
	if delta * 1000.0 > SLOW:
		_slow.append("%s t=%.1fs %.0fms" % [_phase, s.time, delta * 1000.0])
	s.gpu.append(RenderingServer.viewport_get_measured_render_time_gpu(get_viewport().get_viewport_rid()))
	s.path += _tracked.position.distance_to(s.last)
	s.last = _tracked.position
	var clearance := _clearance(s.last)
	s.low = minf(s.low, clearance)
	s.high = maxf(s.high, clearance)


## Puts the fly camera FLIGHT_HEIGHT above the macro surface at its theta and z.
func _hold_height() -> void:
	var p := _fly.position
	var theta := Cyl.theta_of(p)
	_fly.position = Cyl.position(theta, p.z, _terrain.height_at(theta, p.z) + FLIGHT_HEIGHT, _terrain.params.radius)


## Height of a station-space point above the macro surface (approximate: no detail) under it, in m.
func _clearance(p: Vector3) -> float:
	var theta := Cyl.theta_of(p)
	return _terrain.params.radius - Vector2(p.x, p.y).length() - _terrain.height_at(theta, p.z)


func _on_timed(pass_name: String, ms: float) -> void:
	if _listening:
		(_detail if pass_name == "detail" else _bake).append(ms)


func _on_body_held(held: bool) -> void:
	_holding = held
	_holds += int(held)
	if _phase != "blackout":
		return
	var t: float = _stats.blackout.time
	if held and _held_t < 0.0:
		_held_t = t
		_held_at = _player.global_position
	elif not held and _held_t >= 0.0 and _released_t < 0.0:
		_released_t = t
		_drift = maxf(_drift, _player.global_position.distance_to(_held_at))


func _on_tiles(tiles: Array[Vector2i]) -> void:
	_tiles.append(tiles.size())


func _summary() -> void:
	var all_cpu: Array = []
	var all_gpu: Array = []
	var rows := ""
	for phase: String in _stats:
		var s: Dictionary = _stats[phase]
		all_cpu.append_array(s.cpu)
		all_gpu.append_array(s.gpu)
		var radius := (Vector2(s.start.x, s.start.y).length() + Vector2(s.last.x, s.last.y).length()) / 2.0
		var spin := wrapf(Cyl.theta_of(s.last) - Cyl.theta_of(s.start), -PI, PI) * radius
		var fell := "  <- FELL THROUGH" if s.low < FELL else ""
		rows += "  %-8s %5.1f s %7.1f m path %7.1f m axial %7.1f m spinward, %6.1f..%.1f m above ground, %d frames%s\n    %s\n" % [
				phase, s.time, s.path, s.last.z - s.start.z, spin, s.low, s.high, s.cpu.size(), fell, _times(s.cpu, s.gpu)]
	var vp := get_viewport()
	print("---- smoke run ----")
	print("machine: %s, %s" % [OS.get_processor_name(), RenderingServer.get_video_adapter_name()])
	print("driver: %s, window %s, viewport %s, display %.0f Hz, vsync mode %d, legs %.0f s" % [
			RenderingServer.get_current_rendering_driver_name(), DisplayServer.window_get_size(),
			vp.get_visible_rect().size, DisplayServer.screen_get_refresh_rate(),
			DisplayServer.window_get_vsync_mode(), leg])
	print("per phase (CPU = frame interval from the process delta; GPU = viewport render time):")
	print(rows.trim_suffix("\n"))
	print("all frames: %d, %s" % [all_cpu.size(), _times(all_cpu, all_gpu)])
	print("origin shifts: %d; held: %d times, %d frames; frames over %.0f ms: %s; focus changes: %s" % [_shifts, _holds,
			_held_frames, SLOW, _slow, _focus])
	print("detail lists: %s; tiles per dispatch %s..%s; %s" % [_stat(_detail, 2.0), _tiles.min() if _tiles else "-",
			_tiles.max() if _tiles else "-", _per_tile(_detail, _tiles)])
	print("bake: %s" % _stat(_bake, 1.0))


## "cpu mean .. p99 .. max .. gpu mean .. p99 .. max .. ms" for a set of frames.
static func _times(cpu: Array, gpu: Array) -> String:
	var s := "CPU mean %.2f p99 %.2f max %.2f (%d over 16)" % [_mean(cpu), _pct(cpu, 0.99), cpu.max(),
			cpu.filter(func(x: float) -> bool: return x > 16.0).size()]
	if gpu.max() <= 0.0:
		return s + "  GPU n/a"
	return s + "  GPU mean %.2f p99 %.2f max %.2f ms" % [_mean(gpu), _pct(gpu, 0.99), gpu.max()]


## Count, median, p90 and max of times in ms, and how many are over budget.
static func _stat(a: Array[float], budget: float) -> String:
	if a.is_empty():
		return "n/a"
	return "n %d, median %.3f, p90 %.3f, max %.3f ms, %d over %.1f ms" % [a.size(), _pct(a, 0.5), _pct(a, 0.9), a.max(),
			a.filter(func(x: float) -> bool: return x > budget).size(), budget]


## The worst list time per tile, if the lists and the dispatches pair up in order.
static func _per_tile(detail: Array[float], tiles: Array[int]) -> String:
	if detail.is_empty() or detail.size() != tiles.size():
		return "per tile n/a (%d lists timed, %d dispatches)" % [detail.size(), tiles.size()]
	var worst := 0.0
	for i in detail.size():
		worst = maxf(worst, detail[i] / tiles[i])
	return "per tile max %.3f ms" % worst


static func _mean(a: Array) -> float:
	return a.reduce(func(sum: float, x: float) -> float: return sum + x, 0.0) / a.size()


## The value that fraction q of the sorted samples lie below.
static func _pct(a: Array, q: float) -> float:
	var b := a.duplicate()
	b.sort()
	return b[mini(int(b.size() * q), b.size() - 1)]
