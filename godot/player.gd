## A walker that stands upright inside the station, with its head toward the spin axis.
## Kinematic, so it adds the station's fictitious acceleration to its own velocity.
class_name Player
extends CharacterBody3D

## The station whose rotating frame this player lives in.
@export var station: Station
## Top walking speed along the floor, in m/s.
@export var run_speed := 15.0
## How fast walking speeds up and slows down, in m/s². Also the floor's grip.
@export var ground_accel := 40.0
## Upward speed a jump adds, in m/s.
@export var jump_speed := 3.0
## Shortest time between jumps, in s.
@export var jump_delay := 1.0

var _jump_cooldown := 0.0


func _physics_process(delta: float) -> void:
	_jump_cooldown -= delta
	var down := station.down_at(global_position)
	if down == Vector3.ZERO:
		# On the spin axis there is no "up" to align to.
		move_and_slide()
		return
	# Stand upright, keeping the heading, as Unity's FromToRotation did.
	up_direction = -down
	global_basis = (Basis(Quaternion(global_basis.y, -down)) * global_basis).orthonormalized()
	velocity += station.acceleration_at(global_position, velocity) * delta
	if is_on_floor():
		var radial := velocity.project(down)
		var wish := -global_basis.z * _axis(KEY_W, KEY_UP, KEY_S, KEY_DOWN) \
				+ global_basis.x * _axis(KEY_D, KEY_RIGHT, KEY_A, KEY_LEFT)
		var along := (velocity - radial).move_toward(wish.limit_length() * run_speed, ground_accel * delta)
		velocity = radial + along
		if Input.is_physical_key_pressed(KEY_SPACE) and _jump_cooldown <= 0.0:
			velocity += up_direction * jump_speed
			_jump_cooldown = jump_delay
	move_and_slide()


## +1 if either positive key is held, -1 for either negative key, 0 for both or neither.
func _axis(pos: Key, pos_alt: Key, neg: Key, neg_alt: Key) -> float:
	var held := func(a: Key, b: Key) -> bool:
		return Input.is_physical_key_pressed(a) or Input.is_physical_key_pressed(b)
	return float(held.call(pos, pos_alt)) - float(held.call(neg, neg_alt))
