## Ctrl-click to teleport. Holding Ctrl frees the mouse so the cursor can point at a target; a click while
## Ctrl is held puts the ground body on the surface under the cursor and goes no further, so it does not
## capture the mouse; letting go of Ctrl captures the mouse again if it was captured before. On macOS Godot
## reports Ctrl-left-click as a right click, so either button counts. The point is found on the 32 m
## macro surface along the camera's ray; Terrain then stands the body on the exact collider once a patch
## covers it.
class_name ClickTeleport
extends Node

@export var terrain: Terrain

## m between samples along the ray. The macro surface is bilinear on 32 m cells, so nothing is skipped.
const STEP := 8.0

## Whether letting go of Ctrl should capture the mouse again.
var _recapture := false


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.keycode == KEY_CTRL and not event.echo:
		if event.pressed:
			_recapture = Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		elif _recapture:
			_recapture = false
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		return
	if not (event is InputEventMouseButton and event.pressed and event.ctrl_pressed \
			and event.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]):
		return
	var vp := get_viewport()
	if vp.gui_get_hovered_control() != null:
		return
	var cam := vp.get_camera_3d()
	var station := terrain.station
	var hit = ground_hit(terrain.maps, terrain.params, station.to_local(cam.project_ray_origin(event.position)),
			station.global_basis.inverse() * cam.project_ray_normal(event.position))
	if hit != null:
		terrain.teleport(hit.x, hit.y)
	vp.set_input_as_handled()


## The first point where the ray from origin along dir (both in station space) meets the macro surface,
## as (theta, z); null if the ray starts under the surface or leaves through an end cap first.
static func ground_hit(maps: MacroMaps, params: WorldParams, origin: Vector3, dir: Vector3) -> Variant:
	dir = dir.normalized()
	var above := func(t: float) -> bool:
		var p := origin + dir * t
		return Cyl.height_of(p, params.radius) > maps.sample(maps.surface, Cyl.theta_of(p), p.z, params)
	if not above.call(0.0):
		return null
	var half := params.length / 2.0
	var t := 0.0
	# Inside the cylinder every ray reaches the hull (height 0, never above the floor) or an end cap.
	while above.call(t + STEP):
		t += STEP
		if absf((origin + dir * t).z) > half:
			return null
	var lo := t
	var hi := t + STEP
	for i in 24:
		var mid := (lo + hi) / 2.0
		if above.call(mid):
			lo = mid
		else:
			hi = mid
	var p := origin + dir * hi
	return Vector2(Cyl.theta_of(p), p.z)
