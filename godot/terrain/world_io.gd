## Saves and loads a generated world under user://worlds/<name>/: params.tres, maps.res and an
## empty tiles/ directory reserved for per-tile deltas.
class_name WorldIO


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
