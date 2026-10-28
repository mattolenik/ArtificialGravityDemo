extends SceneTree

var failed := false

func check(ok: bool, msg: String) -> void:
	if not ok:
		push_error(msg)
		failed = true

func _initialize() -> void:
	var R := 3200.0
	var dtheta := TAU / 16384
	# A 45 degree slope at 1200 m (0.767 m cells): the bake lies on the drawn polyline, so a drawn vertex
	# misses the collider's chord only by the hull's curvature over one cell, under 1 mm.
	var h := PackedFloat32Array()
	h.resize(405)
	for k in 405: h[k] = 1200.0 + (k - 202) * 0.767
	var e := NoiseReport.row_mismatch(h, dtheta, R, Cyl.bake_row(h, dtheta, R, 1.0, 257))
	check(e.size() >= 300 and e.size() <= 360, "samples within 128 m: %d" % e.size())
	var worst := 0.0
	for x in e: worst = maxf(worst, absf(x))
	check(worst < 1e-3, "slope mismatch %f m" % worst)
	# Per-cell noise of +-0.2 m: the collider's 1 m chords cut the zigzag by 5 cm or more somewhere and
	# never by more than its 0.4 m peak to peak.
	for k in 405: h[k] = 1200.0 + (0.2 if k % 2 == 0 else -0.2)
	var row := Cyl.bake_row(h, dtheta, R, 1.0, 257)
	e = NoiseReport.row_mismatch(h, dtheta, R, row)
	worst = 0.0
	for x in e: worst = maxf(worst, absf(x))
	check(worst > 0.05 and worst <= 0.4, "zigzag mismatch %f m" % worst)
	# A NaN sample (a cell outside the window) and its two neighbours are skipped, not propagated.
	h[200] = NAN
	var e2 := NoiseReport.row_mismatch(h, dtheta, R, row)
	check(e2.size() == e.size() - 3, "NaN and its neighbours skipped: %d vs %d" % [e2.size(), e.size()])
	for x in e2: check(is_finite(x), "NaN leaked")
	# Cells under 1 m: a collider sample around a vertex two past the NaN can lie on the bake's chord to what
	# it read there (here 50 m off, as a macro value can be), so that vertex is skipped too.
	h[200] = 1200.2
	h[205] = 1250.0
	row = Cyl.bake_row(h, dtheta, R, 1.0, 257)
	h[205] = NAN
	worst = 0.0
	for x in NoiseReport.row_mismatch(h, dtheta, R, row): worst = maxf(worst, absf(x))
	check(worst <= 0.4, "macro chord leaked: %f m" % worst)
	# rock_site: the highest macro cell with bedrock within 1 m of the surface, else the highest cell.
	var p := WorldParams.new()
	p.radius = 64 * 32 / TAU + 40.0; p.h_sea = 40.0; p.length = 128 * 32
	var m := MacroMaps.new()
	m.surface = Image.create(64, 128, false, Image.FORMAT_RF)
	m.bedrock_top = Image.create(64, 128, false, Image.FORMAT_RF)
	for x in 64: for y in 128:
		m.surface.set_pixel(x, y, Color(float(x + y), 0, 0))
		m.bedrock_top.set_pixel(x, y, Color(float(x + y) - 10.0, 0, 0))
	var mc := 32 * p.dtheta()
	check(NoiseReport.rock_site(m, p).is_equal_approx(Vector2(63.5 * mc, -p.length / 2.0 + 127.5 * 32)), "no bare rock: the highest cell")
	m.bedrock_top.set_pixel(20, 30, Color(50.0, 0, 0))  # bare, surface 50
	m.bedrock_top.set_pixel(10, 15, Color(25.0, 0, 0))  # bare, lower
	check(NoiseReport.rock_site(m, p).is_equal_approx(Vector2(20.5 * mc, -p.length / 2.0 + 30.5 * 32)), "the highest bare cell")
	if failed: quit(1)
	else: print("PASS"); quit(0)
