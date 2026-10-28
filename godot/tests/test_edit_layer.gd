extends SceneTree

var failed := false

func check(ok: bool, msg: String) -> void:
	if not ok:
		push_error(msg)
		failed = true

func _initialize() -> void:
	var p := WorldParams.new()
	var w := TerrainWindow.new()
	w.configure(p, 512, 1.0)
	check(EditLayer.BLOB_SIZE == 128 * 128 * 24 and EditLayer.cell_offset(3, 2) == (2 * 128 + 3) * 24, "blob layout")
	# A disc inside one tile; one straddling the seam at theta = 0; one at the station's first rows; one over four tiles.
	var one := EditLayer.stamp_tiles(w, Vector2i(200, 300), 5)
	check(one.size() == 1 and one[0] == Vector2i(1, 2), "one tile %s" % [one])
	var seam := EditLayer.stamp_tiles(w, Vector2i(2, 500), 5)
	check(seam.size() == 2 and seam.has(Vector2i(127, 3)) and seam.has(Vector2i(0, 3)), "seam %s" % [seam])
	var end := EditLayer.stamp_tiles(w, Vector2i(16380, 1), 5)
	check(end.size() == 2 and end.has(Vector2i(127, 0)) and end.has(Vector2i(0, 0)), "first rows clamp, theta wraps %s" % [end])
	for t in EditLayer.stamp_tiles(w, Vector2i(10, p.n_z() - 2), 5): check(t.y == w.tiles_along - 1, "last rows clamp")
	var four := EditLayer.stamp_tiles(w, Vector2i(127, 127), 3)
	check(four.size() == 4 and four.has(Vector2i(0, 0)) and four.has(Vector2i(1, 1)), "four tiles %s" % [four])
	# The pack's four slots hold any disc up to radius 64; from 65 the box can span three tiles per axis.
	check(EditLayer.stamp_tiles(w, Vector2i(192, 192), 64).size() == 4 and EditLayer.stamp_tiles(w, Vector2i(192, 192), 65).size() == 9, "radius 64 and 65")
	# decode reads back what encode_* wrote in the blob layout.
	var blob := PackedByteArray(); blob.resize(EditLayer.BLOB_SIZE)
	var o := EditLayer.cell_offset(5, 7)
	blob.encode_float(o, 412.5); blob.encode_float(o + 4, 400.0); blob.encode_float(o + 16, 0.0)
	blob.encode_u32(o + 20, 2 | (255 << 24))
	var d := EditLayer.decode(blob, 5, 7)
	check(d.surface == 412.5 and d.bedrock_top == 400.0 and d.material == 2 and d.mask == 255, "decode %s" % d)
	check(EditLayer.decode(blob, 6, 7).mask == 0, "untouched cell")
	# Edits round-trip through the world files, one zstd file per tile; a corrupt file is skipped.
	check(WorldIO.save_edits("test_world", {Vector2i(5, 7): blob, Vector2i(127, 3): blob}) == OK, "save edits")
	var loaded := WorldIO.load_edits("test_world")
	check(loaded.size() == 2 and loaded[Vector2i(127, 3)] == blob and loaded[Vector2i(5, 7)].size() == EditLayer.BLOB_SIZE, "load edits")
	var bad := FileAccess.open("user://worlds/test_world/tiles/9_9.edit", FileAccess.WRITE)
	bad.store_32(1); bad.store_32(12); bad.store_buffer(PackedByteArray([1, 2, 3])); bad.close()
	check(WorldIO.load_edits("test_world").size() == 2, "corrupt tile skipped")
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://worlds/test_world/tiles/9_9.edit"))
	# The edit zone holds a disc that stays HOLE_HALF - ZONE_MARGIN cells from its centre, theta the short way round.
	check(ColliderPatch.zone_holds(Vector2i(10, 10), Vector2i(10, 10), 5, 16384), "centre")
	check(ColliderPatch.zone_holds(Vector2i(10, 10), Vector2i(23, 10), 5, 16384), "13 + 5 = 18 holds")
	check(not ColliderPatch.zone_holds(Vector2i(10, 10), Vector2i(24, 10), 5, 16384), "14 + 5 = 19 moves")
	check(not ColliderPatch.zone_holds(Vector2i(10, 10), Vector2i(10, 29), 5, 16384), "along z too")
	check(ColliderPatch.zone_holds(Vector2i(2, 10), Vector2i(16382, 10), 5, 16384), "across the seam the delta is 4")
	if failed: quit(1)
	else: print("PASS"); quit(0)
