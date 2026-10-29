## The player's tools (the terrain slice 3 plan). The feet: walking pushes the loose dirt under them a little
## toward where the player is going, and a hard landing tamps it, the fourth folding it into the solid
## ground; every stamp goes through Terrain.stamp_tool, from Player's signals on the main thread after
## move_and_slide, one stamp per signal. The auger: E places one where the crosshair hits the ground within
## place_reach, its spoil on the far side from the player, and E within pickup_distance of it picks it up;
## one at a time, and E does nothing while the fly camera is the viewer (it climbs on E). The shovel: T scoops
## scoop_volume where the crosshair hits the ground within shovel_reach (loose first, then solid dirt and clay
## with the swell) and, held, scoops again every scoop_interval, the scoops adding up in the hand; Y dumps what
## it holds there as loose dirt. The held dirt shows on the HUD line and is not saved. The player is kept out
## of the dirt: a dump moves a player nearer its cell than the pile's repose radius plus PILE_MARGIN out to
## that distance, and every physics tick a player whose feet the collider has risen over (the dump on their
## cell, a pile slumping under them) is stood on it.
class_name Tools
extends Node

const AUGER := preload("res://terrain/auger.tscn")
## How far past a dump's repose radius the player is moved, in m.
const PILE_MARGIN := 0.5
## Feet this far under the collider count as buried, in m; they are stood STAND over it.
const BURIED := 0.1
const STAND := 0.05

@export var terrain: Terrain
@export var player: Player
## The shovel's HUD line.
@export var hud: Label

## Stamps made (accepted by stamp_tool), for the driver.
var pushes := 0
var tamps := 0
## The placed auger, null while there is none.
var auger: Auger
## m³ of loose dirt the shovel holds (a scoop's counter, solid ground times the swell); 0 when empty.
var held := 0.0
## Scoops and dumps made (accepted by stamp_tool), and times the player was stood on risen ground, for the driver.
var scoops := 0
var dumps := 0
var lifts := 0
## Whether a scoop's counter is in flight, and its landing's m³ (-1 until it lands; _process consumes it).
var _scoop_pending := false
var _scoop_result := -1.0
## T's press: down, whether a scoop fired during it, and the last scoop's time (ms).
var _t_down := false
var _t_scooped := false
var _t_scoop_at := 0


func _ready() -> void:
	player.stepped.connect(_on_stepped)
	player.landed.connect(_on_landed)


## A push along the floor velocity v (global), quantised to an axis, from push_min_speed up. The feet do
## not stamp while the renderer is stalled (TerrainSim.stalled: the window not drawn), when every stamp's
## timed list would pile into one GPU frame that never turns over.
func _on_stepped(v: Vector3) -> void:
	var t := terrain.tool_params
	if v.length() < t.push_min_speed or terrain.sim.stalled():
		return
	var op := _foot(EditLayer.MODE_PUSH, t.push_share, t.push_max)
	var theta := Cyl.theta_of(terrain.station.to_local(player.global_position))
	op.dir = push_dir(terrain.station.global_basis.inverse() * v, theta)
	pushes += int(terrain.stamp_tool(op))


## A tamp under the feet for a landing at speed (m/s, downward) from tamp_land_speed up.
func _on_landed(speed: float) -> void:
	var t := terrain.tool_params
	if speed < t.tamp_land_speed or terrain.sim.stalled():
		return
	tamps += int(terrain.stamp_tool(_foot(EditLayer.MODE_TAMP, t.tamp_step, terrain.materials.swell_factor[0])))


func _unhandled_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or key.echo or terrain.viewer != player:
		return
	if key.keycode == KEY_T:
		_t_down = key.pressed
		if key.pressed:
			_t_scooped = false
		return
	if not key.pressed:
		return
	if key.keycode == KEY_Y:
		if held <= 0.0:
			print("The shovel is empty")
		elif not _scoop_pending and not terrain.sim.stalled():
			dump()
		return
	if key.keycode != KEY_E:
		return
	var at := terrain.station.to_local(player.global_position)
	if auger != null:
		if at.distance_to(auger.position) <= terrain.tool_params.pickup_distance:
			pickup()
		else:
			print("Pick up the auger first")
		return
	var hit := DebugEdit.look_hit(get_viewport(), [player.get_rid()])
	var q: Vector3 = terrain.station.to_local(hit.position) if not hit.is_empty() else at
	if hit.is_empty() or q.distance_to(at) > terrain.tool_params.place_reach:
		print("Nowhere to place the auger")
		return
	var theta := Cyl.theta_of(q)
	place(theta, q.z, push_dir(q - at, theta))


## Places an auger at the cell of station-local (theta, z), its spoil disc toward side, and stands it on the
## collider there (the macro surface where no patch covers it). Null, with a line printed, while an auger is
## placed, within bore_radius + 1 cells of the player's cell (the shaft would stand through the player), or
## where its bore or spoil disc could not be stamped.
func place(theta: float, z: float, side: Vector2i) -> Auger:
	var t := terrain.tool_params
	var p := terrain.params
	var c := p.cell_of(theta, z)
	if auger != null:
		print("One auger at a time: pick it up first")
		return null
	var me := player_cell()
	@warning_ignore("integer_division")
	var d := Vector2i(posmod(c.x - me.x + p.n_theta() / 2, p.n_theta()) - p.n_theta() / 2, c.y - me.y)
	if d.length_squared() <= (t.bore_radius + 1) * (t.bore_radius + 1):
		print("Too close to place the auger")
		return null
	if not (terrain.can_stamp(c, t.bore_radius) and terrain.can_stamp(Auger.spoil_cell_of(c, side, t.spoil_offset, p.n_theta()), t.spoil_radius)):
		print("The auger cannot bore there")
		return null
	var theta_c := (c.x + 0.5) * p.dtheta()
	var z_c := -p.length / 2.0 + c.y + 0.5
	var hull := Cyl.position(theta_c, z_c, 0.0, p.radius)
	var ground := Cyl.height_of(terrain.patch.surface_point(hull, 0.0), p.radius) if terrain.patch.covers(hull) \
			else terrain.height_at(theta_c, z_c)
	auger = AUGER.instantiate()
	auger.setup(terrain, c, side, ground)
	terrain.station.add_child(auger)
	terrain.set_obstacle(c, t.bore_radius)
	return auger


## Takes the placed auger away; its hole stays and opens to the loose dirt around it.
func pickup() -> void:
	terrain.set_obstacle(TerrainSim.NO_CELL, -1)
	auger.queue_free()
	auger = null


## Scoops scoop_volume at cell, or where the crosshair hits within shovel_reach when none is given; its counter
## lands in _scooped. A line printed when there is no such hit or the stamp is refused.
func scoop(cell := TerrainSim.NO_CELL) -> void:
	var c := _shovel_cell(cell)
	var op := _shovel_op(c, EditLayer.MODE_SCOOP, terrain.tool_params.scoop_volume)
	op.counted = _scooped
	if c != TerrainSim.NO_CELL and terrain.stamp_tool(op):
		_scoop_pending = true
		scoops += 1
	else:
		print("Nothing to scoop there")


## Deposits what the shovel holds as loose dirt at cell, or where the crosshair hits within shovel_reach when
## none is given, and moves the player clear of the pile (_clear_of); the shovel keeps it, with a line printed,
## when there is no such hit or the stamp is refused.
func dump(cell := TerrainSim.NO_CELL) -> void:
	var c := _shovel_cell(cell)
	if c != TerrainSim.NO_CELL and terrain.stamp_tool(_shovel_op(c, EditLayer.MODE_DEPOSIT, held)):
		_clear_of(c, held)
		held = 0.0
		dumps += 1
		_show_held()
	else:
		print("Nowhere to dump the dirt")


## A scoop's counter landing, inside the readback flush: stores only (_process takes it up).
func _scooped(volume: float, _wet: bool) -> void:
	_scoop_result = volume


## Takes up a landed scoop (what it took is held, or a scoop that found only rock says so), then scoops while
## T is held: at once on the press, then every scoop_interval once the last scoop has landed. A refused scoop,
## a scoop that found rock, or the viewer leaving the player ends the press's scooping, so a hold on the sky or
## on rock does not print every interval.
func _process(_delta: float) -> void:
	if _scoop_result >= 0.0:
		_scoop_pending = false
		if _scoop_result <= 1e-6:
			print("Nothing to scoop here")
			_t_down = false
		else:
			held += _scoop_result
		_scoop_result = -1.0
		_show_held()
	if terrain.viewer != player:
		_t_down = false
	if not _t_down or _scoop_pending or terrain.sim.stalled():
		return
	var now := Time.get_ticks_msec()
	if _t_scooped and now - _t_scoop_at < terrain.tool_params.scoop_interval * 1000.0:
		return
	scoop()
	_t_scooped = true
	_t_scoop_at = now
	if not _scoop_pending:
		_t_down = false


## Every physics tick: the player's feet under the collider by more than BURIED (a dump on their cell or a pile
## slumping under them raised it; a body cannot push up through a heightfield and fell through it) are stood
## STAND over it, along the player's up, the velocity kept. Not while a teleport holds the player over the macro
## surface (Terrain._on_live stands them).
func _physics_process(_delta: float) -> void:
	if terrain.viewer != player or terrain.teleporting():
		return
	var up := player.up_direction
	var feet := terrain.station.to_local(player.global_position - up)
	var patch := terrain.patch
	if not patch.covers(feet):
		return
	var under := (patch.surface_point(feet, 0.0) - feet).dot(patch.transform.basis.y)
	if under > BURIED:
		player.global_position += up * (under + STAND)
		lifts += 1
		print("Stood on the ground risen %.2f m over the feet" % under)


## The radius in m of the cone a pile of v m³ settles into at repose_deg: v = π r² (r tan repose) / 3.
static func pile_radius(v: float, repose_deg: float) -> float:
	return pow(3.0 * v / (PI * tan(deg_to_rad(repose_deg))), 1.0 / 3.0)


## Moves the player clear of a dump of v m³ at cell c: off the dump's disc (on it the pile rises under them and
## _physics_process stands them on it) but nearer the cell's centre along the hull than the pile's repose
## radius plus PILE_MARGIN, they are moved to that distance away from the centre and stood on the collider
## there, their velocity kept. Nothing where the patch does not cover the place.
func _clear_of(c: Vector2i, v: float) -> void:
	var p := terrain.params
	var me := terrain.station.to_local(player.global_position)
	var centre := Vector2((c.x + 0.5) * p.dtheta(), -p.length / 2.0 + c.y + 0.5)
	var r := p.radius - Cyl.height_of(me, p.radius)
	var off := Vector2(wrapf(Cyl.theta_of(me) - centre.x, -PI, PI) * r, me.z - centre.y)
	var keep := pile_radius(v, terrain.materials.repose_dry[0]) + PILE_MARGIN
	if off.length() <= terrain.tool_params.scoop_radius + 0.5 or off.length() >= keep:
		return
	off = off.normalized() * keep
	var to := Cyl.position(centre.x + off.x / r, centre.y + off.y, Cyl.height_of(me, p.radius), p.radius)
	if not terrain.patch.covers(to):
		return
	player.global_position = terrain.station.global_transform * terrain.patch.surface_point(to, 1.0 + STAND)


func _show_held() -> void:
	hud.text = "Shovel: %.2f m³" % held if held > 0.0 else ""


## aim when given, else the cell of the crosshair's hit (the player's body excluded) within shovel_reach of the
## player; NO_CELL when there is none.
func _shovel_cell(aim: Vector2i) -> Vector2i:
	if aim != TerrainSim.NO_CELL:
		return aim
	var hit := DebugEdit.look_hit(get_viewport(), [player.get_rid()])
	if hit.is_empty():
		return TerrainSim.NO_CELL
	var q := terrain.station.to_local(hit.position)
	if q.distance_to(terrain.station.to_local(player.global_position)) > terrain.tool_params.shovel_reach:
		return TerrainSim.NO_CELL
	return terrain.params.cell_of(Cyl.theta_of(q), q.z)


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


## A shovel stamp of mode at c over the scoop disc, its limit the swell (a deposit ignores it).
func _shovel_op(c: Vector2i, mode: int, amount: float) -> EditLayer.Op:
	var op := _foot(mode, amount, terrain.materials.swell_factor[0])
	op.cell = c
	op.radius = terrain.tool_params.scoop_radius
	return op
