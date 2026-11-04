## Saves and loads a generated world under user://worlds/<name>/: params.tres, maps.res and tiles/, which
## holds one <ti>_<tj>.edit file per edited tile: u32 version (3), u32 raw size (EditLayer.BLOB_SIZE), then
## the tile's edit blob zstd-compressed. A version 1 file (raw size EditLayer.V1_BLOB_SIZE: cells without
## loose and water_depth) and a version 2 file (EditLayer.V2_BLOB_SIZE: no gaps) still load, padded by
## EditLayer.upgrade_v1 / upgrade_v2; saves are always version 3.
class_name WorldIO

const EDIT_VERSION := 3
## Raw blob size by file version.
const RAW_SIZE := {1: EditLayer.V1_BLOB_SIZE, 2: EditLayer.V2_BLOB_SIZE, 3: EditLayer.BLOB_SIZE}


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


## Wrapped tile Vector2i -> blob of EditLayer.BLOB_SIZE, for every tiles/*.edit of the world that is version
## 3 of EditLayer.BLOB_SIZE raw, or version 1 or 2 of its raw size (upgraded), and decompresses to its raw
## size; any other file is skipped with a warning naming it.
static func load_edits(name: String) -> Dictionary:
	var dir := _dir(name) + "/tiles"
	var out := {}
	for file in DirAccess.get_files_at(dir):
		if not file.ends_with(".edit"):
			continue
		var path := dir + "/" + file
		var xy := file.get_basename().split("_")
		var f := FileAccess.open(path, FileAccess.READ)
		var version := f.get_32() if f != null and f.get_length() >= 8 else 0
		var raw: int = RAW_SIZE.get(version, 0)
		if xy.size() != 2 or not xy[0].is_valid_int() or not xy[1].is_valid_int() or raw == 0 or f.get_32() != raw:
			push_warning("Skipping edit file %s: not a version %d tile of %d bytes" % [path, EDIT_VERSION, EditLayer.BLOB_SIZE])
			continue
		var blob := f.get_buffer(f.get_length() - 8).decompress(raw, FileAccess.COMPRESSION_ZSTD)
		if blob.size() != raw:
			push_warning("Skipping edit file %s: its body does not decompress to %d bytes" % [path, raw])
			continue
		if version == 1:
			blob = EditLayer.upgrade_v1(blob)
		elif version == 2:
			blob = EditLayer.upgrade_v2(blob)
		out[Vector2i(xy[0].to_int(), xy[1].to_int())] = blob
	return out


## Deletes every file of the world's tiles/ (its saved edits); the directory, the generated maps and the
## params stay (load_edits wants the directory). OK with no tiles/ at all. Stops at the first error.
static func wipe_edits(name: String) -> Error:
	var dir := _dir(name) + "/tiles"
	if not DirAccess.dir_exists_absolute(dir):
		return OK
	for file in DirAccess.get_files_at(dir):
		var err := DirAccess.remove_absolute(dir + "/" + file)
		if err != OK:
			return err
	return OK
