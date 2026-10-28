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
	patch.free(); box.free(); body.free(); terrain.free()
	if failed: quit(1)
	else: print("PASS"); quit(0)
