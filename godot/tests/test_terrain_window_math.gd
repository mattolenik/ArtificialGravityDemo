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
	# What a window draws, for the coarser levels' holes: first cell centre to one cell past the last.
	w.center_tile = Vector2i(10, 249)  # wanted set from tile (8, 246)
	var e := w.extent()
	check(absf(e.x - 1280.5 * p.dtheta()) < 1e-6 and absf(e.y - (-16000.0 + 246 * 128 + 256.5)) < 1e-3 \
			and absf(e.z - 256 * p.dtheta()) < 1e-6 and e.w == 256.0, "main extent %s" % e)
	f.center_tile = Vector2i(3, 30)  # wanted set from tile (1, 27): 8 m cells 128..639 around, the last row ends at 31748 m
	e = f.extent()
	check(absf(e.x - 3076.0 * p.dtheta()) < 1e-6 and absf(e.y + e.w - (-16000.0 + 31748.0)) < 1e-3 \
			and absf(e.z - 2048 * p.dtheta()) < 1e-6 and e.w == 2048.0, "far extent %s" % e)
	# Tile nodes share one frame on the hull at the wanted set's middle grid point; each tile's offset from
	# it is in window cells, theta the short way round (this set straddles theta = 0, from tile (126, 0)).
	var nodes: Array[MeshInstance3D] = []
	for i in 16:
		var m := MeshInstance3D.new()
		m.add_child(MeshInstance3D.new())
		nodes.append(m)
	Terrain.place_tiles(w, nodes, Vector2i(0, 0))
	check(nodes[0].position.is_equal_approx(Cyl.position(0.0, -16000.0 + 256.0, 0.0, p.radius)), "tile frame %s" % nodes[0].position)
	for m in nodes: check(m.transform == nodes[0].transform, "one frame for every tile")
	# Slot (x, y) holds tile (x, y) for x < 2 and (124 + x, y) for x >= 2: centre cells 64, 192, -192, -64.
	for i in 16:
		var want := Vector2i([64, 192, -192, -64][i % 4], -192 + 128 * (i / 4))
		for g: MeshInstance3D in [nodes[i], nodes[i].get_child(0)]:
			check(g.get_instance_shader_parameter("tile_offset") == want, "slot %d offset %s, want %s" % [i, g.get_instance_shader_parameter("tile_offset"), want])
	for m in nodes: m.free()
	# Collider patch frame: local Y points at the axis, X is spinward, origin on the hull.
	var patch := ColliderPatch.new()
	patch.set_frame(0.5 * PI, 300.0, 3200.0)
	check(patch.position.is_equal_approx(Vector3(3200, 0, 300)), "patch origin %s" % patch.position)
	check(patch.basis.y.is_equal_approx(Vector3(-1, 0, 0)), "patch up toward the axis %s" % patch.basis.y)
	check(patch.basis.x.is_equal_approx(Vector3(0, 1, 0)), "patch x spinward %s" % patch.basis.x)
	check(patch.basis.z.is_equal_approx(Vector3(0, 0, 1)), "patch z axial")
	var shape: HeightMapShape3D = patch.get_node("CollisionShape3D").shape
	check(shape.map_width == 257 and shape.map_depth == 257, "patch samples")
	check(patch.needs_rebuild(Vector3(3200, 0, 300) + patch.basis.x * 65.0), "rebuild beyond 64 m")
	check(not patch.needs_rebuild(Vector3(3200, 0, 300) + patch.basis.x * 63.0), "no rebuild within 64 m")
	# Coverage is Chebyshev, 4 m inside the 128 m half extent, and only once the patch has a frame.
	for v: Vector3 in [Vector3(123, 0, 0), Vector3(-123, 0, 0), Vector3(0, 0, 123), Vector3(0, 0, -123), Vector3(123, 0, 123)]:
		check(patch.covers(patch.transform * v), "covers %s" % v)
	for v: Vector3 in [Vector3(125, 0, 0), Vector3(-125, 0, 0), Vector3(0, 0, 125), Vector3(0, 0, -125), Vector3(125, 0, 125)]:
		check(not patch.covers(patch.transform * v), "does not cover %s" % v)
	var fresh := ColliderPatch.new()
	check(not fresh.covers(Vector3.ZERO), "a patch with no frame covers nothing")
	fresh.free()
	patch.free()  # outside the tree, so nothing else frees it; a leaked body prints errors at exit
	if failed: quit(1)
	else: print("PASS"); quit(0)
