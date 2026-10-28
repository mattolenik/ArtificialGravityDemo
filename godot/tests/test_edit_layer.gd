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
	# decode reads back what encode_* wrote in the blob layout.
	var blob := PackedByteArray(); blob.resize(EditLayer.BLOB_SIZE)
	var o := EditLayer.cell_offset(5, 7)
	blob.encode_float(o, 412.5); blob.encode_float(o + 4, 400.0); blob.encode_float(o + 16, 0.0)
	blob.encode_u32(o + 20, 2 | (255 << 24))
	var d := EditLayer.decode(blob, 5, 7)
	check(d.surface == 412.5 and d.bedrock_top == 400.0 and d.material == 2 and d.mask == 255, "decode %s" % d)
	check(EditLayer.decode(blob, 6, 7).mask == 0, "untouched cell")
	if failed: quit(1)
	else: print("PASS"); quit(0)
