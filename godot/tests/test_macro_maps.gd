extends SceneTree

var failed := false

func check(ok: bool, msg: String) -> void:
	if not ok:
		push_error(msg)
		failed = true

func _initialize() -> void:
	var p := WorldParams.new()
	check(p.n_theta() == 16384, "n_theta %d" % p.n_theta())
	check(p.n_z() == 32000, "n_z %d" % p.n_z())
	check(p.macro_w() == 512 and p.macro_h() == 1000, "macro size %d %d" % [p.macro_w(), p.macro_h()])
	check(absf(p.g_sea() - 9.8 * 2800.0 / 3200.0) < 1e-6, "g_sea")
	check(absf(p.h_mtn() - 1000.0 * 9.8 / p.g_sea()) < 1e-6, "h_mtn")
	# A test-sized world: 64 cells around, 128 along.
	p.radius = 64 * 32 / TAU + 40.0; p.h_sea = 40.0; p.length = 128 * 32
	check(p.n_theta() == 2048 and p.macro_w() == 64 and p.macro_h() == 128, "small world %d %d" % [p.macro_w(), p.macro_h()])
	var m := MacroMaps.new()
	m.surface = Image.create(64, 128, false, Image.FORMAT_RF)
	for x in 64: for y in 128: m.surface.set_pixel(x, y, Color(float(x), 0, 0))
	# Bilinear with cell centres at (i + 0.5) cells, wrapping in theta, clamping in z.
	var mc := p.dtheta() * 32  # one macro cell in radians
	check(absf(m.sample(m.surface, 0.5 * mc, 0.0, p) - 0.0) < 1e-4, "cell 0 centre")
	check(absf(m.sample(m.surface, TAU, 0.0, p) - 31.5) < 1e-3, "theta = TAU is the midpoint of cells 63 and 0: %f" % m.sample(m.surface, TAU, 0.0, p))
	check(absf(m.sample(m.surface, 0.0, 0.0, p) - 31.5) < 1e-3, "theta = 0 is the same midpoint")
	check(absf(m.sample(m.surface, 10.5 * mc, 1e9, p) - 10.0) < 1e-4, "z clamps high")
	check(absf(m.sample(m.surface, 10.5 * mc, -1e9, p) - 10.0) < 1e-4, "z clamps low")
	check(m.cell(TAU + 0.5 * p.dtheta() * 32, -p.length / 2, p) == Vector2i(0, 0), "cell wraps and starts at -L/2")
	# Save and load round trip.
	m.spawn = Vector2(1.5, -200)
	m.rivers = [PackedFloat32Array([0.1, 10, 5, 3, 0.2, 20, 6, 4])]
	check(WorldIO.save(m, p, "test_world") == OK, "save")
	check(WorldIO.exists("test_world"), "exists")
	var loaded: Array = WorldIO.load_world("test_world")
	check(loaded.size() == 2 and loaded[0] is WorldParams and loaded[1] is MacroMaps, "load types")
	check(loaded[1].spawn == m.spawn and loaded[1].rivers[0][3] == 3.0, "load content")
	check(absf(loaded[1].surface.get_pixel(5, 7).r - 5.0) < 1e-6, "image survived")
	check(loaded[0].h_sea == 40.0, "params survived")
	if failed: quit(1)
	else: print("PASS"); quit(0)
