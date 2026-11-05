## The player's tools (the terrain slice 3 plan; the shovel of the tunnels design). The feet: a hard landing
## tamps the loose dirt under them, the fourth folding it into the solid ground, in the voxel box
## (VoxelBox.tamp) at the feet's point, from Player's landed signal on the main thread after move_and_slide
## (walking no longer pushes the loose ahead of the feet: removed 2026-11-04 by the user's choice, for how
## it looked and felt). The auger: E places one where the
## crosshair hits the ground within place_reach, its spoil on the far side from the player, and E within
## pickup_distance of it picks it up; one at a time, and E does nothing while the fly camera is the viewer
## (it climbs on E). The shovel: the crosshair's hit on the terrain colliders within shovel_reach (any
## surface: floor, wall or roof) is the aim, shown as a ring decal (ShovelPatch) while there is one; at a wall
## (a face steeper than about 40° no lower than a metre under the feet, or ground rising ahead: a hit from a
## quarter metre over the feet to head height) the ball is lifted onto a level floor,
## the last wall scoop's while the feet are near it, else half a metre under the feet (level_floor), so a tunnel
## dug walking in runs level instead of ramping with its half-cut floor; T scoops the ball of scoop_ball m there
## in the voxel box (loose first, then solid dirt and clay with the swell,
## never rock) and, held, scoops again every scoop_interval, the scoops adding up in the hand; Y dumps what
## it holds there as loose dirt, what does not fit the ball staying in the hand. The held dirt shows on the HUD
## line and is not saved; under a litre left after a dump (the ball's voxels round down) counts as empty. The
## player is kept out of the dirt: a dump moves a player nearer its point than the
## pile's repose radius plus PILE_MARGIN out to that distance, and every physics tick a player whose feet the
## collider has risen over (the dump on their cell, a pile slumping under them) is stood on it. The pillar: P
## at the crosshair's hit within shovel_reach stands a pillar from the floor there up to the roof over it
## within the free height and a metre (VoxelBox.pillar), or takes away the post it hits; refused
## within a cell of the player's own cell (it would stand through the player).
class_name Tools
extends Node

const AUGER := preload("res://terrain/auger.tscn")
## How far past a dump's repose radius the player is moved, in m.
const PILE_MARGIN := 0.5
## Feet this far under the collider count as buried, in m; they are stood STAND over it.
const BURIED := 0.1
const STAND := 0.05
## A hand holding less than this after a dump, in m³, is empty.
const EMPTY := 1e-3

@export var terrain: Terrain
@export var player: Player
## The shovel's HUD line.
@export var hud: Label
## The ring shown at the shovel's aim.
@export var patch: ShovelPatch

## Tamps made, for the driver.
var tamps := 0
## Pillars placed less those taken away, for the drivers.
var pillars := 0
## A pillar's counter landing (its signed voxel count; NAN until it lands, _process consumes it).
var _pillar_result := NAN
## The placed auger, null while there is none.
var auger: Auger
## m³ of loose dirt the shovel holds (a scoop's counter, solid ground times the swell); 0 when empty.
var held := 0.0
## Scoops and dumps made (dispatched to the box), and times the player was stood on risen ground, for the driver.
var scoops := 0
var dumps := 0
var lifts := 0
## Whether a scoop's counter is in flight, its landing's m³ (-1 until it lands; _process consumes it) and
## whether the scoop was refused (a fifth gap).
var _scoop_pending := false
var _scoop_result := -1.0
var _scoop_refused := false
## The same for a dump: what the box placed.
var _dump_pending := false
var _dump_result := -1.0
## T's press: down, whether a scoop fired during it, and the last scoop's time (ms).
var _t_down := false
var _t_scooped := false
var _t_scoop_at := 0
## The floor of the wall scoops' ball, in m of height (level_floor); INF before the first.
var _floor := INF


func _ready() -> void:
	player.landed.connect(_on_landed)


## A tamp under the feet for a landing at speed (m/s, downward) from tamp_land_speed up, in the box.
func _on_landed(speed: float) -> void:
	var t := terrain.tool_params
	if speed < t.tamp_land_speed or terrain.sim.stalled():
		return
	var at := terrain.station.to_local(player.global_position)
	if terrain.box.tamp(foot_point(at, terrain.station.global_basis.inverse() * player.up_direction), t.foot_radius, t.tamp_step, terrain.materials.swell_factor[0]):
		tamps += 1
		terrain.touch(player_cell(), t.foot_radius + 1, false)


## The feet: 1 m under the player's origin p along its up, both station-local.
static func foot_point(p: Vector3, up: Vector3) -> Vector3:
	return p - up.normalized()


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
	if key.keycode == KEY_P:
		var hit := shovel_hit()
		if hit.is_empty():
			print("Nowhere to stand a pillar")
		elif not terrain.sim.stalled():
			# A quarter metre into what the crosshair hit: a drawn post's face lies on its cell's edge.
			pillar(hit.surface - hit.normal * 0.25)
		return
	if key.keycode == KEY_Y:
		if held <= 0.0:
			print("The shovel is empty")
		elif not _scoop_pending and not _dump_pending and not terrain.sim.stalled():
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
	auger = AUGER.instantiate()
	auger.setup(terrain, c, side, Cyl.height_of(surface_point(c), p.radius))
	terrain.station.add_child(auger)
	terrain.set_obstacle(c, t.bore_radius)
	return auger


## Takes the placed auger away; its hole stays and opens to the loose dirt around it.
func pickup() -> void:
	terrain.set_obstacle(TerrainSim.NO_CELL, -1)
	auger.queue_free()
	auger = null


## The shovel's aim: the crosshair's hit on the colliders (the player's body excluded) within shovel_reach of
## the player, as station-local `position` and `normal`, a wall hit lifted onto the level floor (the header,
## `level` true), and the hit itself as `surface`; empty when there is none.
func shovel_hit() -> Dictionary:
	var hit := DebugEdit.look_hit(get_viewport(), [player.get_rid()])
	if hit.is_empty():
		return {}
	var R := terrain.params.radius
	var at := terrain.station.to_local(player.global_position)
	var up := terrain.station.global_basis.inverse() * player.up_direction
	var q := terrain.station.to_local(hit.position)
	var surface := q
	var n: Vector3 = terrain.station.global_basis.inverse() * hit.normal
	var feet_h := Cyl.height_of(foot_point(at, up), R)
	var h := Cyl.height_of(q, R)
	var level := (absf(n.dot(up)) < 0.75 and h >= feet_h - 1.0) or (h >= feet_h + 0.25 and h < feet_h + 2.25)
	# The floor this hit's ball would take; scoop keeps it (the ring's aim each frame must not, or a look at
	# a wall from up a slope sets the floor a step down keeps).
	var fl := level_floor(_floor, feet_h)
	if level:
		q = Cyl.position(Cyl.theta_of(q), q.z, fl + terrain.tool_params.scoop_ball, R)
	if q.distance_to(at) > terrain.tool_params.shovel_reach:
		return {}
	return {"position": q, "normal": n, "level": level, "surface": surface, "floor": fl}


## The floor of a wall scoop's ball, in m of height: `prev` (the last one's) while the feet at feet_h stand within
## half a metre under it or a metre over it (the tunnel's own floor, a lump on it), else half a metre under the
## feet (a new tunnel: its first bite steps down half a metre, so a 3 m pit under the free height keeps a roof).
static func level_floor(prev: float, feet_h: float) -> float:
	return prev if feet_h >= prev - 0.5 and feet_h < prev + 1.0 else feet_h - 0.5


## The station-local point of cell c's centre on the collider (Terrain.ground_point: the patch, or a chunk's
## mesh; the macro surface where neither covers it). The probe starts at the macro height: the patch projects
## along its own up, so a probe on the hull lands columns away from a tall cell's centre (3.6 m at 1500 m,
## six cells from the patch's middle).
func surface_point(c: Vector2i) -> Vector3:
	var p := terrain.params
	var theta := (c.x + 0.5) * p.dtheta()
	var z := -p.length / 2.0 + c.y + 0.5
	var probe := Cyl.position(theta, z, terrain.height_at(theta, z), p.radius)
	return terrain.ground_point(probe, 0.0)


## Scoops the ball at station-local `aim`, or at the crosshair's hit within shovel_reach when none is given;
## its counter lands in _scooped. A line printed when there is no aim or the box refuses.
func scoop(aim := Vector3.INF) -> void:
	var hit := {} if aim.is_finite() else shovel_hit()
	var p: Vector3 = aim if aim.is_finite() else hit.get("position", Vector3.INF)
	if p.is_finite() and terrain.box.scoop(p, terrain.tool_params.scoop_ball, terrain.materials.swell_factor, _scooped):
		if hit.get("level", false):
			_floor = hit.floor
		_scoop_pending = true
		scoops += 1
		terrain.touch(_cell_of(p), ceili(terrain.tool_params.scoop_ball) + 1)
	else:
		print("Nothing to scoop there (the aim %s)" % p)


## Dumps what the shovel holds as loose dirt into the ball at `aim` (as scoop), and moves the player clear of
## the pile (_clear_of); what the ball could not take stays in the hand (_placed). A line printed, nothing
## dumped, when there is no aim or the box refuses.
func dump(aim := Vector3.INF) -> void:
	var p := _aim(aim)
	if p.is_finite() and terrain.box.dump(p, terrain.tool_params.scoop_ball, held, _placed):
		_dump_pending = true
		var c := _cell_of(p)
		_clear_of(c, held)
		terrain.touch(c, ceili(terrain.tool_params.scoop_ball) + 1)
	else:
		print("Nowhere to dump the dirt")


## Stands a pillar on the floor at station-local `at` up to the roof over it, or takes away the one there
## (VoxelBox.pillar, reaching the free height and a metre); its counter lands in _pillared. A line printed,
## nothing dispatched, within a cell of the player's cell or where the box refuses.
func pillar(at: Vector3) -> void:
	var p := terrain.params
	var c := _cell_of(at)
	var me := player_cell()
	@warning_ignore("integer_division")
	var dx := posmod(c.x - me.x + p.n_theta() / 2, p.n_theta()) - p.n_theta() / 2
	if maxi(absi(dx), absi(c.y - me.y)) <= 1:
		print("Too close to stand a pillar")
	elif terrain.box.pillar(at, terrain.materials.roof_span_dry[0] + 1.0, _pillared):
		terrain.touch(c, 1)
	else:
		print("Nowhere to stand a pillar")


## The drivers' P aimed at a cell: the floor under its centre a ray down from over the player's head meets (a
## tunnel's floor under its roof), else that ray's start (inside a post, or inside the ground).
func place_pillar(c: Vector2i) -> void:
	var p := terrain.params
	var me := terrain.station.to_local(player.global_position)
	var probe := Cyl.position((c.x + 0.5) * p.dtheta(), -p.length / 2.0 + c.y + 0.5, Cyl.height_of(me, p.radius) + 0.9, p.radius)
	var ground := terrain.ground_below(probe, 3.0)
	pillar(ground if ground.is_finite() else probe)


## A pillar's voxel span from the hit at hit_h m of height: the voxel holding the hit to the voxel `reach` m
## over it, at most 7 (the op's column is a brick tall, the take-away looking as far under the hit).
static func pillar_range(hit_h: float, reach: float) -> Vector2i:
	return Vector2i(floori(hit_h), floori(hit_h) + mini(floori(reach), VoxelBox.BRICK / 2 - 1))


## The drivers' scoop and dump aimed at a cell: its centre on the collider.
func scoop_cell(c: Vector2i) -> void:
	scoop(surface_point(c))


func dump_cell(c: Vector2i) -> void:
	dump(surface_point(c))


func _aim(aim: Vector3) -> Vector3:
	if aim.is_finite():
		return aim
	return shovel_hit().get("position", Vector3.INF)


func _cell_of(p: Vector3) -> Vector2i:
	return terrain.params.cell_of(Cyl.theta_of(p), p.z)


## A scoop's counter landing, inside the readback flush: stores only (_process takes it up).
func _scooped(volume: float, refused: bool) -> void:
	_scoop_result = volume
	_scoop_refused = refused


## A pillar's counter landing: stores only.
func _pillared(count: float, _flag: bool) -> void:
	_pillar_result = count


## A dump's counter landing: what the box placed.
func _placed(volume: float, _flag: bool) -> void:
	_dump_result = volume


## Takes up a landed scoop (what it took is held, or a scoop that found only rock or a full column says so),
## a landed dump (what was placed leaves the hand) and a landed pillar (its line printed, counted), shows the
## aim's ring, then scoops while T is held: at once on the press, then every scoop_interval once the last scoop
## has landed. A refused scoop, a scoop that
## found rock, or the viewer leaving the player ends the press's scooping, so a hold on the sky or on rock does
## not print every interval.
func _process(_delta: float) -> void:
	if _scoop_result >= 0.0:
		_scoop_pending = false
		if _scoop_refused:
			print("No room for a fifth tunnel in this ground")
			_t_down = false
		elif _scoop_result <= 1e-6:
			print("Nothing to scoop here")
			_t_down = false
		else:
			held += _scoop_result
		_scoop_result = -1.0
		_show_held()
	if _dump_result >= 0.0:
		_dump_pending = false
		if _dump_result > 0.0:
			dumps += 1
		held = maxf(held - _dump_result, 0.0)
		if held < EMPTY:
			held = 0.0
		_dump_result = -1.0
		_show_held()
	if not is_nan(_pillar_result):
		var n := roundi(_pillar_result)
		if n > 0:
			print("A pillar stands")
		elif n < 0:
			print("The pillar taken away")
		else:
			print("Nothing to hold up there")
		pillars += signi(n)
		_pillar_result = NAN
	if terrain.viewer != player:
		_t_down = false
		patch.visible = false
	else:
		var hit := shovel_hit()
		if hit.is_empty():
			patch.visible = false
		else:
			patch.show_at(hit.position, hit.normal, terrain.station, terrain.tool_params.scoop_ball)
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
	if not terrain.covered(feet):
		return
	var ground := terrain.patch
	# Over a chunk drawn by its mesh the patch's heights are the roof's until the bake after the mesh lands
	# (NaN then), so the ray decides there from the landing on.
	var q := ground.surface_point(feet, 0.0) if ground.covers(feet) and not terrain.box.covers(feet) else Vector3.INF
	var under: float
	if q.is_finite():
		under = (q - feet).dot(ground.transform.basis.y)
	else:
		# Over a chunk drawn by its mesh: the ground a ray from the head down to under the feet meets, so a
		# tunnel's roof never counts.
		var hit := terrain.ground_below(terrain.station.to_local(player.global_position + up * 0.9), 2.1)
		if not hit.is_finite():
			return
		under = (hit - feet).dot(terrain.station.global_basis.inverse() * up)
	if under > BURIED:
		player.global_position += up * (under + STAND)
		lifts += 1
		print("Stood on the ground risen %.2f m over the feet" % under)


## The radius in m of the cone a pile of v m³ settles into at repose_deg: v = π r² (r tan repose) / 3.
static func pile_radius(v: float, repose_deg: float) -> float:
	return pow(3.0 * v / (PI * tan(deg_to_rad(repose_deg))), 1.0 / 3.0)


## The volume in m³ of the ball of radius m at grid point centre (theta index, z index, height) by the annuli
## of its voxels at VoxelBox.SUB sub-samples per axis: what box_edit.glsl's coverage adds up to for a ball in
## the open (the drivers' expectations).
static func ball_volume(radius: float, centre: Vector3, R: float, dtheta: float) -> float:
	var n := VoxelBox.SUB
	var w := (R - centre.z) * dtheta
	var v := 0.0
	for k in range(floori(centre.z - radius), floori(centre.z + radius) + 1):
		var vol := VoxelColumn.voxel_volume(k, R, dtheta)
		for j in range(floori(centre.y - radius), floori(centre.y + radius) + 1):
			for i in range(floori(centre.x - radius / w), floori(centre.x + radius / w) + 1):
				var inside := 0
				for c in n:
					var h := k + (c + 0.5) / n
					var dh := h - centre.z
					for a in n:
						var dx := (i + (a + 0.5) / n - centre.x) * (R - h) * dtheta
						for b in n:
							var dz := j + (b + 0.5) / n - centre.y
							inside += int(dx * dx + dz * dz + dh * dh <= radius * radius)
				v += inside / float(n * n * n) * vol
	return v


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
	# Under a roof (the patch has no height at the dump point: a chunk's mesh is the ground) the pile cannot
	# spread as a cone: it runs along the tunnel as a ridge at repose over a floor about a ball wide.
	var repose := terrain.materials.repose_dry[0]
	var at := Cyl.position(centre.x, centre.y, Cyl.height_of(me, p.radius), p.radius)
	var confined := terrain.patch.covers(at) and not terrain.patch.surface_point(at, 0.0).is_finite()
	var keep := (sqrt(v / (terrain.tool_params.scoop_ball * tan(deg_to_rad(repose)))) if confined else pile_radius(v, repose)) + PILE_MARGIN
	if off.length() <= terrain.tool_params.scoop_ball + 0.5 or off.length() >= keep:
		return
	off = off.normalized() * keep
	var to := Cyl.position(centre.x + off.x / r, centre.y + off.y, Cyl.height_of(me, p.radius), p.radius)
	# The ground under that spot, from a metre over the player's height down 3 m: a tunnel's floor, or the
	# open ground; none (a wall, a drop) keeps the player put.
	var up_to := Vector3(-sin(Cyl.theta_of(to)), cos(Cyl.theta_of(to)), 0.0)
	var ground := terrain.ground_below(to + up_to, 3.0)
	if not ground.is_finite():
		return
	player.global_position = terrain.station.global_transform * (ground + up_to * (1.0 + STAND))


func _show_held() -> void:
	hud.text = "Shovel: %.2f m³" % held if held > 0.0 else ""


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


