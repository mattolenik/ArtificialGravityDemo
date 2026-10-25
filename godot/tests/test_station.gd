extends SceneTree

var failed := false

func check(ok: bool, msg: String) -> void:
	if not ok:
		push_error(msg)
		failed = true

func _initialize() -> void:
	var station: Station = load("res://station.tscn").instantiate()
	root.add_child(station)
	await physics_frame
	await physics_frame
	# Mesh imported the right way round
	check(absf(station.radius - 3200.0) < 1.0, "radius %f" % station.radius)
	# Review Focus 1: on the axis
	check(station.down_at(Vector3(0, 0, 5)) == Vector3.ZERO, "down on axis")
	check(station.acceleration_at(Vector3(0, 0, 5), Vector3.ZERO) == Vector3.ZERO, "accel on axis")
	check(station.down_at(Vector3(0, -100, 0)).is_equal_approx(Vector3(0, -1, 0)), "down at bottom")

	# The real drop: a Jolt body falls 10 m and lands antispinward of the point below it.
	# The floor is faceted, so the floor below the spawn point is a little inside radius.
	var hit := root.world_3d.direct_space_state.intersect_ray(
			PhysicsRayQueryParameters3D.create(Vector3(0, -3100, 0), Vector3(0, -3300, 0)))
	check(not hit.is_empty(), "no floor below spawn")
	if hit.is_empty():
		quit(1)
		return
	var floor_r: float = -hit.position.y
	var land_r := floor_r - 0.05
	var a := land_r - 10.0
	var dt := 1.0 / 60.0
	var w := station.omega().length()
	var chord := sqrt(land_r * land_r - a * a)
	var expected_time := chord / (w * a)
	var expected_lag := (w * expected_time - atan(chord / a)) * land_r

	var box: Box = load("res://box.tscn").instantiate()
	box.station = station
	box.setup(0.1, 8, 0)
	box.contact_monitor = true
	box.max_contacts_reported = 1
	box.position = Vector3(0, -a, 0)
	var landed := [false]
	box.body_entered.connect(func(_body: Node) -> void: landed[0] = true)
	root.add_child(box)
	var frames := 0
	while not landed[0] and frames < 3600:
		await physics_frame
		frames += 1
	var t := frames * dt
	var p := box.global_position
	var lag := -atan2(p.x, -p.y) * land_r
	print("Jolt fall %.3fs (exact %.3fs), lands %.3fm antispinward (exact %.3fm), floor_r %.3fm" % [t, expected_time, lag, expected_lag, floor_r])
	check(absf(t - expected_time) <= 2 * dt and absf(lag - expected_lag) <= 0.05 * expected_lag, "Jolt drop mismatch")

	for i in 300:
		await physics_frame
	print("sleeping after 5 s at rest: %s" % box.sleeping)
	if failed:
		quit(1)
	else:
		print("PASS")
		quit(0)
