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
	# The shovel: a quarter cubic metre a scoop over the five-cell plus, within 3 m; its stamp passes the disc's
	# cell count as stamp_op does, so each cell takes its share.
	check(t.scoop_volume == 0.25 and t.scoop_radius == 1 and t.shovel_reach == 3.0, "shovel numbers")
	check(EditLayer.MODE_SCOOP == 8, "scoop mode")
	var op := EditLayer.Op.new()
	op.cell = Vector2i(7, 40); op.radius = t.scoop_radius; op.mode = EditLayer.MODE_SCOOP; op.amount = t.scoop_volume
	check(op.reach() == 1, "a scoop reaches its radius")
	var w := TerrainWindow.new()
	w.configure(WorldParams.new(), 512, 1.0)
	var pc := EditLayer.new()._params(w, op, Vector2i.ZERO, EditLayer.disc_cells(op.radius))
	check(pc.decode_s32(32) == 8 and pc.decode_s32(40) == 5 and pc.decode_float(64) == 0.25, "scoop push constants")
	# Holding T: the first scoop fires on the press when the shovel is empty; holding dirt, a press shorter than
	# scoop_hold_delay dumps and a longer one starts scooping; then one scoop every scoop_interval.
	check(t.scoop_hold_delay == 0.25 and t.scoop_interval == 0.25, "hold numbers")
	check(Tools.hold_scoops(0.0, 0.0, false, 0.0, t), "empty: a scoop on the press")
	check(not Tools.hold_scoops(0.5, 0.1, false, 0.0, t), "holding dirt: a short press is not a scoop")
	check(Tools.hold_scoops(0.5, 0.3, false, 0.0, t), "holding dirt: the hold delay starts scooping")
	check(not Tools.hold_scoops(0.5, 1.0, true, 0.1, t), "between scoops")
	check(Tools.hold_scoops(0.5, 1.0, true, 0.25, t), "the interval fires the next scoop")
	if failed: quit(1)
	else: print("PASS"); quit(0)
