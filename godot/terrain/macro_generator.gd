## Builds a world's macro maps from its WorldParams, water first: seas, regions, drainage, rivers,
## lakes and river profiles, so every water cell has a height before any land is grown; then land
## growth with cliff bands, strata, banks, pump loops and the spawn site. Each stage reads the maps
## the earlier stages wrote and writes its own. Deterministic: all randomness comes from one
## RandomNumberGenerator seeded from params.seed, and every noise field is periodic in theta.
class_name MacroGenerator
extends RefCounted

## Neighbour offsets (dx, dy); a flow_dir value d in 1..8 points to neighbour d - 1. x wraps, y does not.
const DX := [1, 1, 0, -1, -1, -1, 0, 1]
const DY := [0, 1, 1, 1, 0, -1, -1, -1]
## Length in cells of the step to each neighbour.
const STEP := [1.0, 1.4142135, 1.0, 1.4142135, 1.0, 1.4142135, 1.0, 1.4142135]
## River source weight by region: sea, flat, hill, mountain, island.
const SOURCE_WEIGHT := [0, 1, 2, 4, 1]
## Land growth rate in m per cell by region (islands grow like hills), and on river banks.
const GROWTH_RATE := [0.0, 0.4, 2.5, 8.0, 2.5]
const RIVER_RATE := 0.05
## WorldParams.bedrock_depth key by region; the sea floor uses the flat range.
const DEPTH_KEY := ["flat", "flat", "hill", "mountain", "hill"]


## Array-backed binary min-heap of cell indices keyed on height.
class Heap:
	var keys := PackedFloat32Array()
	var cells := PackedInt32Array()
	var size := 0

	func _init(capacity: int) -> void:
		keys.resize(capacity)
		cells.resize(capacity)

	func push(key: float, cell: int) -> void:
		if size == keys.size():
			keys.resize(2 * size)
			cells.resize(2 * size)
		var i := size
		size += 1
		while i > 0:
			var parent := (i - 1) >> 1
			if keys[parent] <= key:
				break
			keys[i] = keys[parent]
			cells[i] = cells[parent]
			i = parent
		keys[i] = key
		cells[i] = cell

	## Removes and returns the cell with the lowest key.
	func pop() -> int:
		var top := cells[0]
		size -= 1
		var key := keys[size]
		var cell := cells[size]
		var i := 0
		while true:
			var c := 2 * i + 1
			if c >= size:
				break
			if c + 1 < size and keys[c + 1] < keys[c]:
				c += 1
			if keys[c] >= key:
				break
			keys[i] = keys[c]
			cells[i] = cells[c]
			i = c
		keys[i] = key
		cells[i] = cell
		return top


## Generates the macro maps for params. progress, when valid, is called with (stage_name, fraction)
## before each stage and with ("done", 1.0) at the end.
func generate(params: WorldParams, progress: Callable = Callable()) -> MacroMaps:
	var rng := RandomNumberGenerator.new()
	rng.seed = params.seed
	var m := MacroMaps.new()
	var stages: Array[Callable] = [_seas, _regions, _drainage, _rivers, _lakes, _profiles, _grow, _strata, _banks, _loops, _spawn]
	for i in stages.size():
		if progress.is_valid():
			progress.call(stages[i].get_method().trim_prefix("_"), float(i) / stages.size())
		stages[i].call(m, params, rng)
	if progress.is_valid():
		progress.call("done", 1.0)
	return m


## Ring sea around sea_z with noisy shores and island_count island blobs inside it. Writes region
## (0 sea, 4 island, 1 other land), water_surface (h_sea on sea, else 0) and surface: the sea floor
## falls from the shore at sea_depth_max / (sea_width / 2) per metre to sea_depth_max, land stays h_sea.
func _seas(m: MacroMaps, p: WorldParams, rng: RandomNumberGenerator) -> void:
	var w := p.macro_w()
	var h := p.macro_h()
	var ring := _ring(p)
	var shore := _noise(rng, 1.0 / p.sea_width)
	var half_n := PackedFloat32Array()
	var half_s := PackedFloat32Array()
	for x in w:
		half_n.append(p.sea_width / 2.0 + shore.get_noise_3d(ring[x].x, ring[x].y, p.sea_z + p.sea_width / 2.0) * p.sea_edge_noise)
		half_s.append(p.sea_width / 2.0 + shore.get_noise_3d(ring[x].x, ring[x].y, p.sea_z - p.sea_width / 2.0) * p.sea_edge_noise)
	var region := PackedByteArray()
	region.resize(w * h)
	for y in h:
		var dz := _z(y, p) - p.sea_z
		for x in w:
			region[y * w + x] = 0 if absf(dz) < (half_n[x] if dz >= 0.0 else half_s[x]) else 1
	var blob := _noise(rng, 4.0 / p.sea_width)
	for _i in p.island_count:
		var c := m.cell(rng.randf() * TAU, p.sea_z + rng.randf_range(-0.2, 0.2) * p.sea_width, p)
		var r := rng.randf_range(0.06, 0.12) * p.sea_width / p.macro_cell
		var rc := ceili(r * 1.5)
		for y in range(maxi(c.y - rc, 0), mini(c.y + rc + 1, h)):
			for dx in range(-rc, rc + 1):
				var x := posmod(c.x + dx, w)
				var i := y * w + x
				if region[i] == 0 and Vector2(dx, y - c.y).length() < r * (1.0 + 0.5 * blob.get_noise_3d(ring[x].x, ring[x].y, _z(y, p))):
					region[i] = 4
	var land := PackedInt32Array()
	for i in w * h:
		if region[i] != 0:
			land.append(i)
	var near := _nearest(land, w, h)
	var depth_noise := _noise(rng, 4.0 / p.sea_width)
	var k_depth := p.sea_depth_max / (p.sea_width / 2.0)
	var surface := PackedFloat32Array()
	surface.resize(w * h)
	surface.fill(p.h_sea)
	var water := PackedFloat32Array()
	water.resize(w * h)
	for y in h:
		for x in w:
			var i := y * w + x
			if region[i] != 0:
				continue
			var d := _dist(i, near[i], w) * p.macro_cell
			var n := depth_noise.get_noise_3d(ring[x].x, ring[x].y, _z(y, p))
			surface[i] = maxf(0.0, p.h_sea - minf(p.sea_depth_max, k_depth * d * (1.0 + 0.2 * n)))
			water[i] = p.h_sea
	m.region = _r8(region, w, h)
	m.surface = _rf(surface, w, h)
	m.water_surface = _rf(water, w, h)


## Land regions 1 flat, 2 hill, 3 mountain from Voronoi cells plus low-frequency noise, biased toward
## mountains near |z| > 0.3 length and flats near the sea. Sea and islands keep their region.
func _regions(m: MacroMaps, p: WorldParams, rng: RandomNumberGenerator) -> void:
	var w := p.macro_w()
	var h := p.macro_h()
	var ring := _ring(p)
	var region := m.region.get_data()
	var cells := _noise(rng, 1.0 / p.region_scale)
	cells.noise_type = FastNoiseLite.TYPE_CELLULAR
	cells.cellular_return_type = FastNoiseLite.RETURN_CELL_VALUE
	cells.fractal_type = FastNoiseLite.FRACTAL_NONE
	cells.domain_warp_enabled = true
	cells.domain_warp_amplitude = 0.3 * p.region_scale
	cells.domain_warp_frequency = 1.0 / p.region_scale
	var low := _noise(rng, 0.5 / p.region_scale)
	for y in h:
		var z := _z(y, p)
		var bias := 0.8 * smoothstep(0.25 * p.length, 0.35 * p.length, absf(z)) \
			- 0.8 * (1.0 - smoothstep(0.0, p.region_scale, absf(z - p.sea_z) - p.sea_width / 2.0))
		for x in w:
			var i := y * w + x
			if region[i] == 0 or region[i] == 4:
				continue
			var s := 0.6 * cells.get_noise_3d(ring[x].x, ring[x].y, z) + 0.4 * low.get_noise_3d(ring[x].x, ring[x].y, z) + bias
			region[i] = 1 if s < -0.2 else (2 if s < 0.3 else 3)
	m.region = _r8(region, w, h)


## Random-order fringe expansion over land from every shoreline land cell. A shoreline cell flows
## into its first sea neighbour; every other land cell flows to the neighbour that reached it, so
## following flow_dir from any reachable land cell ends in the sea.
func _drainage(m: MacroMaps, p: WorldParams, rng: RandomNumberGenerator) -> void:
	var w := p.macro_w()
	var h := p.macro_h()
	var region := m.region.get_data()
	var flow := PackedByteArray()
	flow.resize(w * h)
	var fringe := PackedInt32Array()
	fringe.resize(w * h)
	var count := 0
	for i in w * h:
		if region[i] == 0:
			continue
		var x := i % w
		@warning_ignore("integer_division")
		var y := i / w
		for j in 8:
			var ny: int = y + DY[j]
			if ny >= 0 and ny < h and region[ny * w + posmod(x + DX[j], w)] == 0:
				flow[i] = j + 1
				fringe[count] = i
				count += 1
				break
	while count > 0:
		var k := rng.randi_range(0, count - 1)
		var i := fringe[k]
		count -= 1
		fringe[k] = fringe[count]
		var x := i % w
		@warning_ignore("integer_division")
		var y := i / w
		for j in 8:
			var ny: int = y + DY[j]
			if ny < 0 or ny >= h:
				continue
			var n: int = ny * w + posmod(x + DX[j], w)
			if region[n] != 0 and flow[n] == 0:
				flow[n] = (j + 4) % 8 + 1
				fringe[count] = n
				count += 1
	m.flow_dir = _r8(flow, w, h)


## River sources at river_sources_per_km2 over land, weighted by region (rejection sampled), each
## traced down flow_dir to the sea adding 1 to Q per cell. Cells with Q < river_q_min are dropped.
## The network is split into polylines, each from a headwater to the sea or to the cell where it
## joins a larger river (at a confluence the branch with the largest Q continues). theta is unwrapped
## along each polyline (see _vertex).
func _rivers(m: MacroMaps, p: WorldParams, rng: RandomNumberGenerator) -> void:
	var w := p.macro_w()
	var n := w * p.macro_h()
	var region := m.region.get_data()
	var flow := m.flow_dir.get_data()
	var n_land := 0
	for i in n:
		if region[i] != 0:
			n_land += 1
	var sources := roundi(p.river_sources_per_km2 * n_land * p.macro_cell * p.macro_cell / 1e6)
	var q := PackedInt32Array()
	q.resize(n)
	var placed := 0
	var tries := 0
	while placed < sources and tries < sources * 1000:
		tries += 1
		var i := rng.randi_range(0, n - 1)
		if flow[i] == 0 or rng.randf() * 4.0 >= SOURCE_WEIGHT[region[i]]:
			continue
		placed += 1
		while region[i] != 0:
			q[i] += 1
			i = _down(i, flow[i], w)
	var q_min := maxf(1.0, p.river_q_min)
	var main := PackedInt32Array()
	main.resize(n)
	main.fill(-1)
	for i in n:
		if region[i] == 0 or q[i] < q_min:
			continue
		var d := _down(i, flow[i], w)
		if region[d] != 0 and (main[d] < 0 or q[i] > q[main[d]]):
			main[d] = i
	var rivers: Array[PackedFloat32Array] = []
	for i in n:
		if region[i] == 0 or q[i] < q_min or main[i] >= 0:
			continue
		var line := _vertex(i, q[i], _theta(i % w, p), p)
		var c := i
		while true:
			var d := _down(c, flow[c], w)
			var end := region[d] == 0 or main[d] != c
			line.append_array(_vertex(d, q[c] if region[d] == 0 else q[d], line[line.size() - 4], p))
			if end:
				break
			c = d
		rivers.append(line)
	m.rivers = rivers


## One lake on a fraction lake_rate of rivers, centred on a random cell of the river (not its end),
## radius 20·sqrt(Q) m. Its level is set by _profiles.
func _lakes(m: MacroMaps, p: WorldParams, rng: RandomNumberGenerator) -> void:
	var lakes: Array[Dictionary] = []
	for r in m.rivers:
		if rng.randf() >= p.lake_rate:
			continue
		var k := 4 * rng.randi_range(0, (r.size() >> 2) - 2)
		lakes.append({"theta": fposmod(r[k], TAU), "z": r[k + 1], "radius": 20.0 * sqrt(r[k + 3]), "level": 0.0})
	m.lakes = lakes


## Walks each river upstream from its end (the sea, or the river it joins, once that one is done),
## raising the water surface by slope(Q)·cell per cell with slope(Q) = 0.004 / sqrt(Q). A lake holds
## its river flat at the height reached at its downstream edge, which becomes its level; lake cells
## (within the radius scaled by 1 + 0.3·noise, so the edge is ragged) not already water get that
## level. surface equals water_surface on river and lake cells. The river texture holds, per cell,
## the distance to the nearest river cell (m), its width and surface.
func _profiles(m: MacroMaps, p: WorldParams, rng: RandomNumberGenerator) -> void:
	var w := p.macro_w()
	var h := p.macro_h()
	var n := w * h
	var water := m.water_surface.get_data().to_float32_array()
	var width := PackedFloat32Array()
	width.resize(n)
	var lake_cells := PackedInt32Array()
	for lake in m.lakes:
		var c := m.cell(lake.theta, lake.z, p)
		lake_cells.append(c.y * w + c.x)
	var river_cells := PackedInt32Array()
	var pending := range(m.rivers.size())
	while not pending.is_empty():
		var waiting := []
		for ri: int in pending:
			var r := m.rivers[ri]
			var cells := PackedInt32Array()
			for k in range(0, r.size(), 4):
				var c := m.cell(r[k], r[k + 1], p)
				cells.append(c.y * w + c.x)
			var end := cells.size() - 1
			if water[cells[end]] <= 0.0:
				waiting.append(ri)
				continue
			var li := -1
			for k in end:
				li = maxi(li, lake_cells.find(cells[k]))
			var centre := -1 if li < 0 else lake_cells[li]
			var radius: float = 0.0 if li < 0 else m.lakes[li].radius
			var phase := 0  # 0 below the lake, 1 in it, 2 above it
			var level := water[cells[end]]
			for k in range(end - 1, -1, -1):
				var inside := phase < 2 and centre >= 0 and _dist(cells[k], centre, w) * p.macro_cell <= radius
				if inside and phase == 0:
					phase = 1
					m.lakes[li].level = level
				elif not inside and phase == 1:
					phase = 2
				if not inside:
					level += 0.004 / sqrt(r[4 * k + 3]) * p.macro_cell
				water[cells[k]] = level
				width[cells[k]] = r[4 * k + 2]
				river_cells.append(cells[k])
		if waiting.size() == pending.size():
			push_error("rivers without a reachable end: %d" % waiting.size())
			break
		pending = waiting
	var ring := _ring(p)
	var edge := _noise(rng, 1.0 / 64.0)
	for lake in m.lakes:
		var c := m.cell(lake.theta, lake.z, p)
		var rc := ceili(1.3 * lake.radius / p.macro_cell)
		for y in range(maxi(c.y - rc, 0), mini(c.y + rc + 1, h)):
			for dx in range(-rc, rc + 1):
				var x := posmod(c.x + dx, w)
				var i := y * w + x
				var r: float = lake.radius * (1.0 + 0.3 * edge.get_noise_3d(ring[x].x, ring[x].y, _z(y, p)))
				if water[i] == 0.0 and Vector2(dx, y - c.y).length() * p.macro_cell <= r:
					water[i] = lake.level
	var region := m.region.get_data()
	var surface := m.surface.get_data().to_float32_array()
	for i in n:
		if region[i] != 0 and water[i] > 0.0:
			surface[i] = water[i]
	var near := _nearest(river_cells, w, h)
	var tex := PackedFloat32Array()
	tex.resize(3 * n)
	for i in n:
		var o := near[i]
		tex[3 * i] = 1e6 if o < 0 else _dist(i, o, w) * p.macro_cell
		tex[3 * i + 1] = 0.0 if o < 0 else width[o]
		tex[3 * i + 2] = 0.0 if o < 0 else water[o]
	m.water_surface = _rf(water, w, h)
	m.surface = _rf(surface, w, h)
	m.river = Image.create_from_data(w, h, false, Image.FORMAT_RGBF, tex.to_byte_array())


## Plateaus, then land heights. Plateaus are the dry hill and mountain cells where noise exceeds its
## 1 − cliff_fraction quantile. Growth is lowest-first from the sea and river cells at their water
## surface: popping cell c at height h gives each unreached dry neighbour h + (s_region·b + s_river·
## (1 − b))·(1 + 2|noise|)·step·sqrt(max(0, 1 − (h − h_sea) / h_mtn)), clamped to h_sea + h_mtn. A
## step from outside a plateau into it also adds a jump of cliff_min..cliff_max from low-frequency
## noise (before the clamp), so the rim rises as one face and the plateau grows on from it at the
## normal rate; cliff flags those rim cells, the tops of the jumps. b = clamp(river distance /
## (3·width), 0, 1) is the regional share: 0 on a river, 1 beyond three widths. Each dry cell takes
## its lowest candidate over the neighbours popped before it (Dijkstra with lazy deletion), so a rim
## cell that the plateau itself reaches lower gets no jump and stands no lip above it. A lake cell
## keeps its level. flow_dir of every land cell except river cells is re-pointed at the cell its
## height came from, which was popped earlier, so land drains downhill to water and on to the sea
## without cycles. Writes surface, cliff and flow_dir.
func _grow(m: MacroMaps, p: WorldParams, rng: RandomNumberGenerator) -> void:
	var w := p.macro_w()
	var h := p.macro_h()
	var n := w * h
	var ring := _ring(p)
	var region := m.region.get_data()
	var water := m.water_surface.get_data().to_float32_array()
	var surface := m.surface.get_data().to_float32_array()
	var river := m.river.get_data().to_float32_array()
	var mesa := _noise(rng, 1.0 / 600.0)
	mesa.fractal_type = FastNoiseLite.FRACTAL_NONE
	var jump := _noise(rng, 1.0 / 400.0)
	jump.fractal_type = FastNoiseLite.FRACTAL_NONE
	var rough := _noise(rng, 1.0 / 1000.0)
	var mesa_n := PackedFloat32Array()
	mesa_n.resize(n)
	var rough_n := PackedFloat32Array()
	rough_n.resize(n)
	var samples := PackedFloat32Array()
	for y in h:
		var z := _z(y, p)
		for x in w:
			var i := y * w + x
			if region[i] == 0 or water[i] > 0.0:
				continue
			rough_n[i] = absf(rough.get_noise_3d(ring[x].x, ring[x].y, z))
			if region[i] == 2 or region[i] == 3:
				mesa_n[i] = mesa.get_noise_3d(ring[x].x, ring[x].y, z)
				samples.append(mesa_n[i])
	var plateau := PackedByteArray()
	plateau.resize(n)
	if not samples.is_empty():
		var t := _quantile(samples, 1.0 - p.cliff_fraction)
		for i in n:
			if (region[i] == 2 or region[i] == 3) and water[i] == 0.0 and mesa_n[i] > t:
				plateau[i] = 1
	var cliff := PackedByteArray()
	cliff.resize(n)
	var cap := p.h_sea + p.h_mtn()
	var flow := m.flow_dir.get_data()
	var heap := Heap.new(n)
	var state := PackedByteArray()  # 0 unreached, 1 reached, 2 popped (final)
	state.resize(n)
	for i in n:
		if water[i] > 0.0 and (region[i] == 0 or river[3 * i] == 0.0):
			state[i] = 1
			heap.push(water[i], i)
	while heap.size > 0:
		var c := heap.pop()
		if state[c] == 2:
			continue  # stale entry of a cell that was lowered after it was pushed
		state[c] = 2
		var hc := water[c] if water[c] > 0.0 else surface[c]
		var atten := sqrt(maxf(0.0, 1.0 - (hc - p.h_sea) / p.h_mtn()))
		var x := c % w
		@warning_ignore("integer_division")
		var y := c / w
		for j in 8:
			var ny: int = y + DY[j]
			if ny < 0 or ny >= h:
				continue
			var i: int = ny * w + posmod(x + DX[j], w)
			if state[i] == 2:
				continue
			if water[i] > 0.0:
				if state[i] == 0:  # a lake cell: keeps its level, drains to the cell that reached it
					state[i] = 1
					flow[i] = (j + 4) % 8 + 1
					heap.push(water[i], i)
				continue
			var width := river[3 * i + 1]
			var b := 1.0 if width <= 0.0 else clampf(river[3 * i] / (3.0 * width), 0.0, 1.0)
			var inc: float = (GROWTH_RATE[region[i]] * b + RIVER_RATE * (1.0 - b)) * (1.0 + 2.0 * rough_n[i]) * STEP[j] * atten
			var rim := plateau[i] and not plateau[c]
			if rim:
				var u := 0.5 + 0.5 * jump.get_noise_3d(ring[i % w].x, ring[i % w].y, _z(ny, p))
				inc += lerpf(p.cliff_min, p.cliff_max, clampf(u, 0.0, 1.0))
			var hi := minf(hc + inc, cap)
			if state[i] == 0 or hi < surface[i]:
				state[i] = 1
				surface[i] = hi
				flow[i] = (j + 4) % 8 + 1
				cliff[i] = 255 if rim else 0
				heap.push(hi, i)
	m.surface = _rf(surface, w, h)
	m.cliff = _r8(cliff, w, h)
	m.flow_dir = _r8(flow, w, h)


## bedrock_top = max(0, surface − D), D from bedrock_depth for the region (the sea floor uses the
## flat range, islands the hill range tapering to 0 at 0.04·sea_width from their shore) blended by
## noise, and D = 0 on cliff cells. Clay lenses on land where noise exceeds its 1 − clay_fraction
## quantile: clay_thickness.x at the lens edge to .y inside, its top at a noise-chosen depth in the
## dirt, clamped into it. Without a lens clay_bottom = clay_top = bedrock_top.
func _strata(m: MacroMaps, p: WorldParams, rng: RandomNumberGenerator) -> void:
	var w := p.macro_w()
	var h := p.macro_h()
	var n := w * h
	var ring := _ring(p)
	var region := m.region.get_data()
	var surface := m.surface.get_data().to_float32_array()
	var cliff := m.cliff.get_data()
	var sea := PackedInt32Array()
	for i in n:
		if region[i] == 0:
			sea.append(i)
	var shore := _nearest(sea, w, h)
	var depth := _noise(rng, 1.0 / 2000.0)
	var lens := _noise(rng, 1.0 / 400.0)
	var level := _noise(rng, 1.0 / 1000.0)
	var lens_n := PackedFloat32Array()
	lens_n.resize(n)
	var land := PackedFloat32Array()
	for y in h:
		var z := _z(y, p)
		for x in w:
			var i := y * w + x
			if region[i] != 0:
				lens_n[i] = lens.get_noise_3d(ring[x].x, ring[x].y, z)
				land.append(lens_n[i])
	var t := INF if land.is_empty() else _quantile(land, 1.0 - p.clay_fraction)
	var d_min := PackedFloat32Array()
	var d_max := PackedFloat32Array()
	for key: String in DEPTH_KEY:
		d_min.append(p.bedrock_depth[key][0])
		d_max.append(p.bedrock_depth[key][1])
	var bedrock := PackedFloat32Array()
	bedrock.resize(n)
	var bottom := PackedFloat32Array()
	bottom.resize(n)
	var top := PackedFloat32Array()
	top.resize(n)
	for y in h:
		var z := _z(y, p)
		for x in w:
			var i := y * w + x
			var s := surface[i]
			var rg := region[i]
			var d := 0.0 if cliff[i] else lerpf(d_min[rg], d_max[rg], clampf(0.5 + depth.get_noise_3d(ring[x].x, ring[x].y, z), 0.0, 1.0))
			if rg == 4:
				d *= clampf(1.0 - _dist(i, shore[i], w) * p.macro_cell / (0.04 * p.sea_width), 0.0, 1.0)
			var b := maxf(0.0, s - d)
			var ct := b
			var cb := b
			if rg != 0 and lens_n[i] > t:
				var thick := lerpf(p.clay_thickness.x, p.clay_thickness.y, clampf((lens_n[i] - t) / 0.2, 0.0, 1.0))
				var u := clampf(0.5 + level.get_noise_3d(ring[x].x, ring[x].y, z), 0.0, 1.0)
				ct = s - u * maxf(0.0, s - b - thick)
				cb = maxf(b, ct - thick)
			bedrock[i] = b
			bottom[i] = cb
			top[i] = ct
	m.bedrock_top = _rf(bedrock, w, h)
	m.clay_bottom = _rf(bottom, w, h)
	m.clay_top = _rf(top, w, h)


## Caps every dry land cell next to water at its lowest water neighbour's surface plus
## tan(bank_slope_deg)·macro_cell, lowering its strata with it. At 32 m "within bank_distance of
## water" is adjacency; the detail pass applies the limit at 1 m. One pass is stable: a cap depends
## only on water cells, which never move.
func _banks(m: MacroMaps, p: WorldParams, _rng: RandomNumberGenerator) -> void:
	var w := p.macro_w()
	var h := p.macro_h()
	var region := m.region.get_data()
	var water := m.water_surface.get_data().to_float32_array()
	var surface := m.surface.get_data().to_float32_array()
	var bedrock := m.bedrock_top.get_data().to_float32_array()
	var bottom := m.clay_bottom.get_data().to_float32_array()
	var top := m.clay_top.get_data().to_float32_array()
	var rise := tan(deg_to_rad(p.bank_slope_deg)) * p.macro_cell
	for y in h:
		for x in w:
			var i := y * w + x
			if region[i] == 0 or water[i] > 0.0:
				continue
			var s := surface[i]
			for j in 8:
				var ny: int = y + DY[j]
				if ny >= 0 and ny < h:
					var ws := water[ny * w + posmod(x + DX[j], w)]
					if ws > 0.0:
						s = minf(s, ws + rise)
			if s < surface[i]:
				surface[i] = s
				bedrock[i] = minf(bedrock[i], s)
				bottom[i] = minf(bottom[i], s)
				top[i] = minf(top[i], s)
	m.surface = _rf(surface, w, h)
	m.bedrock_top = _rf(bedrock, w, h)
	m.clay_bottom = _rf(bottom, w, h)
	m.clay_top = _rf(top, w, h)


## One pump loop per river system that reaches the sea: intake at the main stem's mouth (its sea
## vertex), an outlet at the source of the main stem and of every tributary draining into it
## (directly or through other tributaries), and q the mouth's Q. theta is wrapped to [0, TAU).
func _loops(m: MacroMaps, p: WorldParams, _rng: RandomNumberGenerator) -> void:
	var w := p.macro_w()
	var region := m.region.get_data()
	var owner := PackedInt32Array()
	owner.resize(w * p.macro_h())
	owner.fill(-1)
	for ri in m.rivers.size():
		var r := m.rivers[ri]
		for k in range(0, r.size() - 4, 4):
			var c := m.cell(r[k], r[k + 1], p)
			owner[c.y * w + c.x] = ri
	var joins := PackedInt32Array()
	for r in m.rivers:
		var e := m.cell(r[r.size() - 4], r[r.size() - 3], p)
		joins.append(-1 if region[e.y * w + e.x] == 0 else owner[e.y * w + e.x])
	var stem := PackedInt32Array()
	for ri in m.rivers.size():
		var s := ri
		while joins[s] >= 0:
			s = joins[s]
		stem.append(s)
	var loops: Array[Dictionary] = []
	for ri in m.rivers.size():
		if stem[ri] != ri:
			continue
		var outlets := PackedVector2Array()
		for rj in m.rivers.size():
			if stem[rj] == ri:
				outlets.append(Vector2(fposmod(m.rivers[rj][0], TAU), m.rivers[rj][1]))
		var r := m.rivers[ri]
		loops.append({"intake": Vector2(fposmod(r[r.size() - 4], TAU), r[r.size() - 3]), "outlets": outlets, "q": r[r.size() - 1]})
	m.loops = loops


## Spawn at the centre of the dry flat-region cell nearest theta = 0 (smallest min(theta, TAU −
## theta)) with macro slope under spawn_max_slope_deg, surface at or above h_sea and within
## spawn_river_distance of a river; else the lowest dry flat cell; else the first land cell.
func _spawn(m: MacroMaps, p: WorldParams, _rng: RandomNumberGenerator) -> void:
	var w := p.macro_w()
	var h := p.macro_h()
	var region := m.region.get_data()
	var water := m.water_surface.get_data().to_float32_array()
	var surface := m.surface.get_data().to_float32_array()
	var river := m.river.get_data().to_float32_array()
	var grade := tan(deg_to_rad(p.spawn_max_slope_deg)) * 2.0 * p.macro_cell
	var best := -1
	var best_t := INF
	var low := -1
	var any := -1
	for y in h:
		for x in w:
			var i := y * w + x
			if region[i] == 0:
				continue
			if any < 0:
				any = i
			if region[i] != 1 or water[i] > 0.0:
				continue
			if low < 0 or surface[i] < surface[low]:
				low = i
			if surface[i] < p.h_sea or river[3 * i] > p.spawn_river_distance:
				continue
			var gx := surface[y * w + posmod(x + 1, w)] - surface[y * w + posmod(x - 1, w)]
			var gy := surface[mini(y + 1, h - 1) * w + x] - surface[maxi(y - 1, 0) * w + x]
			var t := minf(_theta(x, p), TAU - _theta(x, p))
			if gx * gx + gy * gy < grade * grade and t < best_t:
				best = i
				best_t = t
	var pick := best if best >= 0 else (low if low >= 0 else any)
	if pick >= 0:
		@warning_ignore("integer_division")
		m.spawn = Vector2(_theta(pick % w, p), _z(pick / w, p))


## The value below which a fraction q of values lie.
func _quantile(values: PackedFloat32Array, q: float) -> float:
	var sorted := values.duplicate()
	sorted.sort()
	return sorted[clampi(floori(q * sorted.size()), 0, sorted.size() - 1)]


## Exact Euclidean nearest source for every cell, x wrapping and y not: the index of the nearest
## source cell, or -1 when there are none. Separable lower-envelope distance transform (Felzenszwalb
## and Huttenlocher): the nearest source row in each column, then per row the lower envelope of the
## parabolas (x - q)^2 + dy(q)^2 over the columns q unrolled to [-w/2, 3w/2). Linear in the cells.
func _nearest(sources: PackedInt32Array, w: int, h: int) -> PackedInt32Array:
	var n := w * h
	var is_source := PackedByteArray()
	is_source.resize(n)
	for i in sources:
		is_source[i] = 1
	var row := PackedInt32Array()
	row.resize(n)
	for x in w:
		var last := -1
		for y in h:
			if is_source[y * w + x]:
				last = y
			row[y * w + x] = last
		last = -1
		for y in range(h - 1, -1, -1):
			var i := y * w + x
			if is_source[i]:
				last = y
			if last >= 0 and (row[i] < 0 or last - y < y - row[i]):
				row[i] = last
	var origin := PackedInt32Array()
	origin.resize(n)
	origin.fill(-1)
	@warning_ignore("integer_division")
	var half := w / 2
	var pos := PackedInt32Array()
	pos.resize(2 * w)
	var src := PackedInt32Array()
	src.resize(2 * w)
	var fq := PackedFloat64Array()
	fq.resize(2 * w)
	var edge := PackedFloat64Array()
	edge.resize(2 * w)
	for y in h:
		var k := -1
		for e in 2 * w:
			var col := posmod(e - half, w)
			var r := row[y * w + col]
			if r < 0:
				continue
			var q := e - half
			var f := float((r - y) * (r - y))
			var s := -INF
			while k >= 0:
				s = (f + q * q - fq[k] - pos[k] * pos[k]) / (2.0 * (q - pos[k]))
				if s > edge[k]:
					break
				k -= 1
			k += 1
			pos[k] = q
			src[k] = r * w + col
			fq[k] = f
			edge[k] = s if k > 0 else -INF
		if k < 0:
			continue
		var j := 0
		for x in w:
			while j < k and edge[j + 1] < x:
				j += 1
			origin[y * w + x] = src[j]
	return origin


## Distance in cells between cell centres i and j, the short way around in x.
func _dist(i: int, j: int, w: int) -> float:
	var dx := absi(i % w - j % w)
	dx = mini(dx, w - dx)
	@warning_ignore("integer_division")
	var dy := i / w - j / w
	return sqrt(dx * dx + dy * dy)


## The cell index that flow direction d (1..8) leads to from cell i.
func _down(i: int, d: int, w: int) -> int:
	@warning_ignore("integer_division")
	return (i / w + DY[d - 1]) * w + posmod(i % w + DX[d - 1], w)


## A polyline vertex [theta, z, width, Q] at the centre of cell i. theta is the cell's angle plus the
## multiple of TAU that puts it within PI of near (the previous vertex's theta), so a polyline is
## continuous across theta = 0 and its theta may leave [0, TAU).
func _vertex(i: int, q: float, near: float, p: WorldParams) -> PackedFloat32Array:
	var w := p.macro_w()
	@warning_ignore("integer_division")
	var y := i / w
	return PackedFloat32Array([near + wrapf(_theta(i % w, p) - near, -PI, PI), _z(y, p), 4.0 * sqrt(q), q])


## Angle of the centre of column x.
func _theta(x: int, p: WorldParams) -> float:
	return (x + 0.5) * p.dtheta() * 32.0


## Axial position of the centre of row y.
func _z(y: int, p: WorldParams) -> float:
	return -p.length / 2.0 + (y + 0.5) * p.macro_cell


## Sea-level points (cos theta, sin theta) · (R − h_sea) of every column's centre, in m, for
## sampling noise periodically in theta at (ring[x].x, ring[x].y, z).
func _ring(p: WorldParams) -> PackedVector2Array:
	var ring := PackedVector2Array()
	for x in p.macro_w():
		var t := _theta(x, p)
		ring.append(Vector2(cos(t), sin(t)) * (p.radius - p.h_sea))
	return ring


func _noise(rng: RandomNumberGenerator, frequency: float) -> FastNoiseLite:
	var noise := FastNoiseLite.new()
	noise.seed = rng.randi()
	noise.frequency = frequency
	return noise


func _rf(data: PackedFloat32Array, w: int, h: int) -> Image:
	return Image.create_from_data(w, h, false, Image.FORMAT_RF, data.to_byte_array())


func _r8(data: PackedByteArray, w: int, h: int) -> Image:
	return Image.create_from_data(w, h, false, Image.FORMAT_R8, data)
