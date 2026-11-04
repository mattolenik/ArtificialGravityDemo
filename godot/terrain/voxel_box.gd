## The voxel box of the tunnels design: a 256 x 256 x 64 m box of 1 m voxels in cylindrical grid coordinates
## (theta index, z index, height index) around the player's feet, 24 m over them to 40 m under, in sparse
## bricks of 16³ voxels: a pool of POOL_BRICKS bricks in one storage buffer and an index of 16 x 16 x 4 brick
## slots (slot = brick mod (16, 16, 4), toroidal like the window's tiles) holding a pool brick only where a
## column has something in that 16 m. The box follows the feet by whole bricks (follow): the leaving bricks'
## dirty columns are packed into the window, the bricks freed, the entering columns unpacked from the resident
## window tiles (box_unpack.glsl: free, mark, allocate, fill); a column whose voxels an op changed is flagged
## dirty (one word per box column) and packed back by box_pack.glsl (pack_dirty, every frame something was
## changed, before TerrainSim steps): the window's surface, loose and gap fields stay current for the tiles,
## the collider, the water and the saves, and a column the box never changed keeps its floats bit for bit. A
## window-side stamp inside the box is followed by reload(cells). configure and the static helpers are
## arithmetic (headless-safe); setup is the RenderingDevice entry point. Drivers read bricks back with
## read_brick (synchronous).
class_name VoxelBox
extends RefCounted

const BRICK := 16
const BRICKS_ACROSS := 16
const BRICKS_UP := 4
## The box's height range from the feet: UP_ABOVE m over them, DOWN_BELOW m under.
const UP_ABOVE := 24
const DOWN_BELOW := 40
const BRICK_BYTES := BRICK * BRICK * BRICK * 8
const POOL_BRICKS := 1536
## Box columns per axis, and brick slots.
const COLUMNS := BRICKS_ACROSS * BRICK
const SLOTS := BRICKS_ACROSS * BRICKS_ACROSS * BRICKS_UP
## The origin of a box that does not exist yet.
const FAR := Vector3i(1 << 20, 1 << 20, 1 << 20)
## Cells one reload may list at once.
const LIST_MAX := 65536
## box_stats: one activity word per brick slot (Task 5), the pack's gap overflow count at SLOTS, the pool
## running dry at SLOTS + 1, then one word per 32 m chunk (Task 7).
const STATS_WORDS := SLOTS + 2 + 256
## The Params block of box_unpack.glsl and box_pack.glsl, std430.
const PC_BYTES := 80
const MODE_FREE := 0
const MODE_MARK := 1
const MODE_ALLOCATE := 2
const MODE_FILL := 3

var params: WorldParams
var window: TerrainWindow
var edits: EditLayer
var materials: MaterialSet
## Set by every op that changes voxels; pack_dirty dispatches the pack only then (nothing else sets dirty
## flags on the GPU).
var dirty_pending := false

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


## Arithmetic only.
func configure(p: WorldParams) -> void:
	params = p


## Creates the pool, the index, the free stack and the other buffers, compiles the two shaders and builds their
## sets over the window's fields and the edit layer's stats buffer, on the render thread. Call after
## edits.setup(window).
func setup(w: TerrainWindow, e: EditLayer, m: MaterialSet) -> void:
	configure(w.params)
	window = w
	edits = e
	materials = m
	RenderingServer.call_on_render_thread(_setup_rd)


func _setup_rd() -> void:
	if window._textures.is_empty() or not edits.stats_rid().is_valid():
		push_error("VoxelBox.setup: the window or its edit layer has no GPU resources (their setup failed)")
		return
	_rd = RenderingServer.get_rendering_device()
	_unpack_shader = _compile("res://terrain/shaders/box_unpack.glsl")
	_pack_shader = _compile("res://terrain/shaders/box_pack.glsl")
	if not _unpack_shader.is_valid() or not _pack_shader.is_valid():
		return
	_unpack_pipeline = _rd.compute_pipeline_create(_unpack_shader)
	_pack_pipeline = _rd.compute_pipeline_create(_pack_shader)
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
	_unpack_set = _uniform_set(_unpack_shader)
	_pack_set = _uniform_set(_pack_shader)


func _compile(path: String) -> RID:
	var spirv: RDShaderSPIRV = load(path).get_spirv()
	if spirv.compile_error_compute != "":
		push_error("%s: %s" % [path, spirv.compile_error_compute])
		return RID()
	return _rd.shader_create_from_spirv(spirv)


## Bindings 0 pool, 1 index, 2 dirty, 3 box_stats, 4 the edit layer's stats, 5 the free stack, 6 needed,
## 7 the cell list, then the window's fields in FIELDS order.
func _uniform_set(shader: RID) -> RID:
	var buffers: Array[RID] = [_pool, _index, _dirty, _box_stats, edits.stats_rid(), _free, _needed, _cells]
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


func _notification(what: int) -> void:
	if what != NOTIFICATION_PREDELETE or _rd == null:
		return
	var rids: Array[RID] = [_unpack_shader, _pack_shader, _pool, _index, _dirty, _box_stats, _free, _needed, _cells]
	RenderingServer.call_on_render_thread(TerrainWindow._free_rids.bind(_rd, rids))


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
## need; their dirty flags are dropped, the window being the truth. Cells outside the box are ignored.
func reload(cells: Array[Vector2i]) -> void:
	if cells.is_empty() or not exists():
		return
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
		_rd.capture_timestamp("box_unpack_begin")
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
		_rd.capture_timestamp("box_unpack_end")


## Packs every dirty column into the window fields (box_pack.glsl), when an op flagged any since the last
## call. From Terrain._process before sim.step.
func pack_dirty() -> void:
	if not dirty_pending or not exists():
		return
	dirty_pending = false
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
			"saturation": (w1 >> 16) & 255, "dirty": w1 >> 24}
