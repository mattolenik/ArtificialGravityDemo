extends SceneTree

var failed := false

func check(ok: bool, msg: String) -> void:
	if not ok:
		push_error(msg)
		failed = true

func _initialize() -> void:
	# The lit arc: 160 degrees wide, 2 degree dawn and dusk bands, centred on the bar's theta.
	check(absf(LightBar.day(0.0, 0.0, 160, 2) - 1.0) < 1e-6, "noon")
	check(absf(LightBar.day(deg_to_rad(75), 0.0, 160, 2) - 1.0) < 1e-6, "inside the arc")
	check(absf(LightBar.day(deg_to_rad(-75), 0.0, 160, 2) - 1.0) < 1e-6, "inside, the other way")
	check(LightBar.day(deg_to_rad(85), 0.0, 160, 2) == 0.0, "outside the arc")
	check(LightBar.day(PI, 0.0, 160, 2) == 0.0, "midnight")
	var dusk := LightBar.day(deg_to_rad(80), 0.0, 160, 2)
	check(dusk > 0.3 and dusk < 0.7, "dusk is half lit: %f" % dusk)
	check(absf(LightBar.day(TAU + 0.1, 0.1, 160, 2) - 1.0) < 1e-6, "wraps around")
	check(absf(LightBar.day(1.0, 1.0 + deg_to_rad(70), 160, 2) - 1.0) < 1e-6, "arc centred off zero")
	# The arc moves anti-spinward (theta falls) at the spin rate.
	var station: Station = load("res://station.tscn").instantiate()
	root.add_child(station)
	await physics_frame
	await physics_frame
	var bar := LightBar.new()
	bar.station = station
	station.add_child(bar)
	await physics_frame
	bar.theta = 0.0
	bar._process(2.0)
	var w := sqrt(station.acceleration / station.radius)
	check(absf(bar.theta - wrapf(-2.0 * w, 0.0, TAU)) < 1e-6, "theta after 2 s: %f, want %f" % [bar.theta, wrapf(-2.0 * w, 0.0, TAU)])
	check(bar.get_child_count() == 3, "bar mesh and two lights")
	if failed: quit(1)
	else: print("PASS"); quit(0)
