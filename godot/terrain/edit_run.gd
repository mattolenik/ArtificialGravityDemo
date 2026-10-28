## Windowed check of the edit layer (the terrain edits plan, Task 5). Instantiates main.tscn and, once the
## first collider patch is live:
## 1. teleports to theta = 0 on the spawn's row, so a dig there straddles the seam (tiles 127 and 0);
## 2. digs: 30 stamps of -STEP, then raises: 20 of +STEP, RADIUS cells, 10 a second (net -2.5 m at the
##    centre), through Terrain.edit directly (DebugEdit aims where the camera looks; its keys are checked by
##    hand);
## 3. reads the window's surface and edit_mask at the centre cell and 3 cells west, across the seam;
## 4. teleports 600 m spinward: both tiles must leave the window;
## 5. teleports back: both cells must come back bitwise equal and masked (the apply pass, from the blobs);
## 6. saves user://debug/edit_pit.png and prints the edit (stamp plus pack) and apply GPU times (Vulkan only:
##    Metal reports zeros, shown as n/a), against the budget, not asserted.
## Prints PASS and exits 0 when every check holds, else FAIL and 1. The player floats over the pit: the
## collider follows edits from Task 7. Nothing is persisted yet, so the dig is gone on exit.
## After editing a .glsl run `godot --headless --path . --import` first (the suite does it).
## Run: godot --rendering-driver vulkan --path . res://terrain/edit_run.tscn
extends Node

const Smoke := preload("res://terrain/smoke_run.gd")
const RADIUS := 5.0
const STEP := 0.25
## GPU budget per edit and per applied tile, in ms.
const BUDGET := 0.3

var _station: Station
var _terrain: Terrain
var _player: Player
var _started := false
var _ok := true
## Edit and apply GPU times in ms, and how many tiles each apply list pair covered, in order.
var _edit: Array[float] = []
var _apply: Array[float] = []
var _applied: Array[int] = []


func _ready() -> void:
	var main: Node = load("res://main.tscn").instantiate()
	_station = main.get_node("Station")
	_terrain = _station.get_node("Terrain")
	_terrain.persist_edits = false
	_player = _station.get_node("Player")
	main.get_node("Panel/Box/Timing").timed.connect(func(pass_name: String, ms: float) -> void:
		if pass_name == "edit":
			_edit.append(ms)
		elif pass_name == "apply":
			_apply.append(ms))
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
	var p := _terrain.params
	var z := _terrain.maps.spawn.y
	var window := _terrain.window
	window.tiles_generated.connect(func(tiles: Array[Vector2i]) -> void:
		var n := tiles.filter(func(t: Vector2i) -> bool: return window.edits.blobs.has(t)).size()
		if n > 0:
			_applied.append(n))
	_terrain.teleport(0.0, z)
	if not await _settled():
		return

	var c := p.cell_of(0.0, z)
	var cells: Array[Vector2i] = [c, Vector2i(posmod(c.x - 3, p.n_theta()), c.y)]
	var before := _read(cells)
	for i in 50:
		if not _terrain.edit(0.0, z, RADIUS, -STEP if i < 30 else STEP):
			print("edit %d refused" % i)
			_ok = false
			break
		await get_tree().create_timer(0.1).timeout
	for i in 3:
		await get_tree().process_frame
	var dug := _read(cells)
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
	if same:
		print("survived the scroll: ok")
	else:
		print("survived the scroll: FAILED, %s then %s" % [dug, back])
		_ok = false

	_player.look(Vector2(0.0, 300.0))  # tilt the camera down onto the pit
	for i in 6:
		await get_tree().process_frame
	DirAccess.make_dir_recursive_absolute("user://debug")
	get_viewport().get_texture().get_image().save_png("user://debug/edit_pit.png")
	print("edit GPU (stamp plus pack): %s" % _times(_edit))
	var per_tile: Array[float] = []
	if _apply.size() == _applied.size():
		for i in _apply.size():
			per_tile.append(_apply[i] / _applied[i])
	print("apply GPU per tile: %s (%d lists timed, tiles per list %s)" % [_times(per_tile), _apply.size(), _applied])
	print("PASS" if _ok else "FAIL")
	get_tree().quit(0 if _ok else 1)


func _expect(ok: bool, what: String) -> void:
	if not ok:
		print("%s: FAILED" % what)
		_ok = false


## Median, p90 and max of times in ms against BUDGET.
func _times(a: Array[float]) -> String:
	if a.is_empty():
		return "n/a"
	return "n %d, median %.3f, p90 %.3f, max %.3f ms (budget %.1f ms)" % [a.size(), Smoke._pct(a, 0.5), Smoke._pct(a, 0.9),
			a.max(), BUDGET]


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
