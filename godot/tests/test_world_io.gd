extends SceneTree

var failed := false

func check(ok: bool, msg: String) -> void:
	if not ok:
		push_error(msg)
		failed = true

func _initialize() -> void:
	# test_wipe_edits: a world's saved tiles go, its generated maps stay, and nothing else of user://worlds is
	# touched; wiping a world with no tiles is fine.
	var name := "test_wipe_edits"
	var dir := "user://worlds/%s" % name
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir + "/tiles"))
	var keep := FileAccess.open(dir + "/maps.res", FileAccess.WRITE)
	keep.store_32(7)
	keep.close()
	var blob := PackedByteArray()
	blob.resize(EditLayer.BLOB_SIZE)
	check(WorldIO.save_edits(name, {Vector2i(1, 2): blob, Vector2i(3, 4): blob}) == OK and WorldIO.load_edits(name).size() == 2, "two tiles saved")
	check(WorldIO.wipe_edits(name) == OK and WorldIO.load_edits(name).is_empty() and DirAccess.get_files_at(dir + "/tiles").is_empty(), "the tiles go")
	check(FileAccess.file_exists(dir + "/maps.res"), "the maps stay")
	check(WorldIO.wipe_edits(name) == OK, "wiping again is fine")
	DirAccess.remove_absolute(dir + "/maps.res")
	DirAccess.remove_absolute(dir + "/tiles")
	DirAccess.remove_absolute(dir)
	if failed: quit(1)
	else: print("PASS"); quit(0)
