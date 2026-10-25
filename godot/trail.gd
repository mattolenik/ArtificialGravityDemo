class_name Trail
extends MeshInstance3D
## Camera-facing ribbon following the parent's path (Unity TrailRenderer stand-in).

@export var width := 1.16
@export var lifetime := 100.0
@export var min_distance := 0.5

var points := PackedVector3Array()
var times := PackedFloat64Array()
var _now := 0.0
var _mesh := ImmediateMesh.new()


func _ready() -> void:
	top_level = true
	mesh = _mesh
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	material_override = m


func add_point(pos: Vector3, now: float) -> void:
	if points.size() > 0 and points[-1].distance_to(pos) < min_distance:
		return
	points.append(pos)
	times.append(now)


func prune(now: float) -> void:
	var n := 0
	while n < times.size() and now - times[n] > lifetime:
		n += 1
	if n > 0:
		points = points.slice(n)
		times = times.slice(n)


func _process(delta: float) -> void:
	_now += delta
	add_point((get_parent() as Node3D).global_position, _now)
	prune(_now)
	_mesh.clear_surfaces()
	var cam := get_viewport().get_camera_3d()
	if cam == null or points.size() < 2:
		return
	_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	for i in points.size():
		var p := points[i]
		var tangent := points[mini(i + 1, points.size() - 1)] - points[maxi(i - 1, 0)]
		var side := tangent.cross(cam.global_position - p).normalized() * width / 2.0
		_mesh.surface_add_vertex(p - side)
		_mesh.surface_add_vertex(p + side)
	_mesh.surface_end()
