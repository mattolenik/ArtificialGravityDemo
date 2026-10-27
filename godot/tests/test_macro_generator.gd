extends SceneTree

var failed := false

func check(ok: bool, msg: String) -> void:
	if not ok:
		push_error(msg)
		failed = true

func small_params(seed: int) -> WorldParams:
	var p := WorldParams.new()
	p.seed = seed
	p.radius = 64 * 32 / TAU + 40.0; p.h_sea = 40.0; p.length = 128 * 32
	p.h_ref = 100.0; p.sea_width = 800.0; p.sea_edge_noise = 100.0; p.sea_depth_max = 40.0
	p.island_count = 1; p.region_scale = 600.0; p.river_sources_per_km2 = 4.0; p.river_q_min = 1.0
	p.cliff_min = 40.0; p.cliff_fraction = 0.3
	return p

func _initialize() -> void:
	var p := small_params(7)
	var g := MacroGenerator.new()
	var m := g.generate(p)
	var w := p.macro_w(); var h := p.macro_h()
	check(m.surface.get_width() == w and m.surface.get_height() == h, "size")
	# Seas: a band around z = 0, water at sea level there, sea floor below it.
	var sea_cells := 0
	for y in h: for x in w:
		if m.region.get_pixel(x, y).r8 == 0:
			sea_cells += 1
			check(absf(m.water_surface.get_pixel(x, y).r - 40.0) < 1e-3, "sea level at %d %d" % [x, y])
			check(m.surface.get_pixel(x, y).r < 40.0, "sea floor below sea level")
	check(sea_cells > w * h / 10 and sea_cells < w * h / 2, "sea band size %d" % sea_cells)
	# Drainage: every land cell has a flow direction toward a processed neighbour, except the shoreline seeds.
	var no_dir := 0
	for y in h: for x in w:
		if m.region.get_pixel(x, y).r8 != 0 and m.flow_dir.get_pixel(x, y).r8 == 0: no_dir += 1
	check(no_dir < w * h / 20, "cells without flow dir %d" % no_dir)
	# Rivers: at least one, every one ends in the sea, Q grows downstream, polyline well formed.
	check(m.rivers.size() >= 1, "rivers %d" % m.rivers.size())
	for r in m.rivers:
		check(r.size() % 4 == 0 and r.size() >= 8, "polyline stride")
		var mouth := m.cell(r[r.size() - 4], r[r.size() - 3], p)
		check(m.region.get_pixel(mouth.x, mouth.y).r8 == 0 or m.water_surface.get_pixel(mouth.x, mouth.y).r > 0.0, "river reaches water")
		check(r[r.size() - 1] >= r[3], "Q grows downstream")
	# Profiles: river water surface is at or above sea level and non-increasing toward the mouth.
	for r in m.rivers:
		var prev := INF
		for i in range(0, r.size(), 4):
			var c := m.cell(r[i], r[i + 1], p)
			var ws := m.water_surface.get_pixel(c.x, c.y).r
			check(ws >= 40.0 - 1e-3 and ws <= prev + 1e-3, "profile monotone")
			prev = ws
	# River texture: zero distance on river cells, positive elsewhere, carries width and surface.
	var c0 := m.cell(m.rivers[0][0], m.rivers[0][1], p)
	var rv := m.river.get_pixel(c0.x, c0.y)
	check(rv.r < 1e-3 and rv.g > 0.0 and rv.b >= 40.0, "river texture on river %s" % rv)
	var far_cells := 0
	for y in h: for x in w: if m.river.get_pixel(x, y).r > 100.0: far_cells += 1
	check(far_cells > 0, "river distance field")
	# The river distance is the exact Euclidean distance to the nearest river cell, wrapping in theta
	# (the sea floor's distance to shore uses the same transform).
	var river_cells: Array[Vector2i] = []
	for r in m.rivers:
		for i in range(0, r.size() - 4, 4): river_cells.append(m.cell(r[i], r[i + 1], p))
	for y in range(0, h, 5): for x in range(0, w, 3):
		var best := INF
		for c in river_cells:
			var dx := absi(x - c.x); dx = mini(dx, w - dx)
			best = minf(best, Vector2(dx, y - c.y).length() * p.macro_cell)
		check(absf(m.river.get_pixel(x, y).r - best) < 1e-2, "river distance at %d %d: %f vs %f" % [x, y, m.river.get_pixel(x, y).r, best])
	# Polyline theta is unwrapped: consecutive vertices never jump across theta = 0.
	for r in m.rivers:
		for i in range(4, r.size(), 4): check(absf(r[i] - r[i - 4]) < PI, "theta unwrapped")
	# Determinism.
	var m2 := MacroGenerator.new().generate(small_params(7))
	check(m.surface.get_data() == m2.surface.get_data() and m.water_surface.get_data() == m2.water_surface.get_data(), "deterministic")
	check(MacroGenerator.new().generate(small_params(8)).surface.get_data() != m.surface.get_data(), "seed matters")
	if failed: quit(1)
	else: print("PASS"); quit(0)
