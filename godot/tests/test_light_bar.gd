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
	# The defaults: a 160 degree arc with 30 degree dawn and dusk bands, so full day within 50 degrees of
	# the bar, full night beyond 110, and half light at the arc's edge.
	var bar := LightBar.new()
	check(absf(LightBar.day(deg_to_rad(50), 0.0, bar.arc_deg, bar.soft_deg) - 1.0) < 1e-6, "default: full day at 50")
	check(LightBar.day(deg_to_rad(110), 0.0, bar.arc_deg, bar.soft_deg) == 0.0, "default: full night at 110")
	var edge := LightBar.day(deg_to_rad(80), 0.0, bar.arc_deg, bar.soft_deg)
	check(edge > 0.3 and edge < 0.7, "default: half light at the arc's edge: %f" % edge)
	var mid := LightBar.day(deg_to_rad(95), 0.0, bar.arc_deg, bar.soft_deg)
	check(mid > 0.0 and mid < edge, "default: dusk still fading at 95: %f" % mid)
	# The arc moves anti-spinward (theta falls) once per day_length, 10 minutes by default.
	var station: Station = load("res://station.tscn").instantiate()
	root.add_child(station)
	await physics_frame
	await physics_frame
	bar.station = station
	station.add_child(bar)
	await physics_frame
	check(bar.day_length == 600.0, "default day is 10 minutes: %f" % bar.day_length)
	bar.theta = 0.0
	bar._process(2.0)
	var want := wrapf(-2.0 * TAU / bar.day_length, 0.0, TAU)
	check(absf(bar.theta - want) < 1e-6, "theta after 2 s: %f, want %f" % [bar.theta, want])
	bar.theta = 0.0
	bar._process(bar.day_length / 4.0)
	check(absf(bar.theta - 0.75 * TAU) < 1e-6, "a quarter day turns the arc a quarter turn: %f" % bar.theta)
	check(bar.get_child_count() == 3, "bar mesh and two lights")
	if failed: quit(1)
	else: print("PASS"); quit(0)
