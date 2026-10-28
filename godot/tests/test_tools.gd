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
	if failed: quit(1)
	else: print("PASS"); quit(0)
