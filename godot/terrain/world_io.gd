## Saves and loads a generated world under user://worlds/<name>/: params.tres, maps.res and tiles/, which
## holds one <ti>_<tj>.edit file per edited tile: u32 version (1), u32 raw size (EditLayer.BLOB_SIZE), then
## the tile's edit blob zstd-compressed.
class_name WorldIO

const EDIT_VERSION := 1


static func _dir(name: String) -> String:
	return "user://worlds/%s" % name


static func save(maps: MacroMaps, params: WorldParams, name: String) -> Error:
	var dir := _dir(name)
	var err := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir + "/tiles"))
	if err != OK:
		return err
	err = ResourceSaver.save(params, dir + "/params.tres")
	if err != OK:
		return err
	return ResourceSaver.save(maps, dir + "/maps.res")


## [params, maps], or [] when the world is missing or unreadable.
static func load_world(name: String) -> Array:
	if not exists(name):
		return []
	var params := ResourceLoader.load(_dir(name) + "/params.tres", "", ResourceLoader.CACHE_MODE_IGNORE) as WorldParams
	var maps := ResourceLoader.load(_dir(name) + "/maps.res", "", ResourceLoader.CACHE_MODE_IGNORE) as MacroMaps
	if params == null or maps == null:
		return []
	return [params, maps]


static func exists(name: String) -> bool:
	return FileAccess.file_exists(_dir(name) + "/maps.res")


## Writes each blob of blobs (wrapped tile Vector2i -> PackedByteArray of EditLayer.BLOB_SIZE) to its
## tiles/<ti>_<tj>.edit, replacing the file; tiles not in blobs are left alone. Stops at the first error.
## ponytail: written in place, so a crash mid-write costs that tile; write a temp file and rename if it ever does.
static func save_edits(name: String, blobs: Dictionary) -> Error:
	var dir := _dir(name) + "/tiles"
	var err := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	if err != OK:
		return err
	for tile: Vector2i in blobs:
		var f := FileAccess.open("%s/%d_%d.edit" % [dir, tile.x, tile.y], FileAccess.WRITE)
		if f == null:
			return FileAccess.get_open_error()
		var blob: PackedByteArray = blobs[tile]
		f.store_32(EDIT_VERSION)
		f.store_32(blob.size())
		f.store_buffer(blob.compress(FileAccess.COMPRESSION_ZSTD))
		err = f.get_error()
		f.close()
		if err != OK:
			return err
	return OK


## Wrapped tile Vector2i -> blob, for every tiles/*.edit of the world that is version 1, EditLayer.BLOB_SIZE
## raw and decompresses to that size; any other file is skipped with a warning naming it.
static func load_edits(name: String) -> Dictionary:
	var dir := _dir(name) + "/tiles"
	var out := {}
	for file in DirAccess.get_files_at(dir):
		if not file.ends_with(".edit"):
			continue
		var path := dir + "/" + file
		var xy := file.get_basename().split("_")
		var f := FileAccess.open(path, FileAccess.READ)
		if xy.size() != 2 or not xy[0].is_valid_int() or not xy[1].is_valid_int() or f == null \
				or f.get_length() < 8 or f.get_32() != EDIT_VERSION or f.get_32() != EditLayer.BLOB_SIZE:
			push_warning("Skipping edit file %s: not a version %d tile of %d bytes" % [path, EDIT_VERSION, EditLayer.BLOB_SIZE])
			continue
		var blob := f.get_buffer(f.get_length() - 8).decompress(EditLayer.BLOB_SIZE, FileAccess.COMPRESSION_ZSTD)
		if blob.size() != EditLayer.BLOB_SIZE:
			push_warning("Skipping edit file %s: its body does not decompress to %d bytes" % [path, EditLayer.BLOB_SIZE])
			continue
		out[Vector2i(xy[0].to_int(), xy[1].to_int())] = blob
	return out
