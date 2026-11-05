extends SceneTree

var failed := false

func check(ok: bool, msg: String) -> void:
	if not ok:
		push_error(msg)
		failed = true

func _initialize() -> void:
	var m: MaterialSet = load("res://terrain/materials.tres")
	check(MaterialSet.ROCK_FACE == 3, "rock face id")
	check(m.names.size() == 5 and m.names[3] == "rock_face", "names %s" % [m.names])
	for prop in ["color", "porosity", "wetting_distance", "swell_factor", "repose_dry", "repose_damp", "repose_saturated",
			"roof_span_dry", "roof_span_saturated", "stable_slope_dry", "stable_slope_saturated", "compression_index"]:
		var a = m.get(prop)
		check(a.size() == 5, "%s has 5 rows" % prop)
		check(a[3] == a[2], "%s: rock face equals rock" % prop)
	if failed: quit(1)
	else: print("PASS"); quit(0)
