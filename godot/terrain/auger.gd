## The auger (the terrain slice 3 plan, decisions 5, 6 and 11; the tunnels design): a prop standing in the
## tangent frame at its cell's centre, under Station, that bores the bore_radius disc under it bore_step a
## tick, bore_rate ticks a second, in the voxel box (VoxelBox.bore, dry: the solid's top run cut down, never
## rock), and heaps what each tick's counter readback says it cut, times the swell, as loose dirt on the spoil
## disc spoil_offset cells to its side (VoxelBox.spoil). A tick whose centre stands in water is refused by the
## box as wet: the auger then pumps through the window's bore stamp (Terrain.stamp_tool, MODE_BORE: lifts
## the water, spills it on the spoil disc) until a landing reads dry again. It stops at bore_depth or at rock,
## pauses while its discs are out of the box or the window and resumes when they return, and is never saved.
## Tools places and picks it up.
class_name Auger
extends Node3D

## Emitted once, with "depth" or "rock", when a landed tick stops the bore.
signal stopped(reason: String)

## m: 300 steps of 1/30 sum to 10 - 2e-14, so depth is compared to bore_depth with this much slack.
const DEPTH_EPS := 1e-6

var terrain: Terrain
## The bore disc's centre cell.
var cell: Vector2i
## The axis step from the auger to its spoil disc.
var side: Vector2i
## "pump" when the last landed tick was wet (the window's bore stamp pumps), "bore" when it was dry (the box
## cuts) (decision 5).
var mode := "bore"
## The ground the auger stood on, m over the hull.
var ground := 0.0
## m bored: the steps of the ticks issued while the mode read bore.
var depth := 0.0
var running := true
## "", or why the bore stopped ("depth", "rock"), set by a landing.
var stop_reason := ""
## m³ the counter reported for dry ticks.
var removed := 0.0
## m³ of loose placed on the spoil disc.
var deposited := 0.0
## m³ of water placed on the spoil disc.
var spilled := 0.0
## Ticks stamped, and ticks refused while the bore or spoil tiles were out of the window.
var ticks := 0
var refused := 0

## m³ landed from the counter and not yet deposited, and whether the last landing was wet.
var _pending := 0.0
var _pending_wet := false
## Ticks in ms before which no bore tick is made.
var _next_tick := 0


## Stands the auger on the ground (ground_h m over the hull) at the centre of cell c of t's world, its spoil
## side s, and lets its first tick go at once.
func setup(t: Terrain, c: Vector2i, s: Vector2i, ground_h: float) -> void:
	terrain = t
	cell = c
	side = s
	var p := t.params
	var theta := (c.x + 0.5) * p.dtheta()
	var z := -p.length / 2.0 + c.y + 0.5
	transform = ColliderPatch.tangent_frame(theta, z, p.radius)
	transform.origin = Cyl.position(theta, z, ground_h, p.radius)
	ground = ground_h
	_next_tick = Time.get_ticks_msec()


## The station-local point of a cell's centre at height h over the hull.
func _point(c: Vector2i, h: float) -> Vector3:
	var p := terrain.params
	return Cyl.position((c.x + 0.5) * p.dtheta(), -p.length / 2.0 + c.y + 0.5, h, p.radius)


## The spoil disc's centre cell.
func spoil_cell() -> Vector2i:
	return spoil_cell_of(cell, side, terrain.tool_params.spoil_offset, terrain.params.n_theta())


## The cell offset cells from cell along side, theta wrapped.
static func spoil_cell_of(cell: Vector2i, side: Vector2i, offset: int, n_theta: int) -> Vector2i:
	return Vector2i(posmod(cell.x + side.x * offset, n_theta), cell.y + side.y * offset)


## Why a landed tick stops the bore, "" when it goes on: a wet tick (a pump) never stops it; a dry one that
## cut nothing found every cell at bedrock_top ("rock"); else it stops once depth reaches bore_depth.
static func stop_reason_for(depth: float, bore_depth: float, volume: float, wet: bool) -> String:
	if wet:
		return ""
	if volume <= 0.0:
		return "rock"
	return "depth" if depth >= bore_depth - DEPTH_EPS else ""


## Deposits what has landed, stops on a landing's word, then makes the bore tick that is due (refused, and
## counted as such, while its tiles are out of the window). Neither deposits nor ticks while the renderer is
## stalled; a pause of _process skips the ticks it missed rather than bunching them.
func _process(_delta: float) -> void:
	var t := terrain.tool_params
	var now := Time.get_ticks_msec()
	# No GPU chatter at a stalled renderer (ruling 14): a deposit and a tick are both timed edit lists.
	var stalled := terrain.sim.stalled()
	if _pending > 0.0 and not stalled:
		var amount := _pending if _pending_wet else _pending * terrain.materials.swell_factor[0]
		if _pending_wet:
			if terrain.stamp_tool(_op(spoil_cell(), t.spoil_radius, EditLayer.MODE_SPILL, amount)):
				spilled += amount
				_pending = 0.0
		elif terrain.box.spoil(_point(spoil_cell(), ground), t.spoil_radius, amount, _spoiled):
			_pending = 0.0
			terrain.touch(spoil_cell(), t.spoil_radius + 1)
	if running and stop_reason != "":
		running = false
		print("Auger stopped: " + stop_reason)
		stopped.emit(stop_reason)
	if stalled:
		_next_tick = now
		return
	if not running or now < _next_tick or (mode == "bore" and depth >= t.bore_depth - DEPTH_EPS):
		return
	_next_tick = maxi(_next_tick + roundi(1000.0 / t.bore_rate), now)
	var ok := false
	if mode == "bore":
		ok = terrain.can_stamp(spoil_cell(), t.spoil_radius) and terrain.box.bore(_point(cell, ground - depth), t.bore_radius, t.bore_step, _counted)
	else:
		var op := _op(cell, t.bore_radius, EditLayer.MODE_BORE, t.bore_step)
		op.limit = t.pump_rate / t.bore_rate
		op.counted = _counted
		ok = terrain.can_stamp(spoil_cell(), t.spoil_radius) and terrain.stamp_tool(op)
	if ok:
		ticks += 1
		if mode == "bore":
			depth += t.bore_step
			terrain.touch(cell, t.bore_radius + 1)
	else:
		refused += 1


## A tick's counter landing, inside the readback flush: stores only. A method, so the callable goes invalid
## once the auger is freed and the landing for a picked-up auger is dropped. A dry tick the box refused as
## wet (nothing cut) turns the mode to pump without judging the stop; a box tick counted its step back.
func _counted(volume: float, wet: bool) -> void:
	if mode == "bore" and wet:
		depth -= terrain.tool_params.bore_step
		mode = "pump"
		return
	_pending += volume
	_pending_wet = wet
	mode = "pump" if wet else "bore"
	if not wet:
		removed += volume
	if running and stop_reason == "":
		stop_reason = stop_reason_for(depth, terrain.tool_params.bore_depth, volume, wet)


## A spoil's landing: what the box placed.
func _spoiled(volume: float, _flag: bool) -> void:
	deposited += volume


## A stamp of kind around c that leaves packing to the settle pack.
func _op(c: Vector2i, radius: int, kind: int, amount: float) -> EditLayer.Op:
	var op := EditLayer.Op.new()
	op.cell = c
	op.radius = radius
	op.mode = kind
	op.amount = amount
	op.pack = false
	return op
