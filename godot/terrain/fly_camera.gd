## A free debug camera, toggled by F. While active it is the viewer of the terrain and the emitter (the
## windows, far levels and collider patch follow it) and the player is frozen; WASD and Q/E move it in its
## own frame at `speed`, the scroll wheel scales the speed, and the mouse looks around while captured
## (click captures, Esc releases, as for the player). F again hands the viewer back to the player, which
## stays frozen until the collider patch has landed around it again. Place it under the Station.
class_name FlyCamera
extends Camera3D

@export var terrain: Terrain
@export var player: Player
@export var emitter: Emitter
## m/s; each scroll wheel notch scales it by 1.25.
@export var speed := 50.0
## Radians of turn per pixel of mouse movement.
@export var mouse_sensitivity := 0.003

var active := false


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_F:
		toggle()
	elif not active:
		return
	elif event is InputEventMouseButton and event.pressed:
		match event.button_index:
			MOUSE_BUTTON_LEFT: Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			MOUSE_BUTTON_WHEEL_UP: speed *= 1.25
			MOUSE_BUTTON_WHEEL_DOWN: speed /= 1.25
	elif event.is_action_pressed("ui_cancel"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		look(event.relative)


## Takes over from the player at its head, looking where its camera looks; or hands back to it. Does
## nothing while the player is held (at spawn, or waiting for its patch after a hand-back).
func toggle() -> void:
	if not active:
		if player.process_mode == PROCESS_MODE_DISABLED:
			return
		active = true
		global_transform = player.get_node("CameraPivot").global_transform
		player.process_mode = PROCESS_MODE_DISABLED
		_set_viewer(self)
		make_current()
		return
	active = false
	_set_viewer(player)
	player.get_node("CameraPivot/Camera3D").make_current()
	# The patch followed the camera; Terrain rebuilds it around the player now.
	while terrain.patch.needs_rebuild(terrain.station.to_local(player.global_position)):
		await terrain.patch.live
	player.process_mode = PROCESS_MODE_INHERIT


func _set_viewer(node: Node3D) -> void:
	terrain.viewer = node
	if emitter:
		emitter.viewer = node


## Turns about the local up (toward the axis) and tilts about the camera's own X, from mouse movement in
## pixels.
func look(motion: Vector2) -> void:
	var up := -terrain.station.down_at(global_position)
	if up == Vector3.ZERO:
		up = global_basis.y
	global_basis = (Basis(up, -motion.x * mouse_sensitivity) * global_basis \
			* Basis(Vector3.RIGHT, -motion.y * mouse_sensitivity)).orthonormalized()


func _process(delta: float) -> void:
	if not active:
		return
	var move := Vector3(_axis(KEY_D, KEY_A), _axis(KEY_E, KEY_Q), _axis(KEY_S, KEY_W))
	global_position += global_basis * move * speed * delta


## +1 if the positive key is held, -1 for the negative one, 0 for both or neither.
func _axis(pos: Key, neg: Key) -> float:
	return float(Input.is_physical_key_pressed(pos)) - float(Input.is_physical_key_pressed(neg))
