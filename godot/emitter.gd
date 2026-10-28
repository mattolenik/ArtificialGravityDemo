## Spawns test boxes inside the station to see how falling objects behave.
## Place it as a child of the station; only its local Z (position along the axis) is used,
## unless a viewer is set, whose angle and Z then replace the spawn point's.
class_name Emitter
extends Node3D

enum LaunchDirection { RANDOM, SPINWARD, ANTISPINWARD, TOWARD_AXIS, TOWARD_FLOOR }

@export var station: Station
@export var box_scene: PackedScene
@export var info_label: Label
@export var spawn_camera: Camera3D
## When set, boxes spawn at this node's angle around the axis and its Z instead of the fixed point.
@export var viewer: Node3D

@export_group("Spawn point")
## Distance from the spin axis in m: 0 is on the axis, the cylinder's radius is the floor.
## With a viewer set, 0 means 10 m above the viewer instead (its own distance from the axis - 10 m).
@export_range(0, 3200, 0.1, "or_greater") var distance_from_axis := 0.0
## Angle around the axis in degrees: 0 is straight below the axis (local -Y), positive is spinward.
@export var angle_around_axis := 0.0
## Boxes per spawn.
@export_range(1, 100, 1, "or_greater") var count := 1
## When spawning several boxes, each is offset randomly within this radius (m).
@export_range(0, 100, 0.1, "or_greater") var spread := 10.0

@export_group("Box")
## Edge length in m.
@export_range(0.01, 50, 0.01, "or_greater") var box_size := 5.0
## kg/m³; mass = density × size³. Water is 1000, wood about 600, 8 is a very light foam.
@export_range(0.001, 1000, 0.001, "or_greater") var density := 8.0
## Air drag coefficient; drag area = this × size². About 1.05 for a cube face-on, 0 disables air drag.
@export_range(0, 2, 0.01, "or_greater") var drag_coefficient := 1.05

@export_group("Trail")
## Width in m.
@export_range(0, 10, 0.01, "or_greater") var trail_width := 1.16
## How long the trail lasts, in s.
@export_range(0, 300, 0.1, "or_greater") var trail_time := 100.0

@export_group("Launch (relative to the station)")
@export var direction := LaunchDirection.RANDOM
## Each box gets a random speed in m/s between these. Set both to 0 to drop at rest.
@export_range(0, 50, 0.01, "or_greater") var min_speed := 0.2
@export_range(0, 50, 0.01, "or_greater") var max_speed := 0.8

var _spawned: Array[Box] = []


func _process(_delta: float) -> void:
	if info_label:
		info_label.text = info_text()


## Outward at the spawn point, in station space.
func _outward() -> Vector3:
	var a := deg_to_rad(angle_around_axis)
	if viewer:
		a = Cyl.theta_of(station.to_local(viewer.global_position))
	return Vector3(sin(a), -cos(a), 0)


## distance_from_axis, or with a viewer and distance_from_axis 0, 10 m above the viewer.
func _spawn_distance() -> float:
	if viewer and distance_from_axis == 0.0:
		var p := station.to_local(viewer.global_position)
		return maxf(Vector2(p.x, p.y).length() - 10.0, 0.0)
	return distance_from_axis


func _local_spawn_point() -> Vector3:
	var source := viewer if viewer else self
	return _outward() * _spawn_distance() + Vector3(0, 0, station.to_local(source.global_position).z)


func _local_spinward() -> Vector3:
	return Vector3(0, 0, 1).cross(_outward()) * signf(station.axis.z)


func _local_launch_direction() -> Vector3:
	match direction:
		LaunchDirection.SPINWARD: return _local_spinward()
		LaunchDirection.ANTISPINWARD: return -_local_spinward()
		LaunchDirection.TOWARD_AXIS: return -_outward()
		LaunchDirection.TOWARD_FLOOR: return _outward()
	var v := Vector2.from_angle(randf() * TAU)
	return Vector3(v.x, v.y, 0)


func spawn_point() -> Vector3:
	return station.to_global(_local_spawn_point())


## Toward the axis at the spawn point, i.e. "up" for anything standing below it.
func spawn_up() -> Vector3:
	return station.global_basis * -_outward()


func spinward() -> Vector3:
	return station.global_basis * _local_spinward()


func spawn() -> void:
	for i in count:
		var offset := Vector3.ZERO
		if count > 1:
			offset = Vector3(randfn(0, 1), randfn(0, 1), randfn(0, 1)).normalized() \
					* spread * pow(randf(), 1.0 / 3.0)
		var box: Box = box_scene.instantiate()
		box.station = station
		box.setup(box_size, density, drag_coefficient)
		var trail: Trail = box.get_node("Trail")
		trail.width = trail_width
		trail.lifetime = trail_time
		trail.frame = station
		box.add_to_group(Terrain.GROUND_GROUP)
		station.add_child(box)
		box.global_position = station.to_global(_local_spawn_point() + offset)
		box.global_rotation = station.global_rotation
		box.linear_velocity = station.global_basis * _local_launch_direction() \
				* randf_range(min_speed, max_speed)
		_spawned.append(box)


func clear_spawned() -> void:
	for box in _spawned:
		if is_instance_valid(box):
			box.queue_free()
	_spawned.clear()


func spawned_count() -> int:
	_spawned = _spawned.filter(is_instance_valid)
	return _spawned.size()


func info_text() -> String:
	var distance := _spawn_distance()
	var gravity := station.acceleration * distance / station.radius
	var outside := ""
	if distance + box_size / 2.0 > station.radius:
		outside = "\nThe spawn point is outside the floor."
	return "Floor is %.0f m from the axis. Apparent gravity at the spawn point: %.2f m/s².%s\n%d boxes spawned." \
			% [station.radius, gravity, outside, spawned_count()]


## Looks along the station's axis with "up" toward the axis, so boxes fall down the screen
## and any Coriolis drift shows up as sideways motion.
func toggle_spawn_view() -> void:
	if spawn_camera.current:
		spawn_camera.clear_current(true)
		return
	var size := maxf(box_size * 10.0, spread * 3.0 if count > 1 else 0.0)
	var axis_dir := station.global_basis * Vector3(0, 0, 1)
	spawn_camera.look_at_from_position(spawn_point() + axis_dir * size, spawn_point(), spawn_up())
	spawn_camera.make_current()
