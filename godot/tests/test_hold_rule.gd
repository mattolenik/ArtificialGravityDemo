extends SceneTree

var failed := false
var held_log: Array[bool] = []

func check(ok: bool, msg: String) -> void:
	if not ok:
		push_error(msg)
		failed = true

func _initialize() -> void:
	# A Terrain outside the tree: _ready never runs, so no world, window or RenderingDevice is needed.
	var terrain := Terrain.new()
	var body := Node3D.new()
	terrain._body = body
	terrain.body_held.connect(func(h: bool) -> void: held_log.append(h))
	terrain._hold_body(true)
	check(body.process_mode == Node.PROCESS_MODE_DISABLED and held_log == [true], "held once")
	terrain._hold_body(true)
	check(held_log == [true], "holding again is silent")
	terrain._hold_body(false)
	check(body.process_mode == Node.PROCESS_MODE_INHERIT and held_log == [true, false], "released")
	# A body something else disabled (the fly camera's freeze) is neither taken nor released by Terrain.
	body.process_mode = Node.PROCESS_MODE_DISABLED
	terrain._hold_body(true)
	terrain._hold_body(false)
	check(body.process_mode == Node.PROCESS_MODE_DISABLED and held_log == [true, false], "another holder's hold is respected")
	# Any body: the same rule, state kept on the body.
	var box := RigidBody3D.new()
	check(terrain._hold(box, true) and box.process_mode == Node.PROCESS_MODE_DISABLED and box.get_meta("terrain_held"), "box held")
	check(not terrain._hold(box, true), "box held once")
	check(terrain._hold(box, false) and box.process_mode == Node.PROCESS_MODE_INHERIT, "box released")
	# covers() is a pure function of the frame: a pending bake changes nothing until it lands.
	var patch := ColliderPatch.new()
	patch.set_frame(1.0, 0.0, 3200.0)
	patch._pending = true
	check(patch.covers(patch.transform * Vector3(100, 0, 100)) and not patch.covers(patch.transform * Vector3(130, 0, 0)), "covers ignores a pending bake")
	# A failed edit-bake readback is retried from the next issue_again, not left pending (its error is expected).
	patch._pending_edit = true
	Engine.print_error_messages = false
	patch._landed_edit(PackedByteArray(), 1.0, 0.0, 3200.0)
	Engine.print_error_messages = true
	check(not patch._pending_edit and patch._again_edit, "a failed edit readback retries")
	# The collider throttle: the first touch goes at once; in-zone touches bake at most every edit interval; a
	# touch that would move the zone waits for the zone interval.
	terrain.params = WorldParams.new()
	terrain.tool_params = ToolParams.new()
	terrain.patch = patch
	patch._n_theta = terrain.params.n_theta()
	patch._pending = false
	terrain._collider_touch(Vector2i(100, 100), 2)
	terrain._flush_collider(10.0)
	check(patch.has_zone and patch.zone == Vector2i(100, 100) and patch._again_edit and patch._again_big, "first touch sets the zone at once")
	patch._again_edit = false; patch._again_big = false
	terrain._collider_touch(Vector2i(102, 100), 2)
	terrain._flush_collider(10.1)
	check(not patch._again_edit, "an in-zone touch waits for the edit interval")
	terrain._flush_collider(10.21)
	check(patch._again_edit and not patch._again_big and patch.zone == Vector2i(100, 100), "then the edit shape bakes, zone kept")
	patch._again_edit = false
	terrain._collider_touch(Vector2i(140, 100), 2)
	terrain._flush_collider(10.5)
	check(not patch._again_big and patch.zone == Vector2i(100, 100), "a zone move waits for the zone interval")
	terrain._flush_collider(11.01)
	check(patch._again_big and patch._again_edit and patch.zone == Vector2i(140, 100), "the zone moves after a second")
	# The re-touch follows the last tool stamp only while its own tile is active: none before the tile shows
	# active, forgotten when it never does within RETOUCH_FRAMES frames of the stamp (it changed nothing) or
	# once it has left the active set (the pile settled).
	terrain._touch_radius = -1
	terrain._last_tool = Vector2i(200, 100); terrain._last_reach = 2; terrain._last_frame = 50; terrain._last_active = false
	terrain._retouch(false, 50 + Terrain.RETOUCH_FRAMES)
	check(terrain._last_reach == 2 and terrain._touch_radius == -1, "no re-touch while the readback may still be on its way")
	terrain._retouch(false, 51 + Terrain.RETOUCH_FRAMES)
	check(terrain._last_reach == -1, "a stamp whose tile never became active is forgotten")
	terrain._retouch(true, 60)
	check(terrain._touch_radius == -1, "nothing to re-touch once forgotten")
	terrain._last_reach = 2; terrain._last_frame = 70; terrain._last_active = false
	terrain._retouch(true, 72)
	check(terrain._touch_cell == Vector2i(200, 100) and terrain._touch_radius == 2, "re-touched while its tile is active")
	terrain._touch_radius = -1
	terrain._retouch(false, 73)
	check(terrain._last_reach == -1 and terrain._touch_radius == -1, "forgotten once its tile settles")
	patch.free(); box.free(); body.free(); terrain.free()
	if failed: quit(1)
	else: print("PASS"); quit(0)
