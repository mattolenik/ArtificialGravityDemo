extends SceneTree

var failed := false

func check(ok: bool, msg: String) -> void:
	if not ok:
		push_error(msg)
		failed = true

func _initialize() -> void:
	var R := 3200.0
	# Round trip at the bottom, spinward of it, and up a mountain.
	for t in [0.0, 1.0, 4.5, TAU - 0.01]:
		for h in [0.0, 400.0, 1543.0]:
			var p := Cyl.position(t, -123.0, h, R)
			check(absf(fposmod(Cyl.theta_of(p) - t + PI, TAU) - PI) < 1e-6, "theta %f %f" % [t, h])
			check(absf(Cyl.height_of(p, R) - h) < 1e-3, "height %f %f" % [t, h])
			check(is_equal_approx(p.z, -123.0), "z")
	check(Cyl.position(0.0, 0.0, 0.0, R).is_equal_approx(Vector3(0, -R, 0)), "theta 0 is local -Y")
	check(Cyl.position(0.5 * PI, 0.0, 0.0, R).is_equal_approx(Vector3(R, 0, 0)), "spinward is +X at the bottom")
	# Span volume against a numeric integral of (R - h) over the span.
	var dtheta := TAU / 16384; var dz := 1.0
	var v := Cyl.span_volume(100.0, 350.0, R, dtheta, dz)
	var num := 0.0
	for i in 1000:
		num += (R - (100.0 + 250.0 * (i + 0.5) / 1000.0)) * dtheta * dz * 0.25
	check(absf(v - num) / num < 1e-6, "span volume %f vs %f" % [v, num])
	# Bake: a 45° slope in height, 257 samples at 1 m, must match the analytic curved surface within 1 mm.
	var n := 257; var h := PackedFloat32Array(); h.resize(n)
	for k in n: h[k] = 300.0 + (k - 128) * 1.0
	var y := Cyl.bake_row(h, 1.0 / (R - 300.0), R, 1.0, n)
	var worst := 0.0
	for i in range(8, n - 8):
		var x := (i - 128) * 1.0
		# Invert numerically: find phi with (R - h(phi)) sin phi = x, h linear in phi.
		var phi := x / (R - 300.0)
		for _it in 20:
			var hh := 300.0 + phi * (R - 300.0)
			phi -= ((R - hh) * sin(phi) - x) / ((R - hh) * cos(phi) - (R - 300.0) * sin(phi))
		var exact := R - (R - (300.0 + phi * (R - 300.0))) * cos(phi)
		worst = maxf(worst, absf(y[i] - exact))
	check(worst < 1e-3, "bake error %f m" % worst)
	# A vertical 50 m step at the row's edge folds back; the upper envelope wins and nothing is NaN.
	for k in n: h[k] = 300.0 if k < 200 else 350.0
	y = Cyl.bake_row(h, 1.0 / (R - 300.0), R, 1.0, n)
	# The face leans antispinward by H·sin φ ≈ 1.2 m here, so compare across the lean.
	check(y[201] - y[197] > 49.0, "step kept")
	for i in n: check(is_finite(y[i]), "finite %d" % i)
	# Probe inside the fold-back itself: mapped step edges are at x = 70.99 and 70.75, and a 0.1 m grid
	# puts an output at 70.9, covered by the low surface, the fold and the high one.
	y = Cyl.bake_row(h, 1.0 / (R - 300.0), R, 0.1, 2571)
	check(y[1994] - y[1994 - 100] > 49.0, "fold-back takes the upper envelope %f" % (y[1994] - y[1894]))
	# Station length comes from the mesh.
	var station: Station = load("res://station.tscn").instantiate()
	root.add_child(station)
	await process_frame
	check(absf(station.length - 32000.0) < 1.0, "length %f" % station.length)
	if failed: quit(1)
	else: print("PASS"); quit(0)
