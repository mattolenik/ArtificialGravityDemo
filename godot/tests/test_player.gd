extends SceneTree

var failed := false

func check(ok: bool, msg: String) -> void:
	if not ok:
		push_error(msg)
		failed = true

func _initialize() -> void:
	for deg in [0, 90, 180]:
		var a := deg_to_rad(deg)
		var station: Station = load("res://station.tscn").instantiate()
		root.add_child(station)
		# The root only enters the tree after _initialize, and radius is set in _ready.
		await process_frame
		var player: Player = load("res://player.tscn").instantiate()
		player.station = station
		player.position = Vector3(sin(a), -cos(a), 0) * (station.radius - 2)
		station.add_child(player)
		var landings: Array[float] = []
		var steps: Array[Vector3] = []
		player.landed.connect(func(speed: float) -> void: landings.append(speed))
		player.stepped.connect(func(v: Vector3) -> void: steps.append(v))
		for i in 180:
			await physics_frame
		var down := station.down_at(player.global_position)
		print("%d°: on_floor %s, up·-down %.6f, drift %.4f m/s" % [deg, player.is_on_floor(),
				player.global_basis.y.dot(-down), player.velocity.slide(down).length()])
		check(player.is_on_floor(), "on floor at %d°" % deg)
		check(player.global_basis.y.dot(-down) > 0.999, "upright at %d°" % deg)
		check(player.velocity.slide(down).length() < 0.05, "no drift at %d°" % deg)
		# The drop (about 0.45 s airborne, longer than AIRBORNE_TICKS) lands exactly once at a few m/s; any
		# settling contact after it is too short to count. Standing still, every step reports no floor speed;
		# the landing tick's step still carries the drop's Coriolis drift (2ω · 1 m, about 0.11 m/s, under
		# push_min_speed), which the floor's grip takes the tick after.
		check(Player.AIRBORNE_TICKS == 9, "airborne ticks")
		check(landings.size() == 1 and landings[0] > 1.0 and landings[0] < 10.0, "landed once at %s" % [landings])
		check(steps.size() > 1 and steps[0].length() < 0.5 and steps.slice(1).all(func(v: Vector3) -> bool: return v.length() < 0.05),
				"steps while standing %d, the first %.4f m/s" % [steps.size(), steps[0].length() if steps else 0.0])
		# Mouse look turns about the player's own up, not world Y, and the tilt is clamped.
		var heading := -player.global_basis.z
		player.look(Vector2(100, -100000))
		check(absf(heading.angle_to(-player.global_basis.z) - 0.3) < 0.001, "yaw at %d°" % deg)
		check(player.global_basis.y.dot(-down) > 0.999, "upright after look at %d°" % deg)
		check(is_equal_approx(player.get_node("CameraPivot").rotation.x, 1.4), "pitch clamp at %d°" % deg)
		station.free()
	if failed:
		quit(1)
	else:
		print("PASS")
		quit(0)
