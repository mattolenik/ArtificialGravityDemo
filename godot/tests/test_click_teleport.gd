extends SceneTree

var failed := false

func check(ok: bool, msg: String) -> void:
	if not ok:
		push_error(msg)
		failed = true

func _initialize() -> void:
	# A test-sized world (test_macro_maps' size) with a flat surface 40 m over the hull.
	var p := WorldParams.new()
	p.radius = 64 * 32 / TAU + 40.0; p.h_sea = 40.0; p.length = 128 * 32
	var m := MacroMaps.new()
	m.surface = Image.create(64, 128, false, Image.FORMAT_RF)
	m.surface.fill(Color(40, 0, 0))
	var R := p.radius
	var down := Vector3(sin(1.0), -cos(1.0), 0)  # away from the axis at theta = 1
	# Straight down from 100 m up at theta = 1, z = 50 lands there.
	var hit = ClickTeleport.ground_hit(m, p, Cyl.position(1.0, 50.0, 100.0, R), down)
	check(hit != null and absf(hit.x - 1.0) < 1e-3 and absf(hit.y - 50.0) < 1e-3, "straight down: %s" % [hit])
	# Half down, half along the axis: 60 m of drop over 60 m of z, theta unchanged.
	hit = ClickTeleport.ground_hit(m, p, Cyl.position(1.0, 50.0, 100.0, R), down + Vector3(0, 0, 1))
	check(hit != null and absf(hit.x - 1.0) < 1e-3 and absf(hit.y - 110.0) < 0.01, "slanted: %s" % [hit])
	# Out through the +z end cap: no ground.
	hit = ClickTeleport.ground_hit(m, p, Cyl.position(1.0, p.length / 2.0 - 10.0, 100.0, R), Vector3(0, 0, 1))
	check(hit == null, "end cap: %s" % [hit])
	# Starting under the surface: no ground.
	hit = ClickTeleport.ground_hit(m, p, Cyl.position(1.0, 50.0, 10.0, R), down)
	check(hit == null, "underground: %s" % [hit])
	# Across the cylinder: from 100 m up at theta = 1, sideways (spinward) until the curving floor meets
	# the ray, which happens where the chord is 100 - 40 = 60 m below the start's circle.
	var spinward := Vector3(cos(1.0), sin(1.0), 0)
	hit = ClickTeleport.ground_hit(m, p, Cyl.position(1.0, 50.0, 100.0, R), spinward)
	var r0 := R - 100.0
	var want_theta := 1.0 + acos(r0 / (R - 40.0))
	check(hit != null and absf(hit.x - want_theta) < 1e-3 and absf(hit.y - 50.0) < 1e-3, "across: %s want %f" % [hit, want_theta])

	# ColliderPatch.surface_point: a plane of heights, read bilinearly and lifted along the patch's up.
	var patch := ColliderPatch.new()
	patch.set_frame(0.5 * PI, 300.0, 3200.0)
	var d := PackedFloat32Array()
	d.resize(257 * 257)
	for j in 257: for i in 257: d[j * 257 + i] = 0.5 * i + 0.25 * j
	patch.get_node("CollisionShape3D").shape.map_data = d
	var q := Vector3(10.25, 0, -3.5)  # in the patch's frame
	var want := patch.transform * Vector3(q.x, 0.5 * (q.x + 128) + 0.25 * (q.z + 128) + 2.0, q.z)
	var got := patch.surface_point(patch.transform * q, 2.0)
	check(got.distance_to(want) < 1e-3, "surface_point %s want %s" % [got, want])
	patch.free()
	if failed: quit(1)
	else: print("PASS"); quit(0)
