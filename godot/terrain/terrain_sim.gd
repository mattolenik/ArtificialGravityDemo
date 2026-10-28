## The loose-dirt and sheet-water simulation (the terrain slice 3 plan, decisions 2, 3, 4 and 9): sim.glsl
## stepped at a fixed 1/60 s over the active tiles of the 1 m window only, slumping loose dirt to repose,
## running sheet water down its surface, soaking it into the column and wetting dirt beside it, and letting
## the water carry loose. Activity is flagged by the GPU per window slot in the edit layer's stats buffer
## (stamps, the edit layer's apply of a blob holding loose or water, and every simulated cell that moved),
## read back every frame, and bookkept here per tile in seconds of quiet: a tile quiet for settle_time is
## handed back by step for Terrain to pack and leaves the active set. The active mask is 64 bits, so the
## window is at most 1024 cells (8 x 8 slots). settle and the bookkeeping are CPU only (headless-safe); setup
## and step are the RenderingDevice entry points.
class_name TerrainSim
extends RefCounted

## The fixed step in s, the most steps run in one frame, and the most tiles stepped at once.
const STEP := 1.0 / 60.0
const MAX_STEPS := 2
const MAX_ACTIVE := 16
const NO_CELL := Vector2i(-1, -1)

var params: ToolParams
var materials: MaterialSet
## Nothing moves into a cell within obstacle_radius cells of obstacle (Terrain.set_obstacle); none when negative.
var obstacle := NO_CELL
var obstacle_radius := -1
## m³ of sheet water reservoirs (static water over the ground) have taken, from the landed stats.
var absorbed := 0.0
## Steps run, for the driver.
var steps := 0

## Active tile -> seconds since one of its cells last moved.
var _active := {}
## The last landed stats: one word per window slot (slot y * slots + x), bit 0 a cell of it moved, bit 1 a
## cell across one of its edges moved.
var _flags := PackedInt32Array()
## Bumped by invalidate on every window move: a stats landing requested before it names other tiles.
var _generation := 0
## Seconds not yet stepped, at most MAX_STEPS steps' worth.
var _accum := 0.0
## The window (setup's, then the one settle last saw), for activate's residency test.
var _window: TerrainWindow
var _rd: RenderingDevice
var _shader: RID
var _pipeline: RID
## Per window texel, what the flux pass sends each edge neighbour: loose and water in m³, pore quanta as bytes.
var _flux_loose: RID
var _flux_water: RID
var _flux_pore: RID
## The edit layer's stats buffer and its size in bytes.
var _stats: RID
var _stats_size := 0
var _set: RID


## Compiles sim.glsl and builds its flux textures and uniform set over the window's fields and the edit
## layer's stats buffer, on the render thread. Call right after edits.setup(window).
func setup(window: TerrainWindow, edits: EditLayer) -> void:
	_window = window
	RenderingServer.call_on_render_thread(_setup_rd.bind(window, edits))


func _setup_rd(window: TerrainWindow, edits: EditLayer) -> void:
	if window._textures.is_empty() or not edits.stats_rid().is_valid():
		push_error("TerrainSim.setup: the window or its edit layer has no GPU resources (their setup failed)")
		return
	_rd = RenderingServer.get_rendering_device()
	var spirv: RDShaderSPIRV = load("res://terrain/shaders/sim.glsl").get_spirv()
	if spirv.compile_error_compute != "":
		push_error("sim.glsl: %s" % spirv.compile_error_compute)
		return
	_shader = _rd.shader_create_from_spirv(spirv)
	_pipeline = _rd.compute_pipeline_create(_shader)
	if not _pipeline.is_valid():
		push_error("sim.glsl: pipeline creation failed")
		return
	_stats = edits.stats_rid()
	_stats_size = edits.stats_size()
	_flux_loose = _flux_texture(window.size, RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT)
	_flux_water = _flux_texture(window.size, RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT)
	_flux_pore = _flux_texture(window.size, RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM)
	# Binding 0..10 the window's fields in FIELDS order, 11..13 the flux textures, 14 the stats.
	var images: Array[RID] = []
	for field: String in TerrainWindow.FIELDS:
		images.append(window.texture_rid(field))
	images.append_array([_flux_loose, _flux_water, _flux_pore])
	var uniforms: Array[RDUniform] = []
	for i in images.size():
		var u := RDUniform.new()
		u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		u.binding = i
		u.add_id(images[i])
		uniforms.append(u)
	var s := RDUniform.new()
	s.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	s.binding = images.size()
	s.add_id(_stats)
	uniforms.append(s)
	_set = _rd.uniform_set_create(uniforms, _shader, 0)


func _flux_texture(size: int, format: RenderingDevice.DataFormat) -> RID:
	var f := RDTextureFormat.new()
	f.width = size
	f.height = size
	f.format = format
	f.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	return _rd.texture_create(f, RDTextureView.new())


func _notification(what: int) -> void:
	if what != NOTIFICATION_PREDELETE or _rd == null:
		return
	# Freeing the shader frees its pipeline and uniform set; the stats buffer is the edit layer's.
	var rids: Array[RID] = [_shader, _flux_loose, _flux_water, _flux_pore]
	RenderingServer.call_on_render_thread(TerrainWindow._free_rids.bind(_rd, rids))


## The bookkeeping of one frame, CPU only: every active tile's quiet grows by delta, and the resident tile of
## each slot flagged in `flags` (bit 0 or 1) is active with quiet 0. Tiles quiet for settle_time, then the
## quietest beyond MAX_ACTIVE, leave the active set and are returned, in that order, for packing.
func settle(window: TerrainWindow, delta: float, flags: PackedInt32Array) -> Array[Vector2i]:
	_window = window
	for t: Vector2i in _active:
		_active[t] += delta
	for i in flags.size():
		if flags[i] & 3:
			@warning_ignore("integer_division")
			var t := window.tile_at(Vector2i(i % window.slots, i / window.slots))
			if t != NO_CELL:
				_active[t] = 0.0
	var out: Array[Vector2i] = active_tiles().filter(func(t: Vector2i) -> bool: return _active[t] >= params.settle_time)
	drop(out)
	if _active.size() > MAX_ACTIVE:
		var by_quiet := active_tiles()
		by_quiet.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return _active[a] > _active[b])
		var extra := by_quiet.slice(0, _active.size() - MAX_ACTIVE)
		drop(extra)
		out.append_array(extra)
	return out


## One frame: settle on the flags that landed since the last call, then the whole steps due (at most
## MAX_STEPS; an idle stretch banks none), each one compute list of a flux dispatch per active tile, a
## barrier and an apply dispatch per active tile; then, active or not, a readback of the stats and a clear.
## Returns the tiles that settled, for Terrain to pack after the lists.
func step(window: TerrainWindow, delta: float) -> Array[Vector2i]:
	var settled := settle(window, delta, _flags)
	_flags.fill(0)
	_accum = minf(_accum + delta, MAX_STEPS * STEP)
	var lists: Array[Array] = []
	while _accum >= STEP:
		_accum -= STEP
		if not has_active():
			continue
		var soak := int(steps % params.soak_every == 0)
		var blocks: Array[PackedByteArray] = []
		for mode in 2:
			for t in active_tiles():
				blocks.append(_params(window, t, mode, soak))
		lists.append(blocks)
		steps += 1
	RenderingServer.call_on_render_thread(_step_rd.bind(lists, _generation))
	return settled


func _step_rd(lists: Array[Array], generation: int) -> void:
	if not _set.is_valid():
		return
	for blocks: Array[PackedByteArray] in lists:
		@warning_ignore("integer_division")
		var apply := blocks.size() / 2
		_rd.capture_timestamp("sim_begin")
		var list := _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(list, _pipeline)
		_rd.compute_list_bind_uniform_set(list, _set, 0)
		for k in blocks.size():
			if k == apply:
				# The apply pass reads the outflows every active tile's flux pass wrote.
				_rd.compute_list_add_barrier(list)
			_rd.compute_list_set_push_constant(list, blocks[k], blocks[k].size())
			@warning_ignore("integer_division")
			_rd.compute_list_dispatch(list, TerrainWindow.TILE / 8, TerrainWindow.TILE / 8, 1)
		_rd.compute_list_end()
		_rd.capture_timestamp("sim_end")
	# After the lists, so the stats hold their flags; the request copies the buffer before the clear runs.
	var err := _rd.buffer_get_data_async(_stats, _on_stats.bind(generation), 0, _stats_size)
	if err != OK:
		push_error("sim stats readback: %s" % error_string(err))
	_rd.buffer_clear(_stats, 0, _stats_size)


## Runs inside the device's readback flush: stores the flags and adds the absorbed water, nothing else. A
## landing requested before the window last moved is dropped: its slots name other tiles.
func _on_stats(data: PackedByteArray, generation: int) -> void:
	if generation != _generation or data.size() < 4:
		return
	_flags = data.slice(0, data.size() - 4).to_int32_array()
	absorbed += data.decode_u32(data.size() - 4) * 1e-6


## The window is about to move (Terrain._move_window): stats landing from now on that were requested before
## it are dropped.
func invalidate() -> void:
	_generation += 1


## Makes each of `tiles` that is resident active with quiet 0: the activation the GPU cannot see, cells
## that must move although nothing touched them (an obstacle lifted or moved, decision 3).
func activate(tiles: Array[Vector2i]) -> void:
	for t in tiles:
		if _window != null and _window.is_resident(t):
			_active[t] = 0.0


func has_active() -> bool:
	return not _active.is_empty()


func active_tiles() -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	out.assign(_active.keys())
	return out


func is_active(tile: Vector2i) -> bool:
	return _active.has(tile)


## Removes `tiles` from the active set (Terrain packs them).
func drop(tiles: Array[Vector2i]) -> void:
	for t in tiles:
		_active.erase(t)


## The Params block of sim.glsl (std430, 112 bytes) for one dispatch of `mode` over `tile`.
func _params(window: TerrainWindow, tile: Vector2i, mode: int, soak_tick: int) -> PackedByteArray:
	var p := window.params
	var mask := 0
	for t: Vector2i in _active:
		var s := window.slot_of(t)
		mask |= 1 << (s.y * window.slots + s.x)
	var b := PackedByteArray()
	b.resize(112)
	var first := window.wanted_origin(window.center_tile)
	b.encode_s32(0, tile.x)
	b.encode_s32(4, tile.y)
	b.encode_s32(8, first.x)
	b.encode_s32(12, first.y)
	b.encode_s32(16, p.n_theta())
	b.encode_s32(20, window.slots)
	b.encode_s32(24, mode)
	b.encode_s32(28, soak_tick)
	# The uvec2 active_mask: low word at 32, high at 36.
	b.encode_s64(32, mask)
	b.encode_s32(40, obstacle.x)
	b.encode_s32(44, obstacle.y)
	b.encode_s32(48, obstacle_radius)
	b.encode_float(52, p.dtheta())
	b.encode_float(56, p.radius)
	b.encode_float(60, params.slump_rate)
	b.encode_float(64, params.flow_rate)
	b.encode_float(68, params.transport_share)
	b.encode_float(72, params.transport_depth)
	# Dirt's repose, dry, damp and saturated: all loose material is dirt.
	b.encode_float(76, tan(deg_to_rad(materials.repose_dry[0])))
	b.encode_float(80, tan(deg_to_rad(materials.repose_damp[0])))
	b.encode_float(84, tan(deg_to_rad(materials.repose_saturated[0])))
	for m in 4:
		b.encode_float(88 + 4 * m, materials.porosity[m] * params.soak_column)
	b.encode_float(104, materials.wetting_distance[0])
	b.encode_float(108, params.move_eps)
	return b
