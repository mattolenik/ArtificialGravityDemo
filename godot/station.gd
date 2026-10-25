## Simulates artificial gravity in a spinning cylinder. The cylinder itself stays still and
## the scene is simulated in its rotating frame, where Newton's laws gain two fictitious
## forces: centrifugal (ω²r, outward) and Coriolis (−2Ω×v). Both are exact, not approximations.
class_name Station
extends Node3D

## Apparent gravity at the floor, in m/s². Sets the spin rate: ω = √(a / radius).
@export var acceleration := 9.8
## Local axis the station spins about (right-handed).
@export var axis := Vector3(0, 0, 1)
## Air density at the floor, in kg/m³.
@export var air_density := 1.225
## Air pressure at the floor, in Pa.
@export var air_pressure := 101325.0

## Distance from the axis to the outer hull, read from the mesh in _ready.
var radius: float


## Isothermal air density at distance r from the axis: hydrostatic balance
## against the centrifugal potential. Only ~3% thinner at the axis of a 500 m, 1 g station.
static func air_density_at(r: float, hull_radius: float, w: float, floor_density: float, floor_pressure: float) -> float:
	return floor_density * exp(-0.5 * w * w * (hull_radius * hull_radius - r * r) * floor_density / floor_pressure)


## Acceleration of a free body in a frame spinning at w (rad/s),
## given its offset from a point on the axis and its velocity relative to the frame.
static func fictitious_acceleration(offset: Vector3, velocity: Vector3, w: Vector3) -> Vector3:
	var centrifugal := -w.cross(w.cross(offset))
	var coriolis := -2.0 * w.cross(velocity)
	return centrifugal + coriolis


func _ready() -> void:
	var mesh: MeshInstance3D = find_children("*", "MeshInstance3D")[0]
	# Assuming the mesh is a perfect cylinder on the outside,
	# its bounds read (radius, length, radius) before the 90° turn.
	radius = mesh.get_aabb().end.x
	mesh.material_override = preload("res://oneill_grid.tres")
	var shape := CollisionShape3D.new()
	shape.shape = mesh.mesh.create_trimesh_shape()
	# Bodies live inside the hull and hit it from the inside.
	shape.shape.backface_collision = true
	var body := StaticBody3D.new()
	body.add_child(shape)
	# Under the mesh, not the station, so the collider picks up the 90° turn.
	mesh.add_child(body)


## Angular velocity in global space, rad/s.
func omega() -> Vector3:
	return global_basis * axis.normalized() * sqrt(acceleration / radius)


## Spin axis direction in global space; unlike omega(), defined at zero spin.
func _axis_dir() -> Vector3:
	return (global_basis * axis).normalized()


## Outward from the axis, i.e. "down" for anyone standing on the floor. Zero on the axis.
func down_at(pos: Vector3) -> Vector3:
	return (pos - global_position).slide(_axis_dir()).normalized()


## Fictitious acceleration of a body at global pos moving at vel relative to the station.
func acceleration_at(pos: Vector3, vel: Vector3) -> Vector3:
	return fictitious_acceleration(pos - global_position, vel, omega())


## Air drag in N. The air co-rotates with the station, so it is at rest in this frame.
func drag_force(pos: Vector3, vel: Vector3, drag_area: float) -> Vector3:
	var w := omega()
	var r := (pos - global_position).slide(_axis_dir()).length()
	var density := air_density_at(r, radius, w.length(), air_density, air_pressure)
	return -0.5 * density * drag_area * vel.length() * vel
