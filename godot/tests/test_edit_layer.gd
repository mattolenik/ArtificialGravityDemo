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
	check(EditLayer.BLOB_SIZE == 128 * 128 * 32 and EditLayer.cell_offset(3, 2) == (2 * 128 + 3) * 32, "blob layout")
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
	blob.encode_float(o + 24, 0.75); blob.encode_float(o + 28, 0.02)
	var d := EditLayer.decode(blob, 5, 7)
	# 0.02 is not a float32: it reads back as the nearest one, so approx.
	check(d.surface == 412.5 and d.bedrock_top == 400.0 and d.material == 2 and d.mask == 255 and d.loose == 0.75 and is_equal_approx(d.water_depth, 0.02), "decode %s" % d)
	check(EditLayer.decode(blob, 6, 7).mask == 0, "untouched cell")
	# Edits round-trip through the world files, one zstd file per tile; a corrupt file is skipped.
	check(WorldIO.save_edits("test_world", {Vector2i(5, 7): blob, Vector2i(127, 3): blob}) == OK, "save edits")
	var loaded := WorldIO.load_edits("test_world")
	check(loaded.size() == 2 and loaded[Vector2i(127, 3)] == blob and loaded[Vector2i(5, 7)].size() == EditLayer.BLOB_SIZE, "load edits")
	var bad := FileAccess.open("user://worlds/test_world/tiles/9_9.edit", FileAccess.WRITE)
	bad.store_32(1); bad.store_32(12); bad.store_buffer(PackedByteArray([1, 2, 3])); bad.close()
	check(WorldIO.load_edits("test_world").size() == 2, "corrupt tile skipped")
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://worlds/test_world/tiles/9_9.edit"))
	# Slice 3: FIELDS name the two new float fields; a version 1 blob pads to the 32-byte cell and a version 1
	# file loads that way; saves are version 2.
	check(TerrainWindow.FIELDS.size() == 11 and TerrainWindow.FIELDS[9] == "loose" and TerrainWindow.FIELDS[10] == "water_depth", "fields %s" % [TerrainWindow.FIELDS])
	check(TerrainWindow.field_format("loose") == RenderingDevice.DATA_FORMAT_R32_SFLOAT and TerrainWindow.field_format("edit_mask") == RenderingDevice.DATA_FORMAT_R8_UNORM, "field formats")
	var v1 := PackedByteArray(); v1.resize(128 * 128 * 24)
	v1.encode_float((7 * 128 + 5) * 24, 412.5); v1.encode_u32((7 * 128 + 5) * 24 + 20, 2 | (255 << 24))
	var up := EditLayer.upgrade_v1(v1)
	var u := EditLayer.decode(up, 5, 7)
	check(up.size() == EditLayer.BLOB_SIZE and u.surface == 412.5 and u.material == 2 and u.mask == 255 and u.loose == 0.0 and u.water_depth == 0.0, "v1 upgrade %s" % u)
	check(EditLayer.decode(up, 6, 7).mask == 0 and EditLayer.decode(up, 5, 8).surface == 0.0, "v1 untouched cells")
	var old := FileAccess.open("user://worlds/test_world/tiles/8_8.edit", FileAccess.WRITE)
	old.store_32(1); old.store_32(v1.size()); old.store_buffer(v1.compress(FileAccess.COMPRESSION_ZSTD)); old.close()
	var mixed := WorldIO.load_edits("test_world")
	check(mixed.size() == 3 and mixed[Vector2i(8, 8)] == up, "a version 1 tile loads padded")
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://worlds/test_world/tiles/8_8.edit"))
	var saved := FileAccess.open("user://worlds/test_world/tiles/5_7.edit", FileAccess.READ)
	check(saved.get_32() == 2 and saved.get_32() == EditLayer.BLOB_SIZE, "saved as version 2")
	saved.close()
	var w2 := TerrainWindow.new(); w2.configure(p, 512, 1.0)
	w2.center_tile = Vector2i(10, 20)
	for t in w2.wanted_tiles(w2.center_tile): w2._resident[w2.slot_of(t)] = t
	check(w2.tile_at(w2.slot_of(Vector2i(10, 20))) == Vector2i(10, 20) and w2.tile_at(Vector2i(0, 0)) != Vector2i(-1, -1), "tile_at")
	# The wanted set from tile (8, 18); a centre one tile spinward evicts the column at 8.
	var ev := w2.evicted_by(Vector2i(11, 20))
	check(ev.size() == 4 and ev.has(Vector2i(8, 18)) and ev.has(Vector2i(8, 21)) and not ev.has(Vector2i(9, 18)), "evicted tiles %s" % [ev])
	# The edit zone holds a disc that stays HOLE_HALF - ZONE_MARGIN cells from its centre, theta the short way round.
	check(ColliderPatch.zone_holds(Vector2i(10, 10), Vector2i(10, 10), 5, 16384), "centre")
	check(ColliderPatch.zone_holds(Vector2i(10, 10), Vector2i(23, 10), 5, 16384), "13 + 5 = 18 holds")
	check(not ColliderPatch.zone_holds(Vector2i(10, 10), Vector2i(24, 10), 5, 16384), "14 + 5 = 19 moves")
	check(not ColliderPatch.zone_holds(Vector2i(10, 10), Vector2i(10, 29), 5, 16384), "along z too")
	check(ColliderPatch.zone_holds(Vector2i(2, 10), Vector2i(16382, 10), 5, 16384), "across the seam the delta is 4")
	if failed: quit(1)
	else: print("PASS"); quit(0)
