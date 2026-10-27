extends SceneTree

var failed := false

func check(ok: bool, msg: String) -> void:
	if not ok:
		push_error(msg)
		failed = true

func _initialize() -> void:
	check(Terrain.origin_shift_for(0.0) == 0.0, "no shift at origin")
	check(Terrain.origin_shift_for(1000.0) == 0.0, "no shift under a step")
	check(Terrain.origin_shift_for(2500.0) == -2048.0, "shift down")
	check(Terrain.origin_shift_for(-1600.0) == 2048.0, "shift up")
	# Shifting the station keeps every child's station-local position and moves global positions together.
	var station: Station = load("res://station.tscn").instantiate()
	root.add_child(station)
	await process_frame
	var viewer := Node3D.new(); station.add_child(viewer); viewer.position = Vector3(0, -3195, 2500)
	var patch := Node3D.new(); station.add_child(patch); patch.position = Vector3(0, -3200, 2400)
	station.position.z += Terrain.origin_shift_for(viewer.global_position.z)
	check(absf(viewer.global_position.z - 452.0) < 1e-3, "viewer near the origin %f" % viewer.global_position.z)
	check(viewer.position.z == 2500.0 and patch.position.z == 2400.0, "local positions unchanged")
	check(absf(patch.global_position.z - viewer.global_position.z + 100.0) < 1e-3, "patch moved with the viewer")
	if failed: quit(1)
	else: print("PASS"); quit(0)
