extends SceneTree

var failed := false

func check(ok: bool, msg: String) -> void:
	if not ok:
		push_error(msg)
		failed = true

func _initialize() -> void:
	var p := WorldParams.new()
	var w := TerrainWindow.new()
	# Addressing only; no RenderingDevice headless, so setup() is not called.
	w.configure(p, 512, 1.0)
	check(w.tiles_around == 128 and w.tiles_along == 250 and w.slots == 4, "tile counts %d %d %d" % [w.tiles_around, w.tiles_along, w.slots])
	check(TerrainWindow.wrap_tile(-1, 128) == 127 and TerrainWindow.wrap_tile(128, 128) == 0, "wrap")
	check(w.slot_of(Vector2i(127, 5)) == Vector2i(3, 1) and w.slot_of(Vector2i(128, 5)) == Vector2i(0, 1), "slots across the seam")
	check(w.texel_origin(Vector2i(129, 6)) == Vector2i(128, 256), "texel origin")
	check(w.tile_of_cell(16383, 31999) == Vector2i(127, 249), "last cell")
	var c := w.tile_center(Vector2i(0, 0))
	check(absf(c.x - 64 * p.dtheta()) < 1e-9 and absf(c.y - (-16000.0 + 64.0)) < 1e-6, "tile centre %s" % c)
	# The wanted set around a seam tile wraps in theta and clamps at the ends in z.
	var wanted := w.wanted_tiles(Vector2i(0, 0))
	check(wanted.size() == 16, "wanted count %d" % wanted.size())
	check(wanted.has(Vector2i(127, 0)) and wanted.has(Vector2i(126, 0)) and wanted.has(Vector2i(1, 0)), "wraps around the seam")
	for t in wanted: check(t.y >= 0, "no tile before the first row")
	wanted = w.wanted_tiles(Vector2i(10, 249))
	for t in wanted: check(t.y <= 249, "no tile after the last row")
	check(wanted.has(Vector2i(10, 246)), "window slides back at the end")
	# The far-ring window at 8 m has 16 tiles around.
	var f := TerrainWindow.new(); f.configure(p, 512, 8.0)
	check(f.tiles_around == 16 and f.tiles_along == 31, "far window %d %d" % [f.tiles_around, f.tiles_along])
	if failed: quit(1)
	else: print("PASS"); quit(0)
