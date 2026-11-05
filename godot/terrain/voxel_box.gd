## The voxel box of the tunnels design: a 256 x 256 x 64 m box of 1 m voxels in cylindrical grid coordinates
## (theta index, z index, height index) around the player's feet, 24 m over them to 72 m under, in sparse
## bricks of 16³ voxels: a pool of POOL_BRICKS bricks in one storage buffer and an index of 16 x 16 x 6 brick
## slots (slot = brick mod (16, 16, 4), toroidal like the window's tiles) holding a pool brick only where a
## column has something in that 16 m. The box follows the feet by whole bricks (follow): the leaving bricks'
## dirty columns are packed into the window, the bricks freed, the entering columns unpacked from the resident
## window tiles (box_unpack.glsl: free, mark, allocate, fill); a column whose voxels an op changed is flagged
## dirty (one word per box column) and packed back by box_pack.glsl (pack_dirty, every frame something was
## changed, before TerrainSim steps): the window's surface, loose and gap fields stay current for the tiles,
## the collider, the water and the saves, and a column the box never changed keeps its floats bit for bit. A
## window-side stamp inside the box is followed by reload(cells). The loose dirt moves by the sand rule
## (box_sand.glsl, step) on the active bricks only: a brick goes active when an op, the sand or an unpack
## holding loose flags its slot in box_stats (bit 0, bit 1 from a neighbour across a face), read back after
## every frame that stepped, and settles out after settle_time quiet, at most MAX_ACTIVE_BRICKS at once
## (settle, the window's bookkeeping lifted to bricks). The surface cave-in with the free height runs there
## too (material_table, wall_fails). A 16 m chunk of the box (a brick column) is touched once a packed or unpacked column in it
## holds a gap within the box's height range (the pack's and the unpack's chunk words): it is drawn and
## collided by a surface-nets mesh of its voxels (box_mesh.glsl, remesh_dirty, one chunk at a time, read back
## into a ChunkMesh under Terrain) and the tiles and the collider patch step back from it (the window's
## chunk mask, _set_mask). configure, settle and the static helpers are arithmetic (headless-safe); setup is
## the RenderingDevice entry point. Drivers read bricks back with read_brick (synchronous).
class_name VoxelBox
extends RefCounted

const BRICK := 16
const BRICKS_ACROSS := 16
const BRICKS_UP := 6
## The box's height range from the feet: UP_ABOVE m over them, DOWN_BELOW m under (to the brick: the bottom
## brick holds the height DOWN_BELOW under the feet). 72 m down by the user's choice after the project's
## review, over the design's 40 (the memory, a brick per slot, is accepted).
const UP_ABOVE := 24
const DOWN_BELOW := 72
const BRICK_BYTES := BRICK * BRICK * BRICK * 8
## Box columns per axis, and brick slots; the pool holds a brick per slot.
const COLUMNS := BRICKS_ACROSS * BRICK
const SLOTS := BRICKS_ACROSS * BRICKS_ACROSS * BRICKS_UP
const POOL_BRICKS := SLOTS
## The origin of a box that does not exist yet.
const FAR := Vector3i(1 << 20, 1 << 20, 1 << 20)
## Cells one reload may list at once.
const LIST_MAX := 65536
## box_stats: one activity word per brick slot, the pack's gap overflow count at SLOTS, the pool running dry
## at SLOTS + 1, the sand's arrivals clipped at a voxel's room at SLOTS + 2 (counts; a leak when not 0), then
## a word per chunk slot (box_column.glslh's chunk_word: chunk mod 32 along each axis; bit 0 a column in it
## was packed, bit 1 a packed or unpacked column in it holds a gap within the box's height range). A chunk is
## 16 m, a brick column: a remesh and its trimesh build stay small.
const CHUNK := 16
const CHUNK_SLOTS := 1024
const CHUNK_WORDS := SLOTS + 3
const STATS_WORDS := CHUNK_WORDS + CHUNK_SLOTS
## box_mesh.glsl: its Params block, the most vertices and indices a chunk mesh holds (read back whole, with
## the counts, in one flush), its dual cells.
const MESH_PC_BYTES := 64
const MESH_VERTS := 8192
const MESH_INDS := MESH_VERTS * 6
const MESH_CELLS := 21 * 21 * BRICKS_UP * BRICK
## The Params block of box_unpack.glsl and box_pack.glsl, std430.
const PC_BYTES := 96
const MODE_FREE := 0
const MODE_MARK := 1
const MODE_ALLOCATE := 2
const MODE_FILL := 3
## The ball ops' modes of box_edit.glsl, and its Params block.
const EDIT_SCOOP := 0
const EDIT_DUMP := 1
const EDIT_TAMP := 3
const EDIT_BORE := 4
const EDIT_SPOIL := 5
const EDIT_PILLAR := 6
const EDIT_PC_BYTES := 128
## Sub-samples per axis of a voxel for a ball's coverage (box_edit.glsl's SUB; Tools.ball_volume).
const SUB := 8
## The sand step (box_sand.glsl): the fixed step in s, the most steps run in one frame, the most bricks stepped
## at once; its Params block and the Materials block (material_table).
const STEP := 1.0 / 60.0
const MAX_STEPS := 2
const MAX_ACTIVE_BRICKS := 64
const SAND_PC_BYTES := 96
const PILLAR := 4
const MATERIALS_BYTES := 100

var params: WorldParams
var window: TerrainWindow
var edits: EditLayer
var materials: MaterialSet
## The tunables: the slump rate, the settle time, move_eps (ToolParams).
var tool_params: ToolParams
## Set by every op or step that changes voxels; pack_dirty dispatches the pack only then.
var dirty_pending := false
## Nothing moves into a cell within obstacle_radius cells of obstacle (Terrain.set_obstacle); none when negative.
var obstacle := TerrainSim.NO_CELL
var obstacle_radius := -1
## Sand steps run, for the drivers.
var steps := 0

var _origin := FAR
var _rd: RenderingDevice
var _pool: RID
var _index: RID
var _dirty: RID
var _box_stats: RID
var _free: RID
var _needed: RID
var _cells: RID
var _unpack_shader: RID
var _unpack_pipeline: RID
var _unpack_set: RID
var _pack_shader: RID
var _pack_pipeline: RID
var _pack_set: RID
var _edit_shader: RID
var _edit_pipeline: RID
var _edit_set: RID
## The ball ops' counter: m³ in units of 1e-6, then a refusal flag. Cleared before each op.
var _counter: RID
var _sand_shader: RID
var _sand_pipeline: RID
var _sand_set: RID
## Per active brick and voxel: what leaves and what arrives in a step (box_sand.glsl's Flux).
var _flux: RID
## Per brick slot: its index among the active bricks this step, or -1 (uploaded each step).
var _active_table: RID
## The Materials block of box_sand.glsl.
var _materials: RID
## Active brick (world index) -> seconds since one of its voxels last moved.
var _active := {}
## The activity words landed since the last step, ORed: per slot, bit 0 a voxel moved, bit 1 one across a
## face did or wants in.
var _flags := PackedInt32Array()
## Seconds not yet stepped, at most MAX_STEPS steps' worth.
var _accum := 0.0
## Set when an op or an unpack may have flagged a slot since the last readback.
var _stats_pending := false
## Touched chunks in the box: world chunk (theta chunk wrapped, z chunk) -> {dirty: the frame it went stale,
## 0 when its mesh is current; at: the time of its last remesh; node: ChunkMesh or null}. A chunk is touched by
## the chunk words and leaves the set with the box; its node goes under chunk_root with chunk_material (Terrain
## sets both).
var touched := {}
var chunk_root: Node3D
var chunk_material: Material
## Called with a chunk whose mask bit changed (its mesh landed with faces, or it went): the collider follows.
var on_mask_changed: Callable
## Chunk meshes landed, for the drivers.
var remeshes := 0
var _mesh_shader: RID
var _mesh_pipeline: RID
var _mesh_set: RID
var _mesh_verts: RID
var _mesh_inds: RID
var _mesh_vmap: RID
var _mesh_counts: RID
## The chunk words landed since the last take, ORed.
var _chunk_flags := PackedInt32Array()
## The remesh in flight: its chunk, then its counts and arrays as they land; empty between.
var _remesh := {}


## Arithmetic only.
func configure(p: WorldParams) -> void:
	params = p


## Creates the pool, the index, the free stack and the other buffers, compiles the shaders and builds their
## sets over the window's fields and the edit layer's stats buffer, on the render thread. Call after
## edits.setup(window).
func setup(w: TerrainWindow, e: EditLayer, m: MaterialSet, t: ToolParams = null) -> void:
	configure(w.params)
	window = w
	edits = e
	materials = m
	tool_params = t if t != null else ToolParams.new()
	_flags.resize(SLOTS)
	_chunk_flags.resize(CHUNK_SLOTS)
	RenderingServer.call_on_render_thread(_setup_rd)


func _setup_rd() -> void:
	if window._textures.is_empty() or not edits.stats_rid().is_valid():
		push_error("VoxelBox.setup: the window or its edit layer has no GPU resources (their setup failed)")
		return
	_rd = RenderingServer.get_rendering_device()
	_unpack_shader = _compile("res://terrain/shaders/box_unpack.glsl")
	_pack_shader = _compile("res://terrain/shaders/box_pack.glsl")
	_edit_shader = _compile("res://terrain/shaders/box_edit.glsl")
	_sand_shader = _compile("res://terrain/shaders/box_sand.glsl")
	_mesh_shader = _compile("res://terrain/shaders/box_mesh.glsl")
	if not _unpack_shader.is_valid() or not _pack_shader.is_valid() or not _edit_shader.is_valid() or not _sand_shader.is_valid() or not _mesh_shader.is_valid():
		return
	_unpack_pipeline = _rd.compute_pipeline_create(_unpack_shader)
	_pack_pipeline = _rd.compute_pipeline_create(_pack_shader)
	_edit_pipeline = _rd.compute_pipeline_create(_edit_shader)
	_sand_pipeline = _rd.compute_pipeline_create(_sand_shader)
	_mesh_pipeline = _rd.compute_pipeline_create(_mesh_shader)
	_pool = _rd.storage_buffer_create(POOL_BRICKS * BRICK_BYTES)
	var none := PackedInt32Array()
	none.resize(SLOTS)
	none.fill(-1)
	_index = _rd.storage_buffer_create(SLOTS * 4, none.to_byte_array())
	var zeros := PackedByteArray()
	zeros.resize(COLUMNS * COLUMNS * 4)
	_dirty = _rd.storage_buffer_create(zeros.size(), zeros)
	zeros.resize(STATS_WORDS * 4)
	_box_stats = _rd.storage_buffer_create(zeros.size(), zeros)
	var free := PackedInt32Array([POOL_BRICKS])
	for i in POOL_BRICKS:
		free.append(i)
	_free = _rd.storage_buffer_create(free.size() * 4, free.to_byte_array())
	zeros.resize(SLOTS * 4)
	_needed = _rd.storage_buffer_create(zeros.size(), zeros)
	_cells = _rd.storage_buffer_create(LIST_MAX * 8)
	zeros.resize(8)
	_counter = _rd.storage_buffer_create(8, zeros)
	zeros.resize(MAX_ACTIVE_BRICKS * BRICK * BRICK * BRICK * 8)
	_flux = _rd.storage_buffer_create(zeros.size(), zeros)
	_active_table = _rd.storage_buffer_create(SLOTS * 4, none.to_byte_array())
	_materials = _rd.storage_buffer_create(MATERIALS_BYTES, material_table())
	var buffers: Array[RID] = [_pool, _index, _dirty, _box_stats, edits.stats_rid(), _free, _needed, _cells]
	_unpack_set = _uniform_set(_unpack_shader, buffers)
	_pack_set = _uniform_set(_pack_shader, buffers)
	var edit_buffers: Array[RID] = buffers.duplicate()
	edit_buffers.append(_counter)
	_edit_set = _uniform_set(_edit_shader, edit_buffers)
	var sand_buffers: Array[RID] = buffers.duplicate()
	sand_buffers.append_array([_flux, _active_table, _materials])
	_sand_set = _uniform_set(_sand_shader, sand_buffers)
	_mesh_verts = _rd.storage_buffer_create(MESH_VERTS * 32)
	_mesh_inds = _rd.storage_buffer_create(MESH_INDS * 4)
	_mesh_vmap = _rd.storage_buffer_create(MESH_CELLS * 4)
	zeros.resize(16)
	_mesh_counts = _rd.storage_buffer_create(16, zeros)
	_mesh_set = _buffer_set(_mesh_shader, [_pool, _index, _mesh_verts, _mesh_inds, _mesh_vmap, _mesh_counts])


func _compile(path: String) -> RID:
	var spirv: RDShaderSPIRV = load(path).get_spirv()
	if spirv.compile_error_compute != "":
		push_error("%s: %s" % [path, spirv.compile_error_compute])
		return RID()
	return _rd.shader_create_from_spirv(spirv)


## The buffers at bindings 0.. (pool, index, dirty, box_stats, the edit layer's stats, the free stack, needed,
## the cell list; the counter for the edit shader), then the window's fields in FIELDS order.
func _uniform_set(shader: RID, buffers: Array[RID]) -> RID:
	var uniforms: Array[RDUniform] = []
	for i in buffers.size() + TerrainWindow.FIELDS.size():
		var u := RDUniform.new()
		u.binding = i
		if i < buffers.size():
			u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
			u.add_id(buffers[i])
		else:
			u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
			u.add_id(window.texture_rid(TerrainWindow.FIELDS[i - buffers.size()]))
		uniforms.append(u)
	return _rd.uniform_set_create(uniforms, shader, 0)


## Storage buffers at bindings 0.. only (box_mesh.glsl).
func _buffer_set(shader: RID, buffers: Array[RID]) -> RID:
	var uniforms: Array[RDUniform] = []
	for i in buffers.size():
		var u := RDUniform.new()
		u.binding = i
		u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		u.add_id(buffers[i])
		uniforms.append(u)
	return _rd.uniform_set_create(uniforms, shader, 0)


func _notification(what: int) -> void:
	if what != NOTIFICATION_PREDELETE or _rd == null:
		return
	var rids: Array[RID] = [_unpack_shader, _pack_shader, _edit_shader, _sand_shader, _mesh_shader, _pool, _index, _dirty, _box_stats, _free, _needed, _cells, _counter, _flux, _active_table, _materials,
			_mesh_verts, _mesh_inds, _mesh_vmap, _mesh_counts]
	RenderingServer.call_on_render_thread(TerrainWindow._free_rids.bind(_rd, rids))


## The Materials block of box_sand.glsl (std430, MATERIALS_BYTES): per material, tan of the solid's stand slope
## dry and saturated (the stable slopes; rock never fails), the swell of its loose form, and the free height dry
## and saturated (the roof spans).
func material_table() -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(MATERIALS_BYTES)
	for m in 5:
		b.encode_float(4 * m, tan(deg_to_rad(materials.stable_slope_dry[m])))
		b.encode_float(20 + 4 * m, tan(deg_to_rad(materials.stable_slope_saturated[m])))
		b.encode_float(40 + 4 * m, materials.swell_factor[m])
		b.encode_float(60 + 4 * m, materials.roof_span_dry[m])
		b.encode_float(80 + 4 * m, materials.roof_span_saturated[m])
	return b


## The slope stability rule with the free height: a solid step of `step` m over an edge distance w fails only
## when it is both steeper than the stand slope and taller than the free height.
static func wall_fails(step: float, w: float, stand_tan: float, free: float) -> bool:
	return step > maxf(stand_tan * w, free)


## The span rule's reach (box_sand.glsl): half the roof span, mixed dry to saturated by the column's saturation,
## times the roof's thickness in metres capped at one.
static func roof_reach(span_dry: float, span_sat: float, sat: float, thickness: float) -> float:
	return 0.5 * lerpf(span_dry, span_sat, sat) * minf(thickness, 1.0)


## The span rule: a roof voxel whose nearest support lies `nearest` m away and whose second support in the
## half-disc opposite lies `opposite` m away (INF for none) fails with no support within the reach, or held from
## one side only (a cantilever) beyond half the reach.
static func span_fails(nearest: float, opposite: float, reach: float) -> bool:
	return nearest > reach or (opposite > reach and nearest > 0.5 * reach)


## The world brick in slot i under the origin.
func brick_at_slot(i: int) -> Vector3i:
	@warning_ignore("integer_division")
	var s := Vector3i(i % BRICKS_ACROSS, (i / BRICKS_ACROSS) % BRICKS_ACROSS, i / (BRICKS_ACROSS * BRICKS_ACROSS))
	return Vector3i(_origin.x + posmod(s.x - _origin.x, BRICKS_ACROSS), _origin.y + posmod(s.y - _origin.y, BRICKS_ACROSS),
			_origin.z + posmod(s.z - _origin.z, BRICKS_UP))


## Whether a world brick lies in the box (theta the short way round).
func in_box(brick: Vector3i) -> bool:
	@warning_ignore("integer_division")
	var around := params.n_theta() / BRICK
	return posmod(brick.x - _origin.x, around) < BRICKS_ACROSS and brick.y - _origin.y >= 0 and brick.y - _origin.y < BRICKS_ACROSS \
			and brick.z - _origin.z >= 0 and brick.z - _origin.z < BRICKS_UP


## The bookkeeping of one frame, CPU only: every active brick's quiet grows by delta, and the brick of each
## slot flagged in `flags` (bit 0 or 1) is active with quiet 0. Bricks quiet for settle_time, then the quietest
## beyond MAX_ACTIVE_BRICKS, leave the active set and are returned.
func settle(delta: float, flags: PackedInt32Array) -> Array[Vector3i]:
	for b: Vector3i in _active:
		_active[b] += delta
	for i in flags.size():
		if flags[i] & 3:
			_active[brick_at_slot(i)] = 0.0
	var out: Array[Vector3i] = active_bricks().filter(func(b: Vector3i) -> bool: return _active[b] >= tool_params.settle_time)
	drop(out)
	if _active.size() > MAX_ACTIVE_BRICKS:
		var by_quiet := active_bricks()
		by_quiet.sort_custom(func(a: Vector3i, b: Vector3i) -> bool: return _active[a] > _active[b])
		var extra := by_quiet.slice(0, _active.size() - MAX_ACTIVE_BRICKS)
		drop(extra)
		out.append_array(extra)
	return out


func has_active() -> bool:
	return not _active.is_empty()


func active_bricks() -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	out.assign(_active.keys())
	return out


func is_active(brick: Vector3i) -> bool:
	return _active.has(brick)


func drop(bricks: Array[Vector3i]) -> void:
	for b in bricks:
		_active.erase(b)


## Makes the four bricks of each cell's column active with quiet 0 (an obstacle lifted: a pile held against it
## slumps on).
func activate_cells(cells: Array[Vector2i]) -> void:
	for c in cells:
		for L in BRICKS_UP:
			var b := brick_of_cell(c, bottom() + L * BRICK)
			if in_box(b):
				_active[b] = 0.0


## One frame of the sand: settle on the flags landed since the last call, then the whole steps due (at most
## MAX_STEPS; an idle stretch banks none), each one compute list of the allocate pass (bricks the last step
## wanted), a flux dispatch per active brick, a barrier and an apply dispatch per active brick; then a
## readback of the box_stats activity words and their clear, when a list ran or an op may have flagged a slot.
func step(delta: float) -> void:
	settle(delta, _flags)
	_flags.fill(0)
	if not exists():
		return
	_accum = minf(_accum + delta, MAX_STEPS * STEP)
	var lists: Array[Array] = []
	while _accum >= STEP:
		_accum -= STEP
		if not has_active():
			continue
		lists.append(_step_blocks())
		steps += 1
	if lists.is_empty() and not _stats_pending:
		return
	_stats_pending = false
	if not lists.is_empty():
		dirty_pending = true
	RenderingServer.call_on_render_thread(_step_rd.bind(lists, _pc(_origin, MODE_ALLOCATE, FAR, 0)))


## One step's active table (slot -> active index) and the flux and apply blocks of every active brick.
func _step_blocks() -> Array:
	var table := PackedInt32Array()
	table.resize(SLOTS)
	table.fill(-1)
	var flux: Array[PackedByteArray] = []
	var apply: Array[PackedByteArray] = []
	var bricks := active_bricks()
	for i in bricks.size():
		table[slot_index(slot_of(bricks[i]))] = i
		flux.append(_sand_pc(bricks[i], i, 0))
		apply.append(_sand_pc(bricks[i], i, 1))
	return [table.to_byte_array(), flux, apply]


func _step_rd(lists: Array[Array], alloc_block: PackedByteArray) -> void:
	if not _sand_set.is_valid():
		return
	for l: Array in lists:
		_rd.buffer_update(_active_table, 0, SLOTS * 4, l[0])
		# The pair's name carries the step's active brick count (box_sand_<n>), for the time per active brick.
		_rd.capture_timestamp("box_sand_%d_begin" % l[1].size())
		var list := _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(list, _unpack_pipeline)
		_rd.compute_list_bind_uniform_set(list, _unpack_set, 0)
		_rd.compute_list_set_push_constant(list, alloc_block, alloc_block.size())
		@warning_ignore("integer_division")
		_rd.compute_list_dispatch(list, SLOTS / 64, 1, 1)
		_rd.compute_list_add_barrier(list)
		_rd.compute_list_bind_compute_pipeline(list, _sand_pipeline)
		_rd.compute_list_bind_uniform_set(list, _sand_set, 0)
		for pass_blocks: Array[PackedByteArray] in [l[1], l[2]]:
			for b in pass_blocks:
				_rd.compute_list_set_push_constant(list, b, b.size())
				_rd.compute_list_dispatch(list, 1, 1, 1)
			_rd.compute_list_add_barrier(list)
		_rd.compute_list_end()
		_rd.capture_timestamp("box_sand_%d_end" % l[1].size())
	_read_stats_rd()


## The readback of box_stats (the slot words and the chunk words; the counters between ride along), then
## their clear (the request copies the buffer before the clear runs).
func _read_stats_rd() -> void:
	var err := _rd.buffer_get_data_async(_box_stats, _on_stats, 0, STATS_WORDS * 4)
	if err != OK:
		push_error("box stats readback: %s" % error_string(err))
	_rd.buffer_clear(_box_stats, 0, SLOTS * 4)
	_rd.buffer_clear(_box_stats, CHUNK_WORDS * 4, CHUNK_SLOTS * 4)


## Inside the device's readback flush: ORs the landed activity words into _flags (settle reads them) and the
## chunk words into _chunk_flags (remesh_dirty takes them).
func _on_stats(data: PackedByteArray) -> void:
	var words := data.to_int32_array()
	if words.size() < STATS_WORDS:
		return
	for i in SLOTS:
		_flags[i] |= words[i]
	for i in CHUNK_SLOTS:
		_chunk_flags[i] |= words[CHUNK_WORDS + i]


## The Params block of box_sand.glsl (std430, SAND_PC_BYTES) for brick (world index) at active index `active`.
func _sand_pc(brick: Vector3i, active: int, mode: int) -> PackedByteArray:
	var first := window.wanted_origin(window.center_tile)
	var b := PackedByteArray()
	b.resize(SAND_PC_BYTES)
	b.encode_s32(0, _origin.x)
	b.encode_s32(4, _origin.y)
	b.encode_s32(8, _origin.z)
	b.encode_s32(12, mode)
	b.encode_s32(16, brick.x)
	b.encode_s32(20, brick.y)
	b.encode_s32(24, brick.z)
	b.encode_s32(28, active)
	b.encode_s32(32, first.x)
	b.encode_s32(36, first.y)
	b.encode_s32(40, params.n_theta())
	b.encode_s32(44, window.slots)
	b.encode_s32(48, params.n_z())
	@warning_ignore("integer_division")
	b.encode_s32(52, params.n_theta() / BRICK)
	b.encode_float(56, params.radius)
	b.encode_float(60, params.dtheta())
	b.encode_s32(64, obstacle.x)
	b.encode_s32(68, obstacle.y)
	b.encode_s32(72, obstacle_radius)
	b.encode_float(76, tool_params.slump_rate)
	# Dirt's repose, dry, damp and saturated: all loose material is dirt.
	b.encode_float(80, tan(deg_to_rad(materials.repose_dry[0])))
	b.encode_float(84, tan(deg_to_rad(materials.repose_damp[0])))
	b.encode_float(88, tan(deg_to_rad(materials.repose_saturated[0])))
	b.encode_float(92, tool_params.move_eps)
	return b


## The box origin in bricks for feet at cell feet_cell and height h_feet: the feet's brick is the middle one
## across and along, the bottom brick DOWN_BELOW m under the feet. The theta brick is not wrapped.
static func box_origin_for(feet_cell: Vector2i, h_feet: float) -> Vector3i:
	return Vector3i(floori(feet_cell.x / 16.0) - 8, floori(feet_cell.y / 16.0) - 8, floori((h_feet - DOWN_BELOW) / 16.0))


static func slot_of(brick: Vector3i) -> Vector3i:
	return Vector3i(posmod(brick.x, BRICKS_ACROSS), posmod(brick.y, BRICKS_ACROSS), posmod(brick.z, BRICKS_UP))


static func slot_index(slot: Vector3i) -> int:
	return (slot.z * BRICKS_ACROSS + slot.y) * BRICKS_ACROSS + slot.x


## The brick holding cell at height index k, in the origin's frame (theta the short way round).
func brick_of_cell(cell: Vector2i, k: int) -> Vector3i:
	@warning_ignore("integer_division")
	var around := params.n_theta() / BRICK
	return Vector3i(_origin.x + posmod(floori(cell.x / 16.0) - _origin.x, around), floori(cell.y / 16.0), floori(k / 16.0))


## The box column slot (0..255 each) of a cell, as the shaders address it: brick mod 16, then the cell within.
func column_slot(cell: Vector2i) -> Vector2i:
	return Vector2i(posmod(floori(cell.x / 16.0), BRICKS_ACROSS) * BRICK + posmod(cell.x, BRICK),
			posmod(floori(cell.y / 16.0), BRICKS_ACROSS) * BRICK + posmod(cell.y, BRICK))


func origin() -> Vector3i:
	return _origin


## The height index of the box's lowest voxel.
func bottom() -> int:
	return _origin.z * BRICK


## The height index past the box's highest voxel.
func top() -> int:
	return bottom() + BRICKS_UP * BRICK


func exists() -> bool:
	return _origin != FAR


## Moves the box so the feet's brick is its middle, when that changes: the leaving bricks' dirty columns are
## packed, the bricks freed and the entering columns unpacked from the window, all in one compute list.
func follow(feet: Vector3) -> void:
	var cell := params.cell_of(Cyl.theta_of(feet), feet.z)
	var o := box_origin_for(cell, Cyl.height_of(feet, params.radius))
	@warning_ignore("integer_division")
	o.x = posmod(o.x, params.n_theta() / BRICK)
	if o == _origin:
		return
	var old := _origin
	_origin = o
	# Bricks that leave the box leave the active set; landed flags name slots that change hands.
	drop(active_bricks().filter(func(b: Vector3i) -> bool: return not in_box(b)))
	_flags.fill(0)
	# Chunks that leave the box go, with their meshes; a move up or down changes what the others hold.
	for ch: Vector2i in touched.keys():
		if not chunk_in_box(ch):
			_free_chunk(ch)
		elif o.z != old.z:
			_stale(ch)
	_chunk_flags.fill(0)
	_stats_pending = true
	RenderingServer.call_on_render_thread(_move_rd.bind(old, o, _pc(old, 0, FAR, 0)))


func _move_rd(old: Vector3i, o: Vector3i, pack_block: PackedByteArray) -> void:
	if not _unpack_set.is_valid():
		return
	_rd.capture_timestamp("box_unpack_begin")
	var list := _rd.compute_list_begin()
	if old != FAR:
		_pack_dispatch(list, pack_block)
		_rd.compute_list_add_barrier(list)
	_rd.compute_list_bind_compute_pipeline(list, _unpack_pipeline)
	_rd.compute_list_bind_uniform_set(list, _unpack_set, 0)
	@warning_ignore("integer_division")
	var per_slot := SLOTS / 64
	@warning_ignore("integer_division")
	var per_column := COLUMNS * COLUMNS / 64
	for step: Array in [[MODE_FREE, per_slot], [MODE_MARK, per_column], [MODE_ALLOCATE, per_slot], [MODE_FILL, per_column]]:
		var pc := _pc(o, step[0], old, 0)
		_rd.compute_list_set_push_constant(list, pc, pc.size())
		_rd.compute_list_dispatch(list, step[1], 1, 1)
		_rd.compute_list_add_barrier(list)
	_rd.compute_list_end()
	_rd.capture_timestamp("box_unpack_end")


## Unpacks `cells` again from the window (after a window-side stamp over them), allocating any brick they now
## need; their dirty flags are dropped, the window being the truth, and bricks that take loose go active.
## Cells outside the box are ignored.
func reload(cells: Array[Vector2i]) -> void:
	if cells.is_empty() or not exists():
		return
	_stats_pending = true
	var data := PackedInt32Array()
	for c in cells:
		data.append(c.x)
		data.append(c.y)
	RenderingServer.call_on_render_thread(_reload_rd.bind(data.to_byte_array(), _origin))


func _reload_rd(data: PackedByteArray, o: Vector3i) -> void:
	if not _unpack_set.is_valid():
		return
	for start in range(0, data.size(), LIST_MAX * 8):
		var chunk := data.slice(start, mini(start + LIST_MAX * 8, data.size()))
		@warning_ignore("integer_division")
		var count := chunk.size() / 8
		_rd.buffer_update(_cells, 0, chunk.size(), chunk)
		var list := _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(list, _unpack_pipeline)
		_rd.compute_list_bind_uniform_set(list, _unpack_set, 0)
		@warning_ignore("integer_division")
		for step: Array in [[MODE_MARK, ceili(count / 64.0)], [MODE_ALLOCATE, SLOTS / 64], [MODE_FILL, ceili(count / 64.0)]]:
			var pc := _pc(o, step[0], FAR, count)
			_rd.compute_list_set_push_constant(list, pc, pc.size())
			_rd.compute_list_dispatch(list, step[1], 1, 1)
			_rd.compute_list_add_barrier(list)
		_rd.compute_list_end()


## Packs every dirty column into the window fields (box_pack.glsl), when an op or a step flagged any since
## the last call. From Terrain._process before sim.step, with the count of the simulation's stats readbacks
## asked so far: the tiles under the active bricks are marked in the edit layer as holding an unpacked change
## at that count (EditLayer.stamped), so a window move within the readback's latency packs them before they
## leave (the pack's own activity flag lands a few frames later).
func pack_dirty(asked := 0) -> void:
	if not dirty_pending or not exists():
		return
	dirty_pending = false
	for b in active_bricks():
		edits.stamped[window.tile_of_cell(posmod(b.x * BRICK, params.n_theta()), b.y * BRICK)] = asked
		edits.stamped[window.tile_of_cell(posmod(b.x * BRICK + BRICK - 1, params.n_theta()), b.y * BRICK + BRICK - 1)] = asked
	# The pack's chunk words land with the next readback.
	_stats_pending = true
	pack_all_sync()


## The pack of every dirty column now, whatever dirty_pending says: for callers that read the window right
## after (the drivers, through synchronous reads queued behind it) and for the exit.
func pack_all_sync() -> void:
	if not exists():
		return
	edits.stats_pending = true
	RenderingServer.call_on_render_thread(_pack_rd.bind(_pc(_origin, 0, FAR, 0)))


func _pack_rd(block: PackedByteArray) -> void:
	if not _pack_set.is_valid():
		return
	_rd.capture_timestamp("box_pack_begin")
	var list := _rd.compute_list_begin()
	_pack_dispatch(list, block)
	_rd.compute_list_end()
	_rd.capture_timestamp("box_pack_end")


func _pack_dispatch(list: int, block: PackedByteArray) -> void:
	_rd.compute_list_bind_compute_pipeline(list, _pack_pipeline)
	_rd.compute_list_bind_uniform_set(list, _pack_set, 0)
	_rd.compute_list_set_push_constant(list, block, block.size())
	@warning_ignore("integer_division")
	_rd.compute_list_dispatch(list, COLUMNS * COLUMNS / 64, 1, 1)


## The Params block of the box shaders (std430, PC_BYTES) for origin o, built on the caller's thread so the
## window residency it carries is the window's as of the call.
func _pc(o: Vector3i, mode: int, old: Vector3i, count: int) -> PackedByteArray:
	var first := window.wanted_origin(window.center_tile)
	var b := PackedByteArray()
	b.resize(PC_BYTES)
	b.encode_s32(0, o.x)
	b.encode_s32(4, o.y)
	b.encode_s32(8, o.z)
	b.encode_s32(12, mode)
	b.encode_s32(16, old.x)
	b.encode_s32(20, old.y)
	b.encode_s32(24, old.z)
	b.encode_s32(28, count)
	b.encode_s32(32, first.x)
	b.encode_s32(36, first.y)
	b.encode_s32(40, params.n_theta())
	b.encode_s32(44, window.slots)
	b.encode_s32(48, params.n_z())
	@warning_ignore("integer_division")
	b.encode_s32(52, params.n_theta() / BRICK)
	b.encode_float(56, params.radius)
	b.encode_float(60, params.dtheta())
	b.encode_float(64, params.h_sea + params.h_mtn())
	for m in 4:
		b.encode_float(80 + 4 * m, materials.swell_factor[m])
	return b


## The grid frame of station-local p: (theta index, z index, height), continuous.
func grid_of(p: Vector3) -> Vector3:
	return Vector3(Cyl.theta_of(p) / params.dtheta(), p.z + params.length / 2.0, Cyl.height_of(p, params.radius))


## The bounding box of voxels of the ball of radius m at grid point g: [first, first + extent), the theta
## index unwrapped near g.x; an extent of zero when it is not wholly inside the box (and the station).
func ball_box(g: Vector3, radius: float) -> Array[Vector3i]:
	var w := (params.radius - g.z) * params.dtheta()
	var first := Vector3i(floori(g.x - radius / w), floori(g.y - radius), floori(g.z - radius))
	var last := Vector3i(floori(g.x + radius / w), floori(g.y + radius), floori(g.z + radius))
	var extent := last - first + Vector3i.ONE
	@warning_ignore("integer_division")
	var around := params.n_theta() / BRICK
	var inside := first.y >= 0 and last.y < params.n_z() and first.z >= bottom() and last.z < bottom() + BRICKS_UP * BRICK \
			and extent.x <= 8 and extent.y <= 8 and extent.z <= 8
	for bx in [first.x, last.x]:
		inside = inside and posmod(floori(bx / 16.0) - _origin.x, around) < BRICKS_ACROSS
	for by in [first.y, last.y]:
		inside = inside and floori(by / 16.0) - _origin.y >= 0 and floori(by / 16.0) - _origin.y < BRICKS_ACROSS
	return [first, extent if inside else Vector3i.ZERO]


## Scoops the ball of radius m at station-local p (box_edit.glsl's scoop): loose first, then solid but rock, by
## the ball's coverage; counted(m3, refused) lands with the loose-equivalent m³ taken (solid times its
## material's swell), refused when a column would get a fifth gap (nothing taken). False, nothing dispatched,
## when the ball is not wholly in the box.
func scoop(p: Vector3, radius: float, swell: PackedFloat32Array, counted: Callable) -> bool:
	var g := grid_of(p)
	var bb := ball_box(g, radius)
	if bb[1] == Vector3i.ZERO:
		return false
	dirty_pending = true
	_stats_pending = true
	RenderingServer.call_on_render_thread(_edit_rd.bind(_edit_pc(EDIT_SCOOP, bb[0], bb[1], g, radius, swell, 0.0), PackedInt32Array(), PackedByteArray(), counted))
	return true


## Dumps volume m³ of loose into the air of the ball of radius m at p, nearest the centre first (the ball's
## bricks allocated first); placed(m3, false) lands with what fit, the rest stays in the hand. False, nothing
## dispatched, when the ball is not wholly in the box.
func dump(p: Vector3, radius: float, volume: float, placed: Callable) -> bool:
	var g := grid_of(p)
	var bb := ball_box(g, radius)
	if bb[1] == Vector3i.ZERO:
		return false
	var slots := PackedInt32Array()
	for bz in range(floori(bb[0].z / 16.0), floori((bb[0].z + bb[1].z - 1) / 16.0) + 1):
		for by in range(floori(bb[0].y / 16.0), floori((bb[0].y + bb[1].y - 1) / 16.0) + 1):
			for bx in range(floori(bb[0].x / 16.0), floori((bb[0].x + bb[1].x - 1) / 16.0) + 1):
				slots.append(slot_index(slot_of(Vector3i(bx, by, bz))))
	dirty_pending = true
	_stats_pending = true
	RenderingServer.call_on_render_thread(_edit_rd.bind(_edit_pc(EDIT_DUMP, bb[0], bb[1], g, radius, PackedFloat32Array([1, 1, 1, 1]), volume),
			slots, _pc(_origin, MODE_ALLOCATE, FAR, 0), placed))
	return true


## The bounding box of a disc op's columns and voxels: the disc of `radius` cells around the cell under grid
## point g, the voxels from `below` under g's height to `above` over it; an extent of zero when it is not
## wholly in the box (and on the station).
func disc_box(g: Vector3, radius: int, below: int, above: int) -> Array[Vector3i]:
	var first := Vector3i(floori(g.x) - radius, floori(g.y) - radius, floori(g.z) - below)
	var extent := Vector3i(2 * radius + 1, 2 * radius + 1, below + above + 1)
	@warning_ignore("integer_division")
	var around := params.n_theta() / BRICK
	var inside := first.y >= 0 and first.y + extent.y <= params.n_z() and first.z >= bottom() and first.z + extent.z <= bottom() + BRICKS_UP * BRICK \
			and extent.x <= 8 and extent.y <= 8 and extent.z <= 16
	for bx in [first.x, first.x + extent.x - 1]:
		inside = inside and posmod(floori(bx / 16.0) - _origin.x, around) < BRICKS_ACROSS
	for by in [first.y, first.y + extent.y - 1]:
		inside = inside and floori(by / 16.0) - _origin.y >= 0 and floori(by / 16.0) - _origin.y < BRICKS_ACROSS
	return [first, extent if inside else Vector3i.ZERO]


## A disc op (box_edit.glsl's tamp, bore, spoil) at station-local p over the disc of `radius` cells,
## the voxels from 2 under p's height to 2 over it (the bore 3 under to 4 over, the spoil 2 under to 13 over:
## its pile grows); false, nothing dispatched, when it is not wholly in the box.
func _disc_op(mode: int, p: Vector3, radius: int, amount: float, limit: float, dir: Vector2i, counted: Callable) -> bool:
	var g := grid_of(p)
	var bb := disc_box(g, radius, 3 if mode == EDIT_BORE else 2, 13 if mode == EDIT_SPOIL else (4 if mode == EDIT_BORE else 2))
	if bb[1] == Vector3i.ZERO:
		return false
	dirty_pending = true
	_stats_pending = true
	var pc := _edit_pc(mode, bb[0], bb[1], g, float(radius), PackedFloat32Array([1, 1, 1, 1]), amount)
	pc.encode_s32(108, [Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(0, -1)].find(dir))
	pc.encode_float(112, limit)
	pc.encode_s32(116, obstacle_radius)
	pc.encode_s32(120, obstacle.x)
	pc.encode_s32(124, obstacle.y)
	var slots := PackedInt32Array()
	if mode == EDIT_SPOIL:
		for bz in range(floori(bb[0].z / 16.0), floori((bb[0].z + bb[1].z - 1) / 16.0) + 1):
			for by in range(floori(bb[0].y / 16.0), floori((bb[0].y + bb[1].y - 1) / 16.0) + 1):
				for bx in range(floori(bb[0].x / 16.0), floori((bb[0].x + bb[1].x - 1) / 16.0) + 1):
					slots.append(slot_index(slot_of(Vector3i(bx, by, bz))))
	RenderingServer.call_on_render_thread(_edit_rd.bind(pc, slots, _pc(_origin, MODE_ALLOCATE, FAR, 0) if not slots.is_empty() else PackedByteArray(), counted))
	return true


## A landing's tamp: the footprint's loose gains `step` of compaction and folds into solid with the swell at 1.
func tamp(p: Vector3, radius: int, step: float, swell: float) -> bool:
	return _disc_op(EDIT_TAMP, p, radius, step, swell, Vector2i(1, 0), Callable())


## An auger's dry tick: the disc's columns lose `step` m of solid from their top run, stopping at rock;
## counted(m3, wet) lands with the annulus cut, or wet with nothing cut when the centre stands in water (the
## window's bore pumps then).
func bore(p: Vector3, radius: int, step: float, counted: Callable) -> bool:
	return _disc_op(EDIT_BORE, p, radius, step, 0.0, Vector2i(1, 0), counted)


## The auger's spoil: volume m³ of fresh loose spread over the disc; placed(m3, false) lands with what fit.
func spoil(p: Vector3, radius: int, volume: float, placed: Callable) -> bool:
	return _disc_op(EDIT_SPOIL, p, radius, volume, 0.0, Vector2i(1, 0), placed)


## Stands a pillar in the column at station-local p, from the voxel of p's height to the voxel `reach` m over
## it (Tools.pillar_range), or takes away the pillar holding p's voxel or one next to it, looked for as far
## under p (box_edit.glsl's pillar); counted(count,
## false) lands with the voxels filled, minus those taken, 0 where there is no roof within the reach. False,
## nothing dispatched, when the column is not wholly in the box.
func pillar(p: Vector3, reach: float, counted: Callable) -> bool:
	var g := grid_of(p)
	# Tools.pillar_range's span, written out: the box does not load Tools (its preloaded auger scene would leak
	# from every headless test that loads the box).
	var span := Vector2i(floori(g.z), floori(g.z + reach))
	var bb := disc_box(g, 0, span.y - span.x, span.y - span.x)
	if bb[1] == Vector3i.ZERO:
		return false
	dirty_pending = true
	_stats_pending = true
	RenderingServer.call_on_render_thread(_edit_rd.bind(_edit_pc(EDIT_PILLAR, bb[0], bb[1], g, 0.0, PackedFloat32Array(), 0.0), PackedInt32Array(), PackedByteArray(), counted))
	return true


## One ball op: the counter cleared, the listed slots flagged needed and allocated (a dump), the op dispatched
## over its one workgroup, the counter read back into cb(m3, flag).
func _edit_rd(block: PackedByteArray, slots: PackedInt32Array, alloc_block: PackedByteArray, cb: Callable) -> void:
	if not _edit_set.is_valid():
		return
	_rd.buffer_clear(_counter, 0, 8)
	var one := PackedByteArray([1, 0, 0, 0])
	for e in slots:
		_rd.buffer_update(_needed, e * 4, 4, one)
	_rd.capture_timestamp("box_edit_begin")
	var list := _rd.compute_list_begin()
	if not slots.is_empty():
		_rd.compute_list_bind_compute_pipeline(list, _unpack_pipeline)
		_rd.compute_list_bind_uniform_set(list, _unpack_set, 0)
		_rd.compute_list_set_push_constant(list, alloc_block, alloc_block.size())
		@warning_ignore("integer_division")
		_rd.compute_list_dispatch(list, SLOTS / 64, 1, 1)
		_rd.compute_list_add_barrier(list)
	_rd.compute_list_bind_compute_pipeline(list, _edit_pipeline)
	_rd.compute_list_bind_uniform_set(list, _edit_set, 0)
	_rd.compute_list_set_push_constant(list, block, block.size())
	_rd.compute_list_dispatch(list, 1, 1, 1)
	_rd.compute_list_end()
	_rd.capture_timestamp("box_edit_end")
	var err := _rd.buffer_get_data_async(_counter, _counted.bind(cb), 0, 8)
	if err != OK:
		push_error("box counter readback: %s" % error_string(err))


## Inside the device's readback flush: hands the counter (m³, or the pillar's signed voxel count, and whether
## the op was refused) to cb, which must only store them.
func _counted(data: PackedByteArray, cb: Callable) -> void:
	if cb.is_valid():
		cb.call(data.decode_s32(0) * 1e-6, data.decode_u32(4) != 0)


## The Params block of box_edit.glsl (std430, EDIT_PC_BYTES).
func _edit_pc(mode: int, first: Vector3i, extent: Vector3i, g: Vector3, radius: float, swell: PackedFloat32Array, amount: float) -> PackedByteArray:
	var fst := window.wanted_origin(window.center_tile)
	var b := PackedByteArray()
	b.resize(EDIT_PC_BYTES)
	b.encode_s32(0, _origin.x)
	b.encode_s32(4, _origin.y)
	b.encode_s32(8, _origin.z)
	b.encode_s32(12, mode)
	b.encode_s32(16, first.x)
	b.encode_s32(20, first.y)
	b.encode_s32(24, first.z)
	b.encode_s32(28, params.n_theta())
	b.encode_s32(32, extent.x)
	b.encode_s32(36, extent.y)
	b.encode_s32(40, extent.z)
	b.encode_s32(44, window.slots)
	b.encode_float(48, g.x)
	b.encode_float(52, g.y)
	b.encode_float(56, g.z)
	b.encode_float(60, radius)
	for m in 4:
		b.encode_float(64 + 4 * m, swell[m] if m < swell.size() else 1.0)
	b.encode_float(80, amount)
	b.encode_float(84, params.radius)
	b.encode_float(88, params.dtheta())
	b.encode_s32(92, params.n_z())
	b.encode_s32(96, fst.x)
	b.encode_s32(100, fst.y)
	@warning_ignore("integer_division")
	b.encode_s32(104, params.n_theta() / BRICK)
	b.encode_s32(116, -1)
	return b


## The brick in `slot`, synchronously (a stall: drivers only); empty when the slot holds none.
func read_brick(slot: Vector3i) -> PackedByteArray:
	var out: Array[PackedByteArray] = []
	RenderingServer.call_on_render_thread(func() -> void:
		var e := _rd.buffer_get_data(_index, slot_index(slot) * 4, 4).decode_s32(0)
		out.append(_rd.buffer_get_data(_pool, e * BRICK_BYTES, BRICK_BYTES) if e >= 0 else PackedByteArray()))
	return out[0]


## The slots holding a brick, synchronously (drivers only).
func allocated() -> int:
	var out: Array[int] = []
	RenderingServer.call_on_render_thread(func() -> void:
		var n := 0
		for e in _rd.buffer_get_data(_index).to_int32_array():
			n += int(e >= 0)
		out.append(n))
	return out[0]


## The box_stats words, synchronously (drivers only).
func read_stats() -> PackedInt32Array:
	var out: Array[PackedInt32Array] = []
	RenderingServer.call_on_render_thread(func() -> void:
		out.append(_rd.buffer_get_data(_box_stats).to_int32_array()))
	return out[0]


## Voxel (x, y, z) of a brick as read_brick returns it (x across, y up, z along).
static func voxel(brick: PackedByteArray, x: int, y: int, z: int) -> Dictionary:
	var o := ((y * BRICK + z) * BRICK + x) * 8
	var w0 := brick.decode_u32(o)
	var w1 := brick.decode_u32(o + 4)
	return {"solid": w0 & 0xFFFF, "loose": w0 >> 16, "material": w1 & 255, "compaction": (w1 >> 8) & 255,
			"saturation": (w1 >> 16) & 255, "hanging": (w1 >> 24) & 1}


## The 32 m chunk of a cell.
static func chunk_of_cell(cell: Vector2i) -> Vector2i:
	return Vector2i(floori(cell.x / float(CHUNK)), floori(cell.y / float(CHUNK)))


## The chunks the box spans along an axis from its origin brick o: the first (theta in the origin's frame)
## and the count (a chunk is a brick column).
static func _chunk_span(o: int) -> Vector2i:
	return Vector2i(o, BRICKS_ACROSS)


## Whether a world chunk (theta chunk wrapped, z chunk) lies in the box.
func chunk_in_box(ch: Vector2i) -> bool:
	var sx := _chunk_span(_origin.x)
	var sy := _chunk_span(_origin.y)
	@warning_ignore("integer_division")
	var n := params.n_theta() / CHUNK
	return posmod(ch.x - sx.x, n) < sx.y and ch.y - sy.x >= 0 and ch.y - sy.x < sy.y


## The chunks in the box (and on the station) whose words have `bit`: each chunk slot (x mod 32, y mod 32)
## resolved in the box's span, theta wrapped.
func touched_from(words: PackedInt32Array, bit := 2) -> Array[Vector2i]:
	var sx := _chunk_span(_origin.x)
	var sy := _chunk_span(_origin.y)
	@warning_ignore("integer_division")
	var n := params.n_theta() / CHUNK
	@warning_ignore("integer_division")
	var rows := params.n_z() / CHUNK
	var out: Array[Vector2i] = []
	for i in CHUNK_SLOTS:
		if (words[i] & bit) == 0:
			continue
		var cx := sx.x + posmod(i % 32 - sx.x, 32)
		@warning_ignore("integer_division")
		var cy := sy.x + posmod(i / 32 - sy.x, 32)
		if cx - sx.x < sx.y and cy - sy.x < sy.y and cy >= 0 and cy < rows:
			out.append(Vector2i(posmod(cx, n), cy))
	return out


## Whether a touched chunk with a landed mesh holds the column under station-space p, within the box's height
## range: its trimesh is the ground there (Terrain.covered).
func covers(p: Vector3) -> bool:
	var h := Cyl.height_of(p, params.radius)
	if not exists() or h < bottom() or h >= top():
		return false
	var st: Dictionary = touched.get(chunk_of_cell(params.cell_of(Cyl.theta_of(p), p.z)), {})
	return not st.is_empty() and st.node != null and st.node.faces > 0


## The landed chunk words: a chunk with a gap in range is touched (dirty), a touched chunk with a packed
## column is dirty.
func _take_chunk_flags() -> void:
	for ch in touched_from(_chunk_flags, 2):
		if not touched.has(ch):
			touched[ch] = {"dirty": 0, "at": -INF, "node": null}
			_stale(ch)
	for ch in touched_from(_chunk_flags, 1):
		if touched.has(ch):
			_stale(ch)
	_chunk_flags.fill(0)


## Marks a touched chunk's mesh stale from this frame on (the oldest stale chunk is remeshed first, so a scoop
## at a corner of four chunks starves none).
func _stale(ch: Vector2i) -> void:
	if touched[ch].dirty == 0:
		touched[ch].dirty = maxi(1, Engine.get_process_frames())


## One chunk mesh at a time (Terrain._process, after pack_dirty): the chunk words landed are taken up, a
## remesh whose counts and arrays landed is given to its chunk's node (the mask follows), else the stale
## chunk that has waited longest, collider_edit_interval or more after its own last remesh, is meshed by
## box_mesh.glsl.
func remesh_dirty(now: float) -> void:
	if not exists() or chunk_root == null:
		return
	_take_chunk_flags()
	if not _remesh.is_empty():
		_remesh_landing()
		return
	var pick := Vector2i.ZERO
	var oldest := 0
	for ch: Vector2i in touched:
		var st: Dictionary = touched[ch]
		if st.dirty > 0 and (oldest == 0 or st.dirty < oldest) and now - st.at >= tool_params.collider_edit_interval:
			oldest = st.dirty
			pick = ch
	if oldest == 0:
		return
	touched[pick].dirty = 0
	touched[pick].at = now
	_remesh = {"chunk": pick}
	RenderingServer.call_on_render_thread(_mesh_rd.bind(_mesh_pc(pick, 0), _mesh_pc(pick, 1)))


func _remesh_landing() -> void:
	if not (_remesh.has("counts") and _remesh.has("verts") and _remesh.has("inds")):
		return
	var ch: Vector2i = _remesh.chunk
	var counts: PackedByteArray = _remesh.counts
	var nv := mini(counts.decode_u32(0), MESH_VERTS)
	var ni := mini(counts.decode_u32(4), MESH_INDS)
	if counts.decode_u32(8) != 0:
		push_warning("chunk %s: the mesh buffers filled (%d vertices, %d indices)" % [ch, nv, ni])
	if touched.has(ch):
		_land_chunk(ch, _remesh.verts.slice(0, nv * 32), _remesh.inds.slice(0, ni * 4))
	_remesh = {}


## Inside the device's readback flush: stores only.
func _on_mesh_data(data: PackedByteArray, key: String) -> void:
	if not _remesh.is_empty():
		_remesh[key] = data


## The landed arrays into the chunk's node (made under chunk_root on its first landing), the whole timed into
## the node's build_ms; the mask follows a mesh appearing or going empty.
func _land_chunk(ch: Vector2i, vdata: PackedByteArray, idata: PackedByteArray) -> void:
	var t := Time.get_ticks_usec()
	var st: Dictionary = touched[ch]
	if st.node == null:
		st.node = ChunkMesh.new(chunk_material)
		chunk_root.add_child(st.node)
	var f := vdata.to_float32_array()
	@warning_ignore("integer_division")
	var n := f.size() / 8
	var vs := PackedVector3Array()
	var ns := PackedVector3Array()
	var cs := PackedColorArray()
	vs.resize(n)
	ns.resize(n)
	cs.resize(n)
	for i in n:
		var o := i * 8
		vs[i] = Vector3(f[o], f[o + 1], f[o + 2])
		ns[i] = Vector3(f[o + 4], f[o + 5], f[o + 6])
		cs[i] = Color(f[o + 3] / 255.0, f[o + 7], 0.0, 1.0)
	var had: bool = st.node.faces > 0
	st.node.set_arrays(vs, ns, cs, idata.to_int32_array() if vs.size() > 0 else PackedInt32Array())
	st.node.build_ms = (Time.get_ticks_usec() - t) / 1000.0
	remeshes += 1
	if (st.node.faces > 0) != had:
		_set_mask(ch)


func _free_chunk(ch: Vector2i) -> void:
	var st: Dictionary = touched[ch]
	var drawn: bool = st.node != null and st.node.faces > 0
	if st.node != null:
		st.node.queue_free()
	touched.erase(ch)
	if drawn:
		_set_mask(ch)


## Uploads the mask of the chunks drawn and collided by their meshes (a byte per chunk slot of the window),
## then tells Terrain which chunk changed.
func _set_mask(changed: Vector2i) -> void:
	var bytes := PackedByteArray()
	bytes.resize(CHUNK_SLOTS)
	for ch: Vector2i in touched:
		if touched[ch].node != null and touched[ch].node.faces > 0:
			bytes[posmod(ch.y, 32) * 32 + posmod(ch.x, 32)] = 255
	var rid := window.texture_rid("chunk_mask")
	RenderingServer.call_on_render_thread(func() -> void: _rd.texture_update(rid, 0, bytes))
	if on_mask_changed.is_valid():
		on_mask_changed.call(changed)


## The two dispatches of box_mesh.glsl over a chunk, timed, and the readbacks of their counts and arrays
## (whole: they land in one flush).
func _mesh_rd(pc0: PackedByteArray, pc1: PackedByteArray) -> void:
	if not _mesh_set.is_valid():
		return
	_rd.buffer_clear(_mesh_counts, 0, 16)
	_rd.capture_timestamp("box_mesh_begin")
	var list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list, _mesh_pipeline)
	_rd.compute_list_bind_uniform_set(list, _mesh_set, 0)
	_rd.compute_list_set_push_constant(list, pc0, pc0.size())
	_rd.compute_list_dispatch(list, 3, 3, BRICKS_UP * BRICK / 4)
	_rd.compute_list_add_barrier(list)
	_rd.compute_list_set_push_constant(list, pc1, pc1.size())
	_rd.compute_list_dispatch(list, 3, 3, BRICKS_UP * BRICK / 4)
	_rd.compute_list_end()
	_rd.capture_timestamp("box_mesh_end")
	for r: Array in [[_mesh_counts, "counts", 16], [_mesh_verts, "verts", MESH_VERTS * 32], [_mesh_inds, "inds", MESH_INDS * 4]]:
		var err := _rd.buffer_get_data_async(r[0], _on_mesh_data.bind(r[1]), 0, r[2])
		if err != OK:
			push_error("chunk mesh readback: %s" % error_string(err))


## The Params block of box_mesh.glsl (std430, MESH_PC_BYTES) for a chunk, its first cell in the origin's frame.
func _mesh_pc(ch: Vector2i, mode: int) -> PackedByteArray:
	var x0 := _origin.x * BRICK
	var b := PackedByteArray()
	b.resize(MESH_PC_BYTES)
	b.encode_s32(0, _origin.x)
	b.encode_s32(4, _origin.y)
	b.encode_s32(8, _origin.z)
	b.encode_s32(12, mode)
	b.encode_s32(16, x0 + posmod(ch.x * CHUNK - x0, params.n_theta()))
	b.encode_s32(20, ch.y * CHUNK)
	b.encode_s32(24, params.n_theta())
	@warning_ignore("integer_division")
	b.encode_s32(28, params.n_theta() / BRICK)
	b.encode_float(32, params.radius)
	b.encode_float(36, params.dtheta())
	b.encode_float(40, -params.length / 2.0)
	b.encode_s32(44, MESH_VERTS)
	b.encode_s32(48, MESH_INDS)
	return b
