## A rigid cube that falls under the station's fictitious forces and air drag.
class_name Box
extends RigidBody3D

## The station whose rotating frame this box lives in. Set before add_child.
var station: Station
## Drag coefficient × frontal area (m²). 0 disables air drag.
var drag_area := 0.0


## Sizes the cube (edge in m) and derives its mass (density in kg/m³) and drag area.
func setup(size: float, density: float, drag_coefficient: float) -> void:
	var shape := BoxShape3D.new()
	shape.size = Vector3.ONE * size
	$CollisionShape3D.shape = shape
	var mesh := BoxMesh.new()
	mesh.size = Vector3.ONE * size
	$MeshInstance3D.mesh = mesh
	mass = density * size * size * size
	drag_area = drag_coefficient * size * size


func _physics_process(_delta: float) -> void:
	apply_central_force(mass * station.acceleration_at(global_position, linear_velocity)
			+ station.drag_force(global_position, linear_velocity, drag_area))
