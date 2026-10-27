## Times one default-size generation (seed 1) per stage and saves it as the "default" world. Not a
## test (run.sh only runs test_*.gd): godot --headless --path . -s res://tests/time_macro_generator.gd
extends SceneTree


func _initialize() -> void:
	var params := WorldParams.new()
	params.seed = 1
	var start := Time.get_ticks_usec()
	var last := [start, ""]  # [time the current stage started, its name]
	var maps := MacroGenerator.new().generate(params, func(stage: String, _fraction: float) -> void:
		var now := Time.get_ticks_usec()
		if last[1] != "":
			print("%-10s %7.2f s" % [last[1], (now - last[0]) / 1e6])
		last[0] = now
		last[1] = stage)
	print("%-10s %7.2f s" % ["total", (Time.get_ticks_usec() - start) / 1e6])
	var err := WorldIO.save(maps, params, "default")
	if err != OK:
		push_error("save failed: %s" % error_string(err))
	quit(0 if err == OK else 1)
