## The auger (the terrain slice 3 plan, decisions 5, 6 and 11): a prop standing in the tangent frame at its
## cell's centre, under Station, that bores the bore_radius disc under it bore_step a tick, bore_rate ticks a
## second, and heaps what each tick's counter readback says it cut, times the swell, as loose dirt on the
## spoil disc spoil_offset cells to its side (or spills it there as water when the tick pumped). It stops at
## bore_depth or at rock, pauses while its bore or spoil tiles are out of the window (Terrain.can_stamp) and
## resumes when they return, and is never saved. Tools places and picks it up.
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
## "pump" when the last landed tick was wet, "bore" when it was dry (decision 5).
var mode := "bore"
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
	_next_tick = Time.get_ticks_msec()


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
## counted as such, while its tiles are out of the window).
func _process(_delta: float) -> void:
	var t := terrain.tool_params
	if _pending > 0.0:
		var amount := _pending if _pending_wet else _pending * terrain.materials.swell_factor[0]
		if terrain.stamp_tool(_op(spoil_cell(), t.spoil_radius, EditLayer.MODE_SPILL if _pending_wet else EditLayer.MODE_DEPOSIT, amount)):
			if _pending_wet:
				spilled += amount
			else:
				deposited += amount
			_pending = 0.0
	if running and stop_reason != "":
		running = false
		print("Auger stopped: " + stop_reason)
		stopped.emit(stop_reason)
	if not running or Time.get_ticks_msec() < _next_tick or (mode == "bore" and depth >= t.bore_depth - DEPTH_EPS):
		return
	_next_tick += roundi(1000.0 / t.bore_rate)
	var op := _op(cell, t.bore_radius, EditLayer.MODE_BORE, t.bore_step)
	op.limit = t.pump_rate / t.bore_rate
	op.counted = _counted
	if terrain.can_stamp(spoil_cell(), t.spoil_radius) and terrain.stamp_tool(op):
		ticks += 1
		if mode == "bore":
			depth += t.bore_step
	else:
		refused += 1


## A tick's counter landing, inside the readback flush: stores only. A method, so the callable goes invalid
## once the auger is freed and EditLayer drops a landing for a picked-up auger.
func _counted(volume: float, wet: bool) -> void:
	_pending += volume
	_pending_wet = wet
	mode = "pump" if wet else "bore"
	if not wet:
		removed += volume
	if running and stop_reason == "":
		stop_reason = stop_reason_for(depth, terrain.tool_params.bore_depth, volume, wet)


## A stamp of kind around c that leaves packing to the settle pack.
func _op(c: Vector2i, radius: int, kind: int, amount: float) -> EditLayer.Op:
	var op := EditLayer.Op.new()
	op.cell = c
	op.radius = radius
	op.mode = kind
	op.amount = amount
	op.pack = false
	return op
