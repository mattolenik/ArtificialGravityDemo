## Builds a world's macro maps from its WorldParams, water first: seas, regions, drainage, rivers,
## lakes and river profiles, so every water cell has a height before any land is grown. Each stage
## reads the maps the earlier stages wrote and writes its own. Deterministic: all randomness comes
## from one RandomNumberGenerator seeded from params.seed, and every noise field is periodic in theta.
class_name MacroGenerator
extends RefCounted

## Neighbour offsets (dx, dy); a flow_dir value d in 1..8 points to neighbour d - 1. x wraps, y does not.
const DX := [1, 1, 0, -1, -1, -1, 0, 1]
const DY := [0, 1, 1, 1, 0, -1, -1, -1]
## River source weight by region: sea, flat, hill, mountain, island.
const SOURCE_WEIGHT := [0, 1, 2, 4, 1]


## Generates the macro maps for params. progress, when valid, is called with (stage_name, fraction)
## before each stage and with ("done", 1.0) at the end.
func generate(params: WorldParams, progress: Callable = Callable()) -> MacroMaps:
	var rng := RandomNumberGenerator.new()
	rng.seed = params.seed
	var m := MacroMaps.new()
	var stages: Array[Callable] = [_seas, _regions, _drainage, _rivers, _lakes, _profiles]
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
## joins a larger river (at a confluence the branch with the largest Q continues).
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
		var line := PackedFloat32Array()
		var c := i
		while true:
			line.append_array(_vertex(c, q[c], p))
			var d := _down(c, flow[c], w)
			if region[d] == 0 or main[d] != c:
				line.append_array(_vertex(d, q[c] if region[d] == 0 else q[d], p))
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
		lakes.append({"theta": r[k], "z": r[k + 1], "radius": 20.0 * sqrt(r[k + 3]), "level": 0.0})
	m.lakes = lakes


## Walks each river upstream from its end (the sea, or the river it joins, once that one is done),
## raising the water surface by slope(Q)·cell per cell with slope(Q) = 0.004 / sqrt(Q). A lake holds
## its river flat at the height reached at its downstream edge, which becomes its level; lake cells
## not already water get that level. surface equals water_surface on river and lake cells. The river
## texture holds, per cell, the distance to the nearest river cell (m), its width and surface.
func _profiles(m: MacroMaps, p: WorldParams, _rng: RandomNumberGenerator) -> void:
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
	for lake in m.lakes:
		var c := m.cell(lake.theta, lake.z, p)
		var rc := ceili(lake.radius / p.macro_cell)
		for y in range(maxi(c.y - rc, 0), mini(c.y + rc + 1, h)):
			for dx in range(-rc, rc + 1):
				var i := y * w + posmod(c.x + dx, w)
				if water[i] == 0.0 and Vector2(dx, y - c.y).length() * p.macro_cell <= lake.radius:
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


## Multi-source BFS over the grid (8 neighbours, x wrapping): for each cell, the source that reached
## it first, or -1.
func _nearest(sources: PackedInt32Array, w: int, h: int) -> PackedInt32Array:
	var origin := PackedInt32Array()
	origin.resize(w * h)
	origin.fill(-1)
	var queue := sources.duplicate()
	queue.resize(w * h)
	for i in sources:
		origin[i] = i
	var head := 0
	var tail := sources.size()
	while head < tail:
		var i := queue[head]
		head += 1
		var x := i % w
		@warning_ignore("integer_division")
		var y := i / w
		for j in 8:
			var ny: int = y + DY[j]
			if ny < 0 or ny >= h:
				continue
			var n: int = ny * w + posmod(x + DX[j], w)
			if origin[n] < 0:
				origin[n] = origin[i]
				queue[tail] = n
				tail += 1
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


## A polyline vertex [theta, z, width, Q] at the centre of cell i.
func _vertex(i: int, q: float, p: WorldParams) -> PackedFloat32Array:
	var w := p.macro_w()
	@warning_ignore("integer_division")
	var y := i / w
	return PackedFloat32Array([_theta(i % w, p), _z(y, p), 4.0 * sqrt(q), q])


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
