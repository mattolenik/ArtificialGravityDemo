extends SceneTree

var failed := false

func check(ok: bool, msg: String) -> void:
	if not ok:
		push_error(msg)
		failed = true

func _initialize() -> void:
	var t := Trail.new(); t.lifetime = 100.0
	t.add_point(Vector3.ZERO, 0.0)
	t.add_point(Vector3(0.1, 0, 0), 1.0)   # too close: skipped
	t.add_point(Vector3(5, 0, 0), 50.0)
	t.add_point(Vector3(10, 0, 0), 101.0)
	check(t.points.size() == 3, "min distance")
	t.prune(101.0)
	check(t.points.size() == 2 and t.points[0] == Vector3(5, 0, 0), "prune")
	t.free()
	if failed:
		quit(1)
	else:
		print("PASS")
		quit(0)
