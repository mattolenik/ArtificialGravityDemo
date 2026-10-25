extends SceneTree

var failed := false

func check(ok: bool, msg: String) -> void:
	if not ok:
		push_error(msg)
		failed = true

func _initialize() -> void:
	var R := 500.0; var h := 10.0; var g := 9.8; var dt := 1.0 / 60.0
	var w := sqrt(g / R)
	var a := R - h
	var chord := sqrt(R * R - a * a)
	var expected_time := chord / (w * a)
	var expected_lag := (w * expected_time - atan(chord / a)) * R
	# Spin is about +Z, so spinward at the bottom of the cylinder is +X.
	var omega := Vector3(0, 0, w)
	var p := Vector3(0, -a, 0); var v := Vector3.ZERO; var t := 0.0
	while p.length() < R:
		v += Station.fictitious_acceleration(p, v, omega) * dt
		p += v * dt
		t += dt
	var lag := -atan2(p.x, -p.y) * R
	print("fall %.3fs (exact %.3fs), lands %.3fm antispinward (exact %.3fm)" % [t, expected_time, lag, expected_lag])
	check(absf(t - expected_time) <= 2 * dt and absf(lag - expected_lag) <= 0.05 * expected_lag, "drop mismatch")
	# About 3% thinner at the axis of a 500 m, 1 g station.
	var ratio := Station.air_density_at(0.0, R, w, 1.225, 101325.0) / 1.225
	check(ratio > 0.96 and ratio < 0.98, "air density ratio %f" % ratio)
	if failed:
		quit(1)
	else:
		print("PASS")
		quit(0)
