## Click to teleport: while `button` is down, a left click puts the ground body on the surface under the
## cursor (under the crosshair while the mouse is captured) and the click goes no further, so it does not
## capture the mouse. The point is found on the 32 m macro surface along the camera's ray; Terrain then
## stands the body on the exact collider once a patch covers it.
class_name ClickTeleport
extends Node

@export var terrain: Terrain
## A toggle button; clicks teleport while it is pressed.
@export var button: BaseButton

## m between samples along the ray. The macro surface is bilinear on 32 m cells, so nothing is skipped.
const STEP := 8.0


func _input(event: InputEvent) -> void:
	if not button.button_pressed or not (event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT):
		return
	var vp := get_viewport()
	if vp.gui_get_hovered_control() != null:
		return
	var pos: Vector2 = vp.get_visible_rect().size / 2.0 if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED else event.position
	var cam := vp.get_camera_3d()
	var station := terrain.station
	var hit = ground_hit(terrain.maps, terrain.params, station.to_local(cam.project_ray_origin(pos)),
			station.global_basis.inverse() * cam.project_ray_normal(pos))
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
