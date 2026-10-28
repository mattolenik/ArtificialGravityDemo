## Debug digging: hold [ to lower and ] to raise the ground where the screen centre points, a RADIUS-cell
## disc by STEP m at its centre, RATE stamps a second. The point is the first hit of a physics ray from the
## current camera through the screen centre (the viewer's own body excluded), so you dig where you look on
## the live collider; no hit, no stamp. Exists to exercise the edit pipeline (Terrain.edit); the real tools
## are a later slice.
class_name DebugEdit
extends Node

@export var terrain: Terrain

const RADIUS := 5.0
const STEP := 0.25
const RATE := 10.0
## m.
const REACH := 2000.0

## Ticks in ms before which no stamp is made.
var _next := 0


func _process(_delta: float) -> void:
	var dh := -STEP if Input.is_physical_key_pressed(KEY_BRACKETLEFT) \
			else (STEP if Input.is_physical_key_pressed(KEY_BRACKETRIGHT) else 0.0)
	if dh == 0.0 or Time.get_ticks_msec() < _next:
		return
	_next = Time.get_ticks_msec() + roundi(1000.0 / RATE)
	var vp := get_viewport()
	var cam := vp.get_camera_3d()
	var mid := vp.get_visible_rect().size / 2.0
	var from := cam.project_ray_origin(mid)
	var ray := PhysicsRayQueryParameters3D.create(from, from + cam.project_ray_normal(mid) * REACH)
	if terrain.viewer is CollisionObject3D:
		ray.exclude = [(terrain.viewer as CollisionObject3D).get_rid()]
	var hit := cam.get_world_3d().direct_space_state.intersect_ray(ray)
	if hit.is_empty():
		return
	var p := terrain.station.to_local(hit.position)
	terrain.edit(Cyl.theta_of(p), p.z, RADIUS, dh)
