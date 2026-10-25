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


## Isothermal air density at distance r from the axis: hydrostatic balance
## against the centrifugal potential. Only ~3% thinner at the axis of a 500 m, 1 g station.
static func air_density_at(r: float, radius: float, omega: float, floor_density: float, floor_pressure: float) -> float:
	return floor_density * exp(-0.5 * omega * omega * (radius * radius - r * r) * floor_density / floor_pressure)


## Acceleration of a free body in a frame spinning at omega (rad/s),
## given its offset from a point on the axis and its velocity relative to the frame.
static func fictitious_acceleration(offset: Vector3, velocity: Vector3, omega: Vector3) -> Vector3:
	var centrifugal := -omega.cross(omega.cross(offset))
	var coriolis := -2.0 * omega.cross(velocity)
	return centrifugal + coriolis
