## Windowed check for TerrainWindow: loads (or generates) the default world, fills a 512 window around
## theta = 0 at the station's midpoint, around the spawn site with `-- --spawn`, or around 1 m cell
## (i, j) with `-- --at=i,j`, around the first macro cell with a cliff rim with `-- --cliff`, and adds the P dump.
## `-- --auto` presses P itself after a few frames, then quits.
extends Node

var _window: TerrainWindow
var _frames := 0


func _ready() -> void:
	var world := WorldIO.load_world("default")
	if world.is_empty():
		print("generating the default world")
		var p := WorldParams.new()
		world = [p, MacroGenerator.new().generate(p)]
		WorldIO.save(world[1], p, "default")
	var params: WorldParams = world[0]
	var maps: MacroMaps = world[1]
	_window = TerrainWindow.new()
	_window.setup(params, maps)
	@warning_ignore("integer_division")
	var center := _window.tile_of_cell(0, params.n_z() / 2)
	for arg in OS.get_cmdline_user_args():
		if arg == "--spawn":
			var cell := params.cell_of(maps.spawn.x, maps.spawn.y)
			center = _window.tile_of_cell(cell.x, cell.y)
		elif arg == "--cliff":
			var rim := _first_cliff(params, maps)
			if rim.x < 0:
				push_error("no cliff with a drop in the world")
			else:
				# The macro cell's centre: a macro cell spans 32 cells each way.
				center = _window.tile_of_cell(rim.x * 32 + 16, rim.y * 32 + 16)
		elif arg.begins_with("--at="):
			var ij := arg.trim_prefix("--at=").split_floats(",")
			center = _window.tile_of_cell(int(ij[0]), int(ij[1]))
	_window.move_to(center)
	print("window around tile %s, %d tiles resident" % [center, _window.resident_tiles().size()])
	var dump := preload("res://terrain/debug_window_dump.gd").new()
	dump.window = _window
	dump.center = center
	add_child(dump)


## The first macro cell flagged as a cliff rim that really has a drop (a neighbour at least cliff_min lower;
## a rim at the height cap has none), or (-1, -1).
static func _first_cliff(params: WorldParams, maps: MacroMaps) -> Vector2i:
	var w := params.macro_w()
	var flags := maps.cliff.get_data()
	var k := flags.find(255)
	while k >= 0:
		var x := k % w
		@warning_ignore("integer_division")
		var y := k / w
		var top := maps.surface.get_pixel(x, y).r
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var ny: int = y + d.y
			if ny >= 0 and ny < params.macro_h() and top - maps.surface.get_pixel(posmod(x + d.x, w), ny).r >= params.cliff_min:
				return Vector2i(x, y)
		k = flags.find(255, k + 1)
	return Vector2i(-1, -1)


func _process(_delta: float) -> void:
	if not OS.get_cmdline_user_args().has("--auto"):
		return
	_frames += 1
	if _frames == 5:
		var key := InputEventKey.new()
		key.keycode = KEY_P
		key.pressed = true
		Input.parse_input_event(key)
	elif _frames == 10:
		get_tree().quit()
