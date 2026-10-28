## The player's feet as tools (the terrain slice 3 plan): walking pushes the loose dirt under them a little
## toward where the player is going, and a hard landing tamps it, the fourth folding it into the solid
## ground. Every stamp goes through Terrain.stamp_tool, from Player's signals on the main thread after
## move_and_slide, one stamp per signal.
class_name Tools
extends Node

@export var terrain: Terrain
@export var player: Player

## Stamps made (accepted by stamp_tool), for the driver.
var pushes := 0
var tamps := 0


func _ready() -> void:
	player.stepped.connect(_on_stepped)
	player.landed.connect(_on_landed)


## A push along the floor velocity v (global), quantised to an axis, from push_min_speed up.
func _on_stepped(v: Vector3) -> void:
	var t := terrain.tool_params
	if v.length() < t.push_min_speed:
		return
	var op := _foot(EditLayer.MODE_PUSH, t.push_share, t.push_max)
	var theta := Cyl.theta_of(terrain.station.to_local(player.global_position))
	op.dir = push_dir(terrain.station.global_basis.inverse() * v, theta)
	pushes += int(terrain.stamp_tool(op))


## A tamp under the feet for a landing at speed (m/s, downward) from tamp_land_speed up.
func _on_landed(speed: float) -> void:
	var t := terrain.tool_params
	if speed < t.tamp_land_speed:
		return
	tamps += int(terrain.stamp_tool(_foot(EditLayer.MODE_TAMP, t.tamp_step, terrain.materials.swell_factor[0])))


## The cell of the player's origin.
func player_cell() -> Vector2i:
	var p := terrain.station.to_local(player.global_position)
	return terrain.params.cell_of(Cyl.theta_of(p), p.z)


## The axis step of a station-space velocity at angle theta: (±1, 0) spinward or antispinward, (0, ±1) along
## the axis, whichever component is larger (spinward on a tie); zero when both are under 1e-6.
static func push_dir(v_local: Vector3, theta: float) -> Vector2i:
	var dt := v_local.dot(Vector3(cos(theta), sin(theta), 0))
	var dz := v_local.z
	if absf(dt) < 1e-6 and absf(dz) < 1e-6:
		return Vector2i.ZERO
	if absf(dt) >= absf(dz):
		return Vector2i(int(signf(dt)), 0)
	return Vector2i(0, int(signf(dz)))


## A foot-sized stamp of mode at the player's cell that leaves packing to the settle pack.
func _foot(mode: int, amount: float, limit: float) -> EditLayer.Op:
	var op := EditLayer.Op.new()
	op.cell = player_cell()
	op.radius = terrain.tool_params.foot_radius
	op.mode = mode
	op.amount = amount
	op.limit = limit
	op.pack = false
	return op
