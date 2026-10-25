extends SceneTree

var failed := false

func check(ok: bool, msg: String) -> void:
	if not ok:
		push_error(msg)
		failed = true

func _initialize() -> void:
	var station: Station = load("res://station.tscn").instantiate()
	root.add_child(station)
	var emitter := Emitter.new()
	emitter.station = station
	emitter.spawn_camera = Camera3D.new()
	emitter.add_child(emitter.spawn_camera)
	station.add_child(emitter)
	await physics_frame
	emitter.box_scene = load("res://box.tscn")
	emitter.distance_from_axis = 100
	emitter.count = 3
	emitter.box_size = 2
	emitter.direction = Emitter.LaunchDirection.SPINWARD
	emitter.min_speed = 0.5
	emitter.max_speed = 0.5
	emitter.spawn()
	var boxes := station.get_children().filter(func(n): return n is Box)
	check(emitter.spawned_count() == 3, "count")
	for b in boxes:
		check(is_equal_approx(b.mass, 8.0 * 8.0), "mass")
		check(is_equal_approx(b.drag_area, 1.05 * 4.0), "drag area")
		check(b.linear_velocity.is_equal_approx(Vector3(0.5, 0, 0)), "spinward is +X at the bottom")
		check(b.global_position.distance_to(emitter.spawn_point()) <= 10.0, "spread")
	# Review Focus 2: shapes aren't shared
	emitter.count = 1; emitter.box_size = 4; emitter.spawn()
	check(boxes[0].get_node("CollisionShape3D").shape.size == Vector3.ONE * 2, "first box kept its size")
	# Review Focus 3: freed elsewhere
	boxes[1].queue_free(); await process_frame
	check(emitter.spawned_count() == 3, "freed box not counted")
	emitter.clear_spawned(); await process_frame
	check(emitter.spawned_count() == 0, "cleared")
	# Readout, and Review Focus 5
	check(emitter.info_text().contains("%.2f m/s²" % (9.8 * 100 / station.radius)), "gravity readout")
	emitter.distance_from_axis = 3199
	check(emitter.info_text().contains("outside the floor"), "outside warning")
	# Handedness: spinward shows on the right of the spawn view, as in Unity
	emitter.toggle_spawn_view()
	check(emitter.spawn_camera.global_basis.x.dot(emitter.spinward()) > 0.99, "spinward on the right")
	# Trail vertices are global, so the ribbon must not inherit the station's offset
	station.position.x = 1000
	emitter.count = 1; emitter.spawn()
	await process_frame
	var trail: Trail = station.get_children().filter(func(n): return n is Box)[0].find_children("*", "Trail")[0]
	check(trail.global_transform == Transform3D.IDENTITY, "trail not at origin: %s" % trail.global_transform)
	if failed:
		quit(1)
	else:
		print("PASS")
		quit(0)
