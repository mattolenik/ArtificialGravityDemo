extends SceneTree

var failed := false

func check(ok: bool, msg: String) -> void:
	if not ok:
		push_error(msg)
		failed = true

func _initialize() -> void:
	# The tunables carry the spec's numbers: 10 m in 30 s at 10 ticks a second, four landings tamp a patch, a
	# cubic metre a second of pumped water, relaxation at an eighth per step.
	var t := ToolParams.new()
	check(is_equal_approx(t.bore_step * t.bore_rate * 30.0, 10.0) and t.bore_depth == 10.0 and t.bore_radius == 1, "bore numbers")
	check(t.spoil_radius == 2 and t.spoil_offset == 7 and t.pump_rate == 1.0, "spoil and pump")
	check(t.tamp_step == 0.25 and t.tamp_land_speed == 2.0 and t.push_share == 0.05 and t.push_max == 0.03 and t.foot_radius == 1, "feet")
	check(t.slump_rate == 0.125 and t.flow_rate == 0.125 and t.soak_every == 6 and t.settle_time == 1.0 and t.move_eps == 1e-4, "simulation")
	check(t.collider_edit_interval == 0.2 and t.collider_zone_interval == 1.0, "collider throttle")
	# 0.4 is not a float32 (the arrays are PackedFloat32Array): it reads back as the nearest one, so approx.
	var m: MaterialSet = load("res://terrain/materials.tres")
	check(m.swell_factor[0] == 1.25 and m.repose_dry[0] == 35.0 and m.repose_damp[0] == 40.0 and m.repose_saturated[0] == 20.0 \
			and is_equal_approx(m.porosity[0], 0.4) and m.wetting_distance[0] == 3.0 and m.wetting_distance[2] == 0.0, "dirt and rock from materials.tres")
	# push_dir: the axis-quantised (theta, z) direction of a station-space velocity at angle theta.
	check(Tools.push_dir(Vector3(1, 0, 0), 0.0) == Vector2i(1, 0), "spinward at theta 0 is +x")
	check(Tools.push_dir(Vector3(0, 1, 0), 0.5 * PI) == Vector2i(1, 0), "spinward at theta pi/2 is +y")
	check(Tools.push_dir(Vector3(-1, 0, 0.5), 0.0) == Vector2i(-1, 0), "the larger component wins")
	check(Tools.push_dir(Vector3(0.2, 0, -1), 0.0) == Vector2i(0, -1), "axial")
	check(Tools.push_dir(Vector3.ZERO, 0.0) == Vector2i.ZERO, "no motion, no direction")
	# The auger's stop rule and its spoil cell across the seam.
	check(Auger.stop_reason_for(0.5, 10.0, 0.02, false) == "" and Auger.stop_reason_for(10.0, 10.0, 0.02, false) == "depth", "boring on, then at depth")
	check(Auger.stop_reason_for(0.5, 10.0, 0.0, false) == "rock", "a dry tick that cut nothing is rock everywhere")
	check(Auger.stop_reason_for(20.0, 10.0, 0.0, true) == "", "a pump never stops")
	check(Auger.spoil_cell_of(Vector2i(16382, 7), Vector2i(1, 0), 7, 16384) == Vector2i(5, 7), "spoil cell wraps")
	check(Auger.spoil_cell_of(Vector2i(10, 9), Vector2i(0, -1), 7, 16384) == Vector2i(10, 2), "spoil cell along the axis")
	# The shovel: two and a half cubic metres a scoop over the five-cell plus, within 3 m; its stamp passes the
	# disc's cell count as stamp_op does, so each cell takes its share.
	check(t.scoop_volume == 2.5 and t.scoop_radius == 1, "shovel numbers")
	# Tunnels: the shovel reaches 4 m (a roof overhead) and scoops a ball of radius 1 m in the box; the ball's
	# volume by the annuli of its voxels at the shader's sub-sampling is within 1 % of 4/3 pi wherever its
	# centre lies in a voxel.
	check(t.shovel_reach == 4.0 and t.scoop_ball == 1.5, "reach and ball")
	var R := 3200.0
	var dtheta := TAU / 16384
	for centre: Vector3 in [Vector3(0.5, 0.5, 410.37), Vector3(0.0, 0.0, 410.5), Vector3(0.7, 0.2, 410.9)]:
		var v := Tools.ball_volume(1.0, centre, R, dtheta)
		check(absf(v - 4.0 / 3.0 * PI) <= 0.01 * 4.0 / 3.0 * PI, "ball volume at %s: %.4f" % [centre, v])
	check(EditLayer.MODE_SCOOP == 8, "scoop mode")
	var op := EditLayer.Op.new()
	op.cell = Vector2i(7, 40); op.radius = t.scoop_radius; op.mode = EditLayer.MODE_SCOOP; op.amount = t.scoop_volume
	check(op.reach() == 1, "a scoop reaches its radius")
	var w := TerrainWindow.new()
	w.configure(WorldParams.new(), 512, 1.0)
	var pc := EditLayer.new()._params(w, op, Vector2i.ZERO, EditLayer.disc_cells(op.radius))
	check(pc.decode_s32(32) == 8 and pc.decode_s32(40) == 5 and pc.decode_float(64) == 2.5, "scoop push constants")
	# T held scoops every scoop_interval. A dump keeps the player out of the pile's repose cone: 2.5 m³ of dry
	# dirt (repose 35°) settles into a cone 1.505 m in radius, 25 m³ into one of 3.243 m.
	check(t.scoop_interval == 0.25, "hold interval")
	check(absf(Tools.pile_radius(2.5, 35.0) - 1.5051) < 1e-3 and absf(Tools.pile_radius(25.0, 35.0) - 3.2426) < 1e-3, "pile radius")
	check(Tools.PILE_MARGIN == 0.5 and Tools.BURIED == 0.1 and Tools.STAND == 0.05, "clearance numbers")
	# The feet: 1 m under the player's origin along its up, station-local; the push direction as before.
	check(Tools.foot_point(Vector3(0, -2790, 5), Vector3(0, 1, 0)) == Vector3(0, -2791, 5) and Tools.foot_point(Vector3(10, 0, 0), Vector3(-2, 0, 0)) == Vector3(11, 0, 0), "foot point")
	# The shovel at a wall cuts level: the ball's floor is the last wall scoop's while the feet are within half a
	# metre under it or a metre over it (the tunnel's own floor), else half a metre under the feet (a new tunnel
	# from a pit: the first bite steps down half a metre, its roof 2.5 m over the pit's floor).
	check(is_equal_approx(Tools.level_floor(INF, 410.3), 409.8), "a first wall scoop: half a metre under the feet")
	check(Tools.level_floor(409.8, 409.85) == 409.8 and Tools.level_floor(409.8, 409.35) == 409.8 and Tools.level_floor(409.8, 410.75) == 409.8, "on the tunnel's floor, or near it: the same floor")
	check(is_equal_approx(Tools.level_floor(409.8, 409.2), 408.7) and is_equal_approx(Tools.level_floor(409.8, 410.8), 410.3), "off it: anchored anew")
	if failed: quit(1)
	else: print("PASS"); quit(0)
