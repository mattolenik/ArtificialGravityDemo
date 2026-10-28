## Windowed check of collider_bake.glsl (the terrain edits plan, Task 4). Instantiates main.tscn unchanged and,
## once the first collider patch is live at the spawn:
## 1. compares patch rows 128 and 8 from the GPU with Cyl.bake_row on the same surface heights (the window
##    texels, the bilinear macro surface outside the window, as the shader reads them);
## 2. bakes a hole 60 cells spinward of the centre and counts its NaN samples against 45 x 45 cells' width;
## 3. drops a 1 m box into the hole: Jolt must read NaN as no ground (decision 9);
## 4. teleports to the first cliff rim with a drop (debug_window.gd --cliff's rule) and compares row 128
##    there, which crosses the face;
## 5. prints the bake's GPU time (Vulkan only: Metal reports zeros, shown as n/a); timings are printed
##    against the budget, not asserted.
## Prints PASS and exits 0 when every check holds, else FAIL and 1. One-shot GDScript loops: debug only.
## After editing collider_bake.glsl run `godot --headless --path . --import` first (the suite does it).
## Run: godot --rendering-driver vulkan --path . res://terrain/bake_check.tscn
extends Node

const Smoke := preload("res://terrain/smoke_run.gd")
const DebugWindow := preload("res://terrain/debug_window.gd")
## GPU row against Cyl.bake_row, in m.
const ROW_TOLERANCE := 2e-3

var _station: Station
var _terrain: Terrain
var _player: Node3D
var _started := false
var _ok := true
## Bake GPU times in ms.
var _bake: Array[float] = []


func _ready() -> void:
	var main: Node = load("res://main.tscn").instantiate()
	_station = main.get_node("Station")
	_terrain = _station.get_node("Terrain")
	_terrain.persist_edits = false
	_player = _station.get_node("Player")
	main.get_node("Panel/Box/Timing").timed.connect(func(pass_name: String, ms: float) -> void:
		if pass_name == "bake":
			_bake.append(ms))
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


func _route() -> void:
	_started = true
	# collider_live fires inside the patch's readback landing, where no GPU work may be issued.
	await get_tree().process_frame
	var patch := _terrain.patch
	var p := _terrain.params
	var e128 := _row_error(128)
	var e8 := _row_error(8)
	print("bake vs reference: row 128 max err %.6f m, row 8 max err %.6f m (%d and %d of %d heights from the macro surface)" % [
			e128.err, e8.err, e128.macro, e8.macro, 2 * ColliderPatch.half_n(128, p) + 1])
	_expect(e128.err < ROW_TOLERANCE and e8.err < ROW_TOLERANCE, "rows")

	var c := p.cell_of(patch.center.x, patch.center.y)
	patch.zone = Vector2i(posmod(c.x + 60, p.n_theta()), c.y)
	patch.has_zone = true
	patch.rebuild(_terrain.window, patch.center.x, patch.center.y)
	if not await _landed():
		return
	var n := 0
	for v in (patch.get_node("CollisionShape3D").shape as HeightMapShape3D).map_data:
		n += int(is_nan(v))
	var zone := Vector2((patch.zone.x + 0.5) * p.dtheta(), -p.length / 2.0 + patch.zone.y + 0.5)
	var h_zone := _terrain.height_at(zone.x, zone.y)
	var expected := 45.0 * 45.0 * (p.radius - h_zone) * p.dtheta()
	print("hole samples %d, expected %.0f" % [n, expected])
	_expect(absf(n - expected) <= 0.1 * expected, "hole size")

	var box: Box = load("res://box.tscn").instantiate()
	box.station = _station
	box.setup(1.0, 8.0, 0.0)
	_station.add_child(box)
	box.global_position = _station.to_global(Cyl.position(zone.x, zone.y, h_zone + 5.0, p.radius))
	box.global_rotation = _station.global_rotation
	await get_tree().create_timer(4.0).timeout
	var b := _station.to_local(box.global_position)
	var above := p.radius - Vector2(b.x, b.y).length() - _terrain.height_at(Cyl.theta_of(b), b.z)
	if above < -20.0:
		print("box %.1f m above the macro surface: NaN is a hole: ok" % above)
	else:
		print("box %.1f m above the macro surface: NaN is NOT a hole" % above)
		_ok = false
	box.queue_free()
	patch.has_zone = false

	var rim := DebugWindow._first_cliff(p, _terrain.maps)
	if rim.x < 0:
		print("no cliff with a drop in the world: cliff row not checked")
		_ok = false
	else:
		_terrain.teleport((rim.x + 0.5) * 32.0 * p.dtheta(), -p.length / 2.0 + (rim.y + 0.5) * p.macro_cell)
		if not await _covered():
			return
		var e := _row_error(128)
		print("cliff row 128 max err %.6f m (macro cell %s; largest step along the row %.1f m, %d fold-backs, %d heights from the macro surface)" % [
				e.err, rim, e.step, e.folds, e.macro])
		_expect(e.err < ROW_TOLERANCE, "cliff row")

	# Let the last timestamps arrive.
	for i in 6:
		await get_tree().process_frame
	print("bake GPU: %s (expected under 0.2 ms, budget 1 ms)" % Smoke._stat(_bake, 1.0))
	print("PASS" if _ok else "FAIL")
	get_tree().quit(0 if _ok else 1)


func _expect(ok: bool, what: String) -> void:
	if not ok:
		print("%s: FAILED" % what)
		_ok = false


## Waits for the bake in flight to land, then a frame (the landing runs inside the readback flush). False
## after quitting on a timeout.
func _landed() -> bool:
	var frames := 0
	while _terrain.patch._pending:
		await get_tree().process_frame
		frames += 1
		if frames > 600:
			push_error("No bake landed in 600 frames.")
			get_tree().quit(1)
			return false
	await get_tree().process_frame
	return true


## Waits until the live patch covers the player, then a frame. False after quitting on a timeout.
func _covered() -> bool:
	var frames := 0
	while not _terrain.patch.covers(_station.to_local(_player.global_position)) or _terrain.patch._pending:
		await get_tree().process_frame
		frames += 1
		if frames > 600:
			push_error("No collider patch under the player after 600 frames.")
			get_tree().quit(1)
			return false
	await get_tree().process_frame
	return true


## Row j of the live patch from the GPU (the big staging texture) against Cyl.bake_row on the heights the
## shader reads: {err: max |difference| in m, step: the largest height step between neighbouring samples
## in m, folds: how many segments run backwards in x, macro: how many heights came from the macro surface}.
func _row_error(j: int) -> Dictionary:
	var patch := _terrain.patch
	var w := _terrain.window
	var p := w.params
	var bytes: Array[PackedByteArray] = []
	RenderingServer.call_on_render_thread(func() -> void:
		var rd := RenderingServer.get_rendering_device()
		bytes.append(rd.texture_get_data(patch._staging, 0))
		bytes.append(rd.texture_get_data(w.texture_rid("surface"), 0)))
	var gpu := bytes[0].to_float32_array()
	var surface := bytes[1].to_float32_array()
	var c := p.cell_of(patch.center.x, patch.center.y)
	var row := c.y + j - 128
	var wanted := {}
	for t in w.wanted_tiles(w.center_tile):
		wanted[t] = true
	var half := ColliderPatch.half_n(128, p)
	var h := PackedFloat32Array()
	h.resize(2 * half + 1)
	var step := 0.0
	var folds := 0
	var macro := 0
	var x_prev := -INF
	for k in h.size():
		var i := posmod(c.x + k - half, p.n_theta())
		if row >= 0 and wanted.has(w.tile_of_cell(i, row)):
			# Tile t sits in slot t mod slots, so cell (i, row) is texel (i, row) mod size.
			h[k] = surface[posmod(row, w.size) * w.size + posmod(i, w.size)]
		else:
			h[k] = _terrain.height_at((i + 0.5) * p.dtheta(), -p.length / 2.0 + row + 0.5)
			macro += 1
		var x := (p.radius - h[k]) * sin((k - half) * p.dtheta())
		folds += int(x < x_prev)
		x_prev = x
		if k > 0:
			step = maxf(step, absf(h[k] - h[k - 1]))
	var ref := Cyl.bake_row(h, p.dtheta(), p.radius, 1.0, ColliderPatch.SAMPLES)
	var err := 0.0
	for i in ColliderPatch.SAMPLES:
		err = maxf(err, absf(gpu[j * ColliderPatch.SAMPLES + i] - ref[i]))
	return {"err": err, "step": step, "folds": folds, "macro": macro}
