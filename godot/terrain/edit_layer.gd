## The edit layer of a TerrainWindow (the terrain edits plan, decisions 1 to 4): edits are absolute per-cell
## overrides, kept per edited tile as one dense blob of all ten window fields plus the edit mask, and moved
## only by edit.glsl. A stamp edits the live window and marks edit_mask; a pack in the same compute list
## copies each touched tile into a slot of a download buffer, read back into `blobs` a few frames later; an
## apply copies a tile's blob over the detail pass's output whenever the tile enters the window, so an edit
## survives the window scrolling away and back. Blobs move as whole PackedByteArrays, never looped here.
## Limit (decision 4): a stamped tile evicted and re-entered before its readback lands gets its old blob.
class_name EditLayer
extends RefCounted

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
	# Binding 0 _up, 1 _down, 2..12 the window's fields in FIELDS order.
	var uniforms: Array[RDUniform] = []
	for i in 2 + TerrainWindow.FIELDS.size():
		var u := RDUniform.new()
		u.binding = i
		if i < 2:
			u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
			u.add_id(_up if i == 0 else _down)
		else:
			u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
			u.add_id(window.texture_rid(TerrainWindow.FIELDS[i - 2]))
		uniforms.append(u)
	_set = _rd.uniform_set_create(uniforms, _shader, 0)


func _notification(what: int) -> void:
	if what != NOTIFICATION_PREDELETE or _rd == null:
		return
	# Freeing the shader frees its pipeline and uniform set.
	var rids: Array[RID] = [_shader, _up, _down]
	RenderingServer.call_on_render_thread(TerrainWindow._free_rids.bind(_rd, rids))


## Stamps a disc of `radius` cells around cell (theta wrapped) by dh m at its centre into the live window,
## then packs every tile it touched and reads them back into `blobs`. Every tile of
## stamp_tiles(window, cell, radius) must be resident (Terrain.edit checks).
func stamp(window: TerrainWindow, cell: Vector2i, radius: int, dh: float) -> void:
	var tiles := stamp_tiles(window, cell, radius)
	# Built here, so the residency the shader tests is the window's as of this call.
	var blocks: Array[PackedByteArray] = [_params(window, 0, cell, Vector2i.ZERO, 0, radius, dh)]
	for k in tiles.size():
		blocks.append(_params(window, 1, cell, tiles[k], k, radius, dh))
	RenderingServer.call_on_render_thread(_stamp_rd.bind(tiles, blocks, ceili((2 * radius + 1) / 8.0)))


func _stamp_rd(tiles: Array[Vector2i], blocks: Array[PackedByteArray], groups: int) -> void:
	if not _set.is_valid():
		return
	_rd.capture_timestamp("edit_begin")
	var list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list, _pipeline)
	_rd.compute_list_bind_uniform_set(list, _set, 0)
	_rd.compute_list_set_push_constant(list, blocks[0], blocks[0].size())
	_rd.compute_list_dispatch(list, groups, groups, 1)
	# The pack must see the stamp's stores.
	_rd.compute_list_add_barrier(list)
	for k in tiles.size():
		_rd.compute_list_set_push_constant(list, blocks[k + 1], blocks[k + 1].size())
		@warning_ignore("integer_division")
		_rd.compute_list_dispatch(list, TerrainWindow.TILE / 8, TerrainWindow.TILE / 8, 1)
	_rd.compute_list_end()
	_rd.capture_timestamp("edit_end")
	# After the list ends: requested inside it, the readback would read stale data.
	for k in tiles.size():
		var err := _rd.buffer_get_data_async(_down, _packed.bind(tiles[k]), k * BLOB_SIZE, BLOB_SIZE)
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
		var pc := _params(window, 2, Vector2i.ZERO, t, 0, 0, 0.0)
		var list := _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(list, _pipeline)
		_rd.compute_list_bind_uniform_set(list, _set, 0)
		_rd.compute_list_set_push_constant(list, pc, pc.size())
		@warning_ignore("integer_division")
		_rd.compute_list_dispatch(list, TerrainWindow.TILE / 8, TerrainWindow.TILE / 8, 1)
		_rd.compute_list_end()
	_rd.capture_timestamp("apply_end")


## The Params block of edit.glsl: std430, 64 bytes.
func _params(window: TerrainWindow, mode: int, cell: Vector2i, tile: Vector2i, slot: int, radius: int, dh: float) -> PackedByteArray:
	var p := window.params
	var first := window.wanted_origin(window.center_tile)
	var b := PackedByteArray()
	b.resize(64)
	b.encode_s32(0, cell.x)
	b.encode_s32(4, cell.y)
	b.encode_s32(8, first.x)
	b.encode_s32(12, first.y)
	b.encode_s32(16, tile.x)
	b.encode_s32(20, tile.y)
	b.encode_s32(24, p.n_theta())
	b.encode_s32(28, window.tiles_around)
	b.encode_s32(32, window.slots)
	b.encode_s32(36, mode)
	b.encode_s32(40, radius)
	b.encode_s32(44, slot)
	b.encode_float(48, dh)
	b.encode_float(52, p.h_sea + p.h_mtn())
	return b


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
