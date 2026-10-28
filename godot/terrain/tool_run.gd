## Windowed check of the slice 3 tools (the terrain slice 3 plan, decision 13), grown phase by phase.
## Instantiates main.tscn and, once the first collider patch is live, runs each phase at its site, a cell
## spawn_cell + (0, 40 k) on the spawn's column, every stamp through Terrain.stamp_tool with tool_params
## values, reading the window synchronously three frames after each stamp. Phases:
## stamps (k = 1, S1; Task 2):
## 1. a 1.5 m³ deposit of spoil_radius: the loose volume over the box of 6 around S1 is 1.5 m³, the disc
##    fresh (compaction 0) and masked;
## 2. three pushes of radius 2 along +z: the loose volume over the box holds and its centre moves forward;
## 3. four tamps of radius 2: after three the loose cells' compaction is 0.75, after the fourth they are folded
##    (loose, compaction and material 0) and the surface gained the disc's loose volume over the swell;
## 4. a 0.5 m³ spill at S1 + (0, 10): the window's sheet water plus its pore water grew by 0.5 m³;
## 5. 30 bore ticks at S1 + (0, 20), 10 a second: the counter's landings add up to the annulus between the
##    surfaces before and after, no tick wet, the disc 1 m down, its clay under the surface, its material by
##    the strata;
## 6. pack_tiles of six resident tiles, S1's first: two lists, the second reusing slot 0; every blob lands,
##    and S1's tile holds the window's loose.
## Then prints the GPU times of the edit (stamp) and pack lists against their budget, reported and not
## asserted (Vulkan only: Metal reports zeros, shown as n/a). Prints PASS and exits 0 when every check holds,
## else FAIL and 1. persist_edits is off, so nothing is saved.
## After editing a .glsl run `godot --headless --path . --import` first (the suite does it).
## Run: godot --rendering-driver vulkan --path . res://terrain/tool_run.tscn
extends Node

const Smoke := preload("res://terrain/smoke_run.gd")
## The GPU budget of the edit and pack lists in ms.
const BUDGET := {"edit": 0.5, "pack": 0.5}

var _station: Station
var _terrain: Terrain
var _started := false
var _ok := true
## Every timed GPU list in order: {name, ms}.
var _timed: Array[Dictionary] = []
## The bore's counter landings: m³ summed, how many landed, whether any tick pumped.
var _bored := 0.0
var _bore_landed := 0
var _bore_wet := false


func _ready() -> void:
	var main: Node = load("res://main.tscn").instantiate()
	_station = main.get_node("Station")
	_terrain = _station.get_node("Terrain")
	_terrain.persist_edits = false
	main.get_node("Panel/Box/Timing").timed.connect(func(pass_name: String, ms: float) -> void:
		_timed.append({"name": pass_name, "ms": ms}))
	_terrain.collider_live.connect(_route, CONNECT_ONE_SHOT)
	add_child(main)
	for i in 1200:
		if _started:
			return
		await get_tree().process_frame
	push_error("The first collider patch did not go live in 1200 frames.")
	get_tree().quit(1)


## The route is scripted: a stray click must not capture the mouse, nor mouse movement turn the player.
func _input(event: InputEvent) -> void:
	if event is InputEventMouse:
		get_viewport().set_input_as_handled()


func _route() -> void:
	_started = true
	# collider_live fires inside the patch's readback landing, where no GPU work may be issued.
	await get_tree().process_frame
	var p := _terrain.params
	var spawn := p.cell_of(_terrain.maps.spawn.x, _terrain.maps.spawn.y)
	await _stamps(spawn + Vector2i(0, 40))
	# Let the last timestamps arrive.
	await _frames(6)
	_summary()
	print("PASS" if _ok else "FAIL")
	get_tree().quit(0 if _ok else 1)


## Phase stamps at s1: deposit, push, tamp, spill, bore and the pack's slot reuse (see the header).
func _stamps(s1: Vector2i) -> void:
	var t := _terrain.tool_params
	var swell := _terrain.materials.swell_factor[0]
	var box := _box(s1, 6)

	_stamp(_op(s1, t.spoil_radius, EditLayer.MODE_DEPOSIT, 1.5))
	await _frames(3)
	var loose := _read("loose")
	var surface := _read("surface")
	var compaction := _read("compaction")
	var mask := _read("edit_mask")
	var deposited := _vol(loose, surface, box)
	var fresh := true
	for c in _disc(s1, t.spoil_radius):
		fresh = fresh and _b(compaction, c) == 0 and _b(mask, c) == 255
	print("deposit: %.6f m³ loose over the box for 1.5 m³ (%+.4f %%), disc fresh and masked: %s" % [
			deposited, (deposited / 1.5 - 1.0) * 100.0, fresh])
	_report("deposit conserves", absf(deposited - 1.5) <= 1.5e-3 and fresh)

	var row0 := _mean_row(loose, surface, box, s1)
	for i in 3:
		_stamp(_op(s1, 2, EditLayer.MODE_PUSH, t.push_share, Vector2i(0, 1), t.push_max))
		await _frames(3)
	loose = _read("loose")
	surface = _read("surface")
	var pushed := _vol(loose, surface, box)
	var row1 := _mean_row(loose, surface, box, s1)
	print("push: %.6f m³ loose over the box, was %.6f (%+.3f ppm); mean row %+.4f -> %+.4f cells" % [
			pushed, deposited, (pushed / deposited - 1.0) * 1e6, row0, row1])
	_report("push moves forward, conserves", absf(pushed - deposited) <= 1e-4 * deposited and row1 - row0 >= 0.05)

	var tamp_disc := _disc(s1, 2)
	for i in 3:
		_stamp(_op(s1, 2, EditLayer.MODE_TAMP, t.tamp_step, Vector2i.ZERO, swell))
		await _frames(3)
	loose = _read("loose")
	surface = _read("surface")
	compaction = _read("compaction")
	var tamped: Array[Vector2i] = []
	var bytes: Array[int] = []
	for c in tamp_disc:
		if _f(loose, c) > 1e-3:
			tamped.append(c)
			bytes.append(_b(compaction, c))
	var at_three := not tamped.is_empty() and bytes.all(func(k: int) -> bool: return absi(k - 191) <= 1)
	var disc_loose := _vol(loose, surface, tamp_disc)
	_stamp(_op(s1, 2, EditLayer.MODE_TAMP, t.tamp_step, Vector2i.ZERO, swell))
	await _frames(3)
	var loose4 := _read("loose")
	var surface4 := _read("surface")
	var compaction4 := _read("compaction")
	var material4 := _read("material")
	var folded := true
	for c in tamped:
		folded = folded and _f(loose4, c) == 0.0 and _b(compaction4, c) == 0 and _b(material4, c) == 0
	var gain := 0.0
	for c in tamp_disc:
		gain += (_f(surface4, c) - _f(surface, c)) * _area(_f(surface, c))
	var want := disc_loose / swell
	print("tamp: %d loose cells, compaction bytes after three %s; after four folded: %s, solid gained %.6f m³ for %.6f m³ loose / %.2f = %.6f (%+.4f %%)" % [
			tamped.size(), bytes, folded, gain, disc_loose, swell, want, (gain / want - 1.0) * 100.0])
	_report("tamp folds with the swell", at_three and folded and absf(gain - want) <= 1e-3 * want)

	var sat0 := _read("saturation")
	var water0 := _sum(_read("water_depth"), _read("surface"))
	_stamp(_op(s1 + Vector2i(0, 10), 2, EditLayer.MODE_SPILL, 0.5))
	await _frames(3)
	surface = _read("surface")
	var sheet := _sum(_read("water_depth"), surface) - water0
	var pore := _pore(sat0, _read("saturation"), _read("material"), _read("loose"), surface)
	print("spill: sheet %+.6f m³, pore %+.6f m³ for 0.5 m³ (%+.4f %%)" % [sheet, pore, ((sheet + pore) / 0.5 - 1.0) * 100.0])
	_report("spill conserves", absf(sheet + pore - 0.5) <= 0.02 * 0.5)

	var b := s1 + Vector2i(0, 20)
	var bore_box := _box(b, 3)
	var s0 := _read("surface")
	for i in 30:
		var op := _op(b, t.bore_radius, EditLayer.MODE_BORE, t.bore_step, Vector2i.ZERO, t.pump_rate / t.bore_rate)
		op.counted = _on_bored
		_stamp(op)
		await get_tree().create_timer(1.0 / t.bore_rate).timeout
	await _frames(5)
	var s30 := _read("surface")
	var bedrock := _read("bedrock_top")
	var clay_bottom := _read("clay_bottom")
	var clay_top := _read("clay_top")
	var material := _read("material")
	var removed := _removed(s0, s30, bore_box)
	var drops: Array[String] = []
	var dropped := true
	var strata := true
	for c in _disc(b, t.bore_radius):
		var s := _f(s30, c)
		var top := 2 if _f(bedrock, c) >= s - 0.01 else (1 if _f(clay_top, c) >= s - 0.01 else 0)
		drops.append("%.5f" % (_f(s0, c) - s))
		dropped = dropped and absf(_f(s0, c) - s - 1.0) <= 1e-3
		strata = strata and _f(clay_top, c) <= s and _f(clay_bottom, c) <= s and _b(material, c) == top
	print("bore: %d of 30 ticks landed, counter %.6f m³, annulus %.6f m³ (%+.4f %%), wet %s; drops %s m, strata and material by the rule: %s" % [
			_bore_landed, _bored, removed, (_bored / removed - 1.0) * 100.0, _bore_wet, drops, strata])
	_report("bore counts what it cut", _bore_landed == 30 and absf(_bored - removed) <= 1e-3 * removed and not _bore_wet
			and dropped and strata)

	var window := _terrain.window
	var tile := window.tile_of_cell(s1.x, s1.y)
	var tiles: Array[Vector2i] = [tile]
	for r in window.resident_tiles():
		if tiles.size() < 6 and r != tile:
			tiles.append(r)
	for r in tiles:
		window.edits.blobs.erase(r)
	window.edits.pack_tiles(window, tiles)
	await _frames(4)
	loose = _read("loose")
	# S1 itself was folded by the tamp: the cell of S1's tile with the most loose in the box stands for it.
	var probe := s1
	for c in box:
		if window.tile_of_cell(c.x, c.y) == tile and _f(loose, c) > _f(loose, probe):
			probe = c
	var landed := tiles.all(func(x: Vector2i) -> bool: return window.edits.blobs.has(x))
	var same := false
	if landed:
		var o := EditLayer.cell_offset(posmod(probe.x, TerrainWindow.TILE), posmod(probe.y, TerrainWindow.TILE))
		var blob: PackedByteArray = window.edits.blobs[tile]
		same = _f(loose, probe) > 0.0 and blob.decode_u32(o + 24) == loose.decode_u32(4 * _texel(probe)) \
				and blob.decode_u32(o + 20) >> 24 == 255
	print("pack: %d tiles %s, all landed: %s; %s in %s: %.6f m loose, blob matches the window and is masked: %s" % [
			tiles.size(), tiles, landed, probe, tile, _f(loose, probe), same])
	_report("pack slots reused across lists", landed and same)


## A bore tick's counter landing, inside the readback flush: stores only.
func _on_bored(volume: float, wet: bool) -> void:
	_bored += volume
	_bore_landed += 1
	_bore_wet = _bore_wet or wet


## An Op with these fields that does not pack (the tools leave packing to the settle pack).
func _op(cell: Vector2i, radius: int, mode: int, amount: float, dir := Vector2i.ZERO, limit := 0.0) -> EditLayer.Op:
	var op := EditLayer.Op.new()
	op.cell = cell
	op.radius = radius
	op.mode = mode
	op.amount = amount
	op.dir = dir
	op.limit = limit
	op.pack = false
	return op


func _stamp(op: EditLayer.Op) -> void:
	if not _terrain.stamp_tool(op):
		print("stamp refused: mode %d at %s" % [op.mode, op.cell])
		_ok = false


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


## A window field's texture, read synchronously.
func _read(field: String) -> PackedByteArray:
	var out: Array[PackedByteArray] = []
	var rid := _terrain.window.texture_rid(field)
	RenderingServer.call_on_render_thread(func() -> void:
		out.append(RenderingServer.get_rendering_device().texture_get_data(rid, 0)))
	return out[0]


## The texel of cell c: tile t sits in slot t mod slots, so cell c is texel c mod size.
func _texel(c: Vector2i) -> int:
	var n := _terrain.window.size
	return posmod(c.y, n) * n + posmod(c.x, n)


## A float field's value at cell c.
func _f(bytes: PackedByteArray, c: Vector2i) -> float:
	return bytes.decode_float(4 * _texel(c))


## A byte field's value (0..255) at cell c.
func _b(bytes: PackedByteArray, c: Vector2i) -> int:
	return bytes[_texel(c)]


## The cells within half of center along each axis, theta wrapped, rows clamped to the station.
func _box(center: Vector2i, half: int) -> Array[Vector2i]:
	var p := _terrain.params
	var out: Array[Vector2i] = []
	for y in range(maxi(center.y - half, 0), mini(center.y + half, p.n_z() - 1) + 1):
		for x in range(center.x - half, center.x + half + 1):
			out.append(Vector2i(posmod(x, p.n_theta()), y))
	return out


## The cells of the disc of radius around center, as edit.glsl takes them.
func _disc(center: Vector2i, radius: int) -> Array[Vector2i]:
	var half := _terrain.params.n_theta() >> 1
	var out: Array[Vector2i] = []
	for c in _box(center, radius):
		var dx := posmod(c.x - center.x + half, 2 * half) - half
		if dx * dx + (c.y - center.y) ** 2 <= radius * radius:
			out.append(c)
	return out


## The area in m² of a cell whose surface is s.
func _area(s: float) -> float:
	return (_terrain.params.radius - s) * _terrain.params.dtheta()


## Σ v · (R − s) · Δθ over cells: the volume of a float field (loose or water_depth), in float64.
func _vol(field: PackedByteArray, surface: PackedByteArray, cells: Array[Vector2i]) -> float:
	var v := 0.0
	for c in cells:
		v += _f(field, c) * _area(_f(surface, c))
	return v


## _vol over every texel of the window.
func _sum(field: PackedByteArray, surface: PackedByteArray) -> float:
	var f := field.to_float32_array()
	var s := surface.to_float32_array()
	var v := 0.0
	for k in f.size():
		if f[k] != 0.0:
			v += f[k] * _area(s[k])
	return v


## The pore water gained between two saturation reads, over every texel: Σ (sat1 − sat0) / 255 · capacity ·
## (R − s) · Δθ, the capacity porosity · soak_column of the cell's top material, dirt where it holds loose.
func _pore(sat0: PackedByteArray, sat1: PackedByteArray, material: PackedByteArray, loose: PackedByteArray,
		surface: PackedByteArray) -> float:
	var porosity := _terrain.materials.porosity
	var column := _terrain.tool_params.soak_column
	var l := loose.to_float32_array()
	var s := surface.to_float32_array()
	var v := 0.0
	for k in sat1.size():
		if sat1[k] != sat0[k]:
			var m := 0 if l[k] > 0.01 else material[k]
			v += (sat1[k] - sat0[k]) / 255.0 * porosity[m] * column * _area(s[k])
	return v


## The volume between surfaces s0 and s1 over cells, each cell the annulus Σ 0.5 · Δθ · (s0 − s1) ·
## (2 · (R − s0) + (s0 − s1)), the bore counter's product form.
func _removed(s0: PackedByteArray, s1: PackedByteArray, cells: Array[Vector2i]) -> float:
	var p := _terrain.params
	var v := 0.0
	for c in cells:
		var cut := _f(s0, c) - _f(s1, c)
		v += 0.5 * p.dtheta() * cut * (2.0 * (p.radius - _f(s0, c)) + cut)
	return v


## The loose-volume-weighted mean row of cells, from row origin.y.
func _mean_row(loose: PackedByteArray, surface: PackedByteArray, cells: Array[Vector2i], origin: Vector2i) -> float:
	var v := 0.0
	var moment := 0.0
	for c in cells:
		var dv := _f(loose, c) * _area(_f(surface, c))
		v += dv
		moment += dv * (c.y - origin.y)
	return moment / v


func _report(what: String, ok: bool) -> void:
	print("%s: %s" % [what, "ok" if ok else "FAILED"])
	_ok = _ok and ok


func _expect(ok: bool, what: String) -> void:
	if not ok:
		print("%s: FAILED" % what)
		_ok = false


## The timing summary, reported against the budgets and never asserted.
func _summary() -> void:
	print("---- tool run ----")
	print("machine: %s, %s; driver %s" % [OS.get_processor_name(), RenderingServer.get_video_adapter_name(),
			RenderingServer.get_current_rendering_driver_name()])
	print("GPU lists in ms (Vulkan only):")
	for pass_name: String in BUDGET:
		var ms: Array[float] = []
		for t in _timed:
			if t.name == pass_name:
				ms.append(t.ms)
		print("  %-5s %s" % [pass_name, Smoke._stat(ms, BUDGET[pass_name])])
