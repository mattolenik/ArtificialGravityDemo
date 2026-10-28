## The edit layer of a TerrainWindow (the terrain edits plan, decisions 1 to 4): edits are absolute per-cell
## overrides, kept per edited tile as one dense blob of all ten window fields plus the edit mask, and moved
## only by edit.glsl. A stamp edits the live window and marks edit_mask; a pack in the same compute list
## copies each touched tile into a slot of a download buffer, read back into `blobs` a few frames later; an
## apply copies a tile's blob over the detail pass's output whenever the tile enters the window, so an edit
## survives the window scrolling away and back. Blobs move as whole PackedByteArrays, never looped here.
## Limit (decision 4): a stamped tile evicted and re-entered before its readback lands gets its old blob.
## Slice 3 adds the tool stamps (stamp_op: bore, deposit, push, tamp, spill), a bore counter read back after
## each counted stamp, and a stats buffer of one activity flag per window slot for TerrainSim.
class_name EditLayer
extends RefCounted

## The modes of edit.glsl.
const MODE_RAISE := 0
const MODE_PACK := 1
const MODE_APPLY := 2
const MODE_BORE := 3
const MODE_DEPOSIT := 4
const MODE_PUSH := 5
const MODE_TAMP := 6
const MODE_SPILL := 7

## Per cell: five float32 heights (surface, bedrock_top, clay_bottom, clay_top, water_surface), then one
## uint32 material | compaction << 8 | saturation << 16 | mask << 24; mask 255 where edited, else 0; then
## float32 loose and water_depth.
const CELL_BYTES := 32
const BLOB_SIZE := TerrainWindow.TILE * TerrainWindow.TILE * CELL_BYTES
## A version 1 blob's cell: the first 24 bytes of this one, no loose or water_depth.
const V1_CELL_BYTES := 24
const V1_BLOB_SIZE := TerrainWindow.TILE * TerrainWindow.TILE * V1_CELL_BYTES
## Tiles one stamp can touch, radius at most 64 cells (Terrain.edit refuses more): the download buffer's slots.
const DOWN_SLOTS := 4

## One stamp of edit.glsl, for stamp_op. `amount` is: raise, m at the centre; bore, the step in m; deposit and
## spill, m³; push, the share; tamp, the compaction step. `limit` is: bore, the pump's m³ per tick; push, the
## cap in m per cell; tamp, the swell. Bore and push read other cells than their own, so they must fit one
## 8 x 8 workgroup: reach() at most 3.
class Op extends RefCounted:
	var cell: Vector2i
	var radius: int
	var mode: int
	var amount := 0.0
	## Push: the axis step toward the cell ahead.
	var dir := Vector2i.ZERO
	var limit := 0.0
	## Push: nothing moves into a cell within obstacle_radius cells of obstacle; no obstacle when negative.
	var obstacle := Vector2i(-1, -1)
	var obstacle_radius := -1
	## Whether the stamp packs its tiles into `blobs` (tool stamps leave that to the settle pack).
	var pack := true
	## Bore: called with (volume_m3, wet) when the counter lands, inside the readback flush (store only).
	var counted := Callable()

	## Cells from `cell` the stamp writes: a push also fills the ring just past its disc.
	func reach() -> int:
		return radius + 1 if mode == MODE_PUSH else radius


## Wrapped tile -> PackedByteArray of BLOB_SIZE: the tile as last packed.
var blobs := {}
## The tiles in blobs that were packed since Terrain last saved them (a set: tile -> true).
var unsaved := {}

var _rd: RenderingDevice
var _shader: RID
var _pipeline: RID
## One blob for the apply pass, and DOWN_SLOTS for the pack pass.
var _up: RID
var _down: RID
## The bore counter: m³ cut or lifted in units of 1e-6, then 1 when a tick pumped.
var _counter: RID
## One activity flag per window slot, then the reservoirs' absorbed water (TerrainSim's).
var _stats: RID
var _stats_size := 0
var _set: RID


## Compiles edit.glsl and builds its buffers and uniform set over window's textures, on the render thread.
## Call right after window.setup.
func setup(window: TerrainWindow) -> void:
	RenderingServer.call_on_render_thread(_setup_rd.bind(window))


func _setup_rd(window: TerrainWindow) -> void:
	if window._textures.is_empty():
		push_error("EditLayer.setup: the window has no textures (its setup failed)")
		return
	_rd = RenderingServer.get_rendering_device()
	var spirv: RDShaderSPIRV = load("res://terrain/shaders/edit.glsl").get_spirv()
	if spirv.compile_error_compute != "":
		push_error("edit.glsl: %s" % spirv.compile_error_compute)
		return
	_shader = _rd.shader_create_from_spirv(spirv)
	_pipeline = _rd.compute_pipeline_create(_shader)
	if not _pipeline.is_valid():
		push_error("edit.glsl: pipeline creation failed")
		return
	_up = _rd.storage_buffer_create(BLOB_SIZE)
	_down = _rd.storage_buffer_create(BLOB_SIZE * DOWN_SLOTS)
	var zeros := PackedByteArray()
	zeros.resize(8)
	_counter = _rd.storage_buffer_create(8, zeros)
	_stats_size = (window.slots * window.slots + 1) * 4
	zeros.resize(_stats_size)
	_stats = _rd.storage_buffer_create(_stats_size, zeros)
	# Binding 0 _up, 1 _down, 2..12 the window's fields in FIELDS order, 13 _counter, 14 _stats.
	var buffers := {0: _up, 1: _down, 13: _counter, 14: _stats}
	var uniforms: Array[RDUniform] = []
	for i in 2 + TerrainWindow.FIELDS.size() + 2:
		var u := RDUniform.new()
		u.binding = i
		if buffers.has(i):
			u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
			u.add_id(buffers[i])
		else:
			u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
			u.add_id(window.texture_rid(TerrainWindow.FIELDS[i - 2]))
		uniforms.append(u)
	_set = _rd.uniform_set_create(uniforms, _shader, 0)


## The stats buffer (bound at 14 here; TerrainSim binds it too) and its size in bytes, (slots² + 1) · 4.
func stats_rid() -> RID:
	return _stats


func stats_size() -> int:
	return _stats_size


func _notification(what: int) -> void:
	if what != NOTIFICATION_PREDELETE or _rd == null:
		return
	# Freeing the shader frees its pipeline and uniform set.
	var rids: Array[RID] = [_shader, _up, _down, _counter, _stats]
	RenderingServer.call_on_render_thread(TerrainWindow._free_rids.bind(_rd, rids))


## Stamps a disc of `radius` cells around cell (theta wrapped) by dh m at its centre into the live window,
## then packs every tile it touched and reads them back into `blobs`. Every tile of
## stamp_tiles(window, cell, radius) must be resident (Terrain.edit checks).
func stamp(window: TerrainWindow, cell: Vector2i, radius: int, dh: float) -> void:
	var op := Op.new()
	op.cell = cell
	op.radius = radius
	op.mode = MODE_RAISE
	op.amount = dh
	stamp_op(window, op)


## Runs one stamp into the live window in one compute list: the stamp over the box of op.reach() cells
## around op.cell, then, when op.pack, a pack of every tile of that box read back into `blobs`. A counted op
## (a bore) clears the counter before the list and reads it back into op.counted after it. Every tile of the
## box must be resident (Terrain.can_stamp checks).
func stamp_op(window: TerrainWindow, op: Op) -> void:
	assert(op.mode not in [MODE_BORE, MODE_PUSH] or box_groups(op.reach()) == 1, "a bore or push must fit one workgroup")
	var tiles: Array[Vector2i] = []
	if op.pack:
		tiles = stamp_tiles(window, op.cell, op.reach())
	# Built here, so the residency the shader tests is the window's as of this call.
	var blocks: Array[PackedByteArray] = [_params(window, op, Vector2i.ZERO, disc_cells(op.radius))]
	for k in tiles.size():
		blocks.append(_tile_params(window, MODE_PACK, tiles[k], k))
	RenderingServer.call_on_render_thread(_stamp_rd.bind(tiles, blocks, box_groups(op.reach()), op.counted))


func _stamp_rd(tiles: Array[Vector2i], blocks: Array[PackedByteArray], groups: int, counted: Callable) -> void:
	if not _set.is_valid():
		return
	# Before the list: buffer_clear, like buffer_update, is refused inside one.
	if counted.is_valid():
		_rd.buffer_clear(_counter, 0, 8)
	_rd.capture_timestamp("edit_begin")
	var list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list, _pipeline)
	_rd.compute_list_bind_uniform_set(list, _set, 0)
	_rd.compute_list_set_push_constant(list, blocks[0], blocks[0].size())
	_rd.compute_list_dispatch(list, groups, groups, 1)
	if not tiles.is_empty():
		# The pack must see the stamp's stores.
		_rd.compute_list_add_barrier(list)
		_pack_dispatches(list, blocks, 1, tiles.size())
	_rd.compute_list_end()
	_rd.capture_timestamp("edit_end")
	# After the list ends: requested inside it, the readback would read stale data.
	_read_back(tiles, 0, tiles.size())
	if counted.is_valid():
		var err := _rd.buffer_get_data_async(_counter, _counted.bind(counted), 0, 8)
		if err != OK:
			push_error("bore counter readback: %s" % error_string(err))


## Runs inside the device's readback flush: hands the counter, m³ and whether the tick pumped, to cb, which
## must only store them. A cb whose object was freed while the readback was in flight is dropped.
func _counted(data: PackedByteArray, cb: Callable) -> void:
	if not cb.is_valid():
		return
	cb.call(data.decode_u32(0) * 1e-6, data.decode_u32(4) != 0)


## Packs `tiles` (resident) into `blobs`: lists of at most DOWN_SLOTS pack dispatches, each list's readbacks
## requested right after it. A readback copies `_down` when it is requested, so the next list reuses the slots.
func pack_tiles(window: TerrainWindow, tiles: Array[Vector2i]) -> void:
	if not tiles.is_empty():
		RenderingServer.call_on_render_thread(_pack_rd.bind(tiles, _pack_blocks(window, tiles), false))


## pack_tiles with synchronous readbacks: `blobs` holds every tile when it returns (Terrain._exit_tree).
func pack_tiles_sync(window: TerrainWindow, tiles: Array[Vector2i]) -> void:
	if not tiles.is_empty():
		RenderingServer.call_on_render_thread(_pack_rd.bind(tiles, _pack_blocks(window, tiles), true))


func _pack_blocks(window: TerrainWindow, tiles: Array[Vector2i]) -> Array[PackedByteArray]:
	var blocks: Array[PackedByteArray] = []
	for k in tiles.size():
		blocks.append(_tile_params(window, MODE_PACK, tiles[k], k % DOWN_SLOTS))
	return blocks


func _pack_rd(tiles: Array[Vector2i], blocks: Array[PackedByteArray], sync: bool) -> void:
	if not _set.is_valid():
		return
	for start in range(0, tiles.size(), DOWN_SLOTS):
		var n := mini(DOWN_SLOTS, tiles.size() - start)
		_rd.capture_timestamp("pack_begin")
		var list := _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(list, _pipeline)
		_rd.compute_list_bind_uniform_set(list, _set, 0)
		_pack_dispatches(list, blocks, start, n)
		_rd.compute_list_end()
		_rd.capture_timestamp("pack_end")
		if not sync:
			_read_back(tiles, start, n)
			continue
		for k in n:
			_packed(_rd.buffer_get_data(_down, k * BLOB_SIZE, BLOB_SIZE), tiles[start + k])


## The pack dispatches of blocks[start] .. blocks[start + n - 1], each into the slot its block names.
func _pack_dispatches(list: int, blocks: Array[PackedByteArray], start: int, n: int) -> void:
	for k in range(start, start + n):
		_rd.compute_list_set_push_constant(list, blocks[k], blocks[k].size())
		@warning_ignore("integer_division")
		_rd.compute_list_dispatch(list, TerrainWindow.TILE / 8, TerrainWindow.TILE / 8, 1)


## Asks for slots 0 .. n - 1 of `_down` as the blobs of tiles[start] .. tiles[start + n - 1].
func _read_back(tiles: Array[Vector2i], start: int, n: int) -> void:
	for k in n:
		var err := _rd.buffer_get_data_async(_down, _packed.bind(tiles[start + k]), k * BLOB_SIZE, BLOB_SIZE)
		if err != OK:
			push_error("edit pack readback: %s" % error_string(err))


## Runs inside the device's readback flush, where nothing may be dispatched: stores the blob only.
func _packed(data: PackedByteArray, tile: Vector2i) -> void:
	if data.size() == BLOB_SIZE:
		blobs[tile] = data
		unsaved[tile] = true
	else:
		push_error("edit pack readback: %d bytes, expected %d" % [data.size(), BLOB_SIZE])


## Copies the blob of each of `tiles` that has one over the window, after the detail pass has written them.
## On the render thread, from TerrainWindow._dispatch, after its compute list: buffer_update is refused
## inside a list, so each tile is its own short list.
func apply_entering(window: TerrainWindow, tiles: Array[Vector2i]) -> void:
	if not _set.is_valid():
		return
	var edited := tiles.filter(func(t: Vector2i) -> bool: return blobs.has(t))
	if edited.is_empty():
		return
	_rd.capture_timestamp("apply_begin")
	for t: Vector2i in edited:
		_rd.buffer_update(_up, 0, BLOB_SIZE, blobs[t])
		var pc := _tile_params(window, MODE_APPLY, t, 0)
		var list := _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(list, _pipeline)
		_rd.compute_list_bind_uniform_set(list, _set, 0)
		_rd.compute_list_set_push_constant(list, pc, pc.size())
		@warning_ignore("integer_division")
		_rd.compute_list_dispatch(list, TerrainWindow.TILE / 8, TerrainWindow.TILE / 8, 1)
		_rd.compute_list_end()
	_rd.capture_timestamp("apply_end")


## The Params block of edit.glsl (std430, 96 bytes) for op. `slot` is the slot of `_down` for a pack and the
## disc's cell count (disc_cells) for a stamp.
func _params(window: TerrainWindow, op: Op, tile: Vector2i, slot: int) -> PackedByteArray:
	var p := window.params
	var first := window.wanted_origin(window.center_tile)
	var b := PackedByteArray()
	b.resize(96)
	b.encode_s32(0, op.cell.x)
	b.encode_s32(4, op.cell.y)
	b.encode_s32(8, first.x)
	b.encode_s32(12, first.y)
	b.encode_s32(16, tile.x)
	b.encode_s32(20, tile.y)
	b.encode_s32(24, p.n_theta())
	b.encode_s32(28, window.slots)
	b.encode_s32(32, op.mode)
	b.encode_s32(36, op.radius)
	b.encode_s32(40, slot)
	b.encode_s32(44, op.obstacle_radius)
	b.encode_s32(48, op.dir.x)
	b.encode_s32(52, op.dir.y)
	b.encode_s32(56, op.obstacle.x)
	b.encode_s32(60, op.obstacle.y)
	b.encode_float(64, op.amount)
	b.encode_float(68, op.limit)
	b.encode_float(72, p.h_sea + p.h_mtn())
	b.encode_float(76, p.radius)
	b.encode_float(80, p.dtheta())
	return b


## The Params block of a pack or apply dispatch over `tile`.
func _tile_params(window: TerrainWindow, mode: int, tile: Vector2i, slot: int) -> PackedByteArray:
	var op := Op.new()
	op.mode = mode
	return _params(window, op, tile, slot)


## The cells of a disc of `radius`: the integer offsets (x, y) with x² + y² <= radius², edit.glsl's test.
static func disc_cells(radius: int) -> int:
	var n := 0
	for y in range(-radius, radius + 1):
		for x in range(-radius, radius + 1):
			n += int(x * x + y * y <= radius * radius)
	return n


## Workgroups per axis of a stamp over the box of `reach` cells around its centre (8 x 8 per group).
static func box_groups(reach: int) -> int:
	return ceili((2 * reach + 1) / 8.0)


## The distinct tiles of the box [cell.x - radius, cell.x + radius] x [cell.y - radius, cell.y + radius],
## rows clamped to the station and theta wrapped: 1 to 4 for a radius of at most 64, up to 9 beyond.
static func stamp_tiles(window: TerrainWindow, cell: Vector2i, radius: int) -> Array[Vector2i]:
	var span := float(TerrainWindow.TILE)
	var out: Array[Vector2i] = []
	for tj in range(floori(maxi(cell.y - radius, 0) / span), floori(mini(cell.y + radius, window.params.n_z() - 1) / span) + 1):
		for ti in range(floori((cell.x - radius) / span), floori((cell.x + radius) / span) + 1):
			var t := Vector2i(TerrainWindow.wrap_tile(ti, window.tiles_around), tj)
			if not out.has(t):
				out.append(t)
	return out


## A version 1 blob (V1_BLOB_SIZE) in this layout: each cell's 24 bytes, then loose and water_depth 0.
## Load time only (WorldIO.load_edits), so it may loop over the cells.
static func upgrade_v1(blob: PackedByteArray) -> PackedByteArray:
	var pad := PackedByteArray()
	pad.resize(CELL_BYTES - V1_CELL_BYTES)
	var out := PackedByteArray()
	for o in range(0, blob.size(), V1_CELL_BYTES):
		out.append_array(blob.slice(o, o + V1_CELL_BYTES))
		out.append_array(pad)
	return out


## Byte offset of cell (i, j) of a tile in its blob.
static func cell_offset(i: int, j: int) -> int:
	return (j * TerrainWindow.TILE + i) * CELL_BYTES


## Cell (i, j) of a blob, by field name, the bytes as 0..255. A test and debug helper.
static func decode(blob: PackedByteArray, i: int, j: int) -> Dictionary:
	var o := cell_offset(i, j)
	var w := blob.decode_u32(o + 20)
	return {"surface": blob.decode_float(o), "bedrock_top": blob.decode_float(o + 4), "clay_bottom": blob.decode_float(o + 8),
			"clay_top": blob.decode_float(o + 12), "water_surface": blob.decode_float(o + 16),
			"material": w & 255, "compaction": (w >> 8) & 255, "saturation": (w >> 16) & 255, "mask": w >> 24,
			"loose": blob.decode_float(o + 24), "water_depth": blob.decode_float(o + 28)}
