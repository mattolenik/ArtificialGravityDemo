## The fine-resolution window around the viewer: one RenderingDevice texture per field on the main
## device, addressed toroidally in 128-cell tiles (tile (ti, tj) lives in slot (ti mod slots, tj mod
## slots)), filled on the GPU by detail.glsl from the macro maps whenever a tile enters. `cell` is the
## window's cell size in m: 1 for the main window, 8 for the far ring's. configure() is arithmetic only
## (headless-safe); setup() is the only RenderingDevice entry point.
class_name TerrainWindow
extends RefCounted

## Emitted by move_to with the tiles it dispatched, after queueing the dispatch.
signal tiles_generated(tiles: Array[Vector2i])

const FIELDS := ["surface", "bedrock_top", "clay_bottom", "clay_top", "water_surface", "material", "compaction", "saturation"]
const TILE := 128
## Heights are R32_SFLOAT metres above the hull, so a texel times HEIGHT_SCALE is metres.
const HEIGHT_SCALE := 1.0
## Macro images uploaded for detail.glsl, in its set 0 binding order.
const MACRO := ["surface", "bedrock_top", "clay_bottom", "clay_top", "water_surface", "region", "cliff", "river", "flow_dir"]

var params: WorldParams
var maps: MacroMaps
## Window side in cells, and cell size in m.
var size: int
var cell: float
var tiles_around: int
var tiles_along: int
var slots: int
## The tile move_to last centred the window on.
var center_tile: Vector2i

var _rd: RenderingDevice
var _textures := {}  # field -> RID
var _wrappers := {}  # field -> Texture2DRD
var _macro: Array[RID] = []
var _sampler: RID
var _shader: RID
var _pipeline: RID
var _sets: Array[RID] = []
var _resident := {}  # slot -> tile


## Tile counts for a window of `size` cells at `cell` m. No GPU work.
func configure(p: WorldParams, window_size: int = 512, cell_size: float = 1.0) -> void:
	params = p
	size = window_size
	cell = cell_size
	var span := TILE * int(cell_size)
	@warning_ignore("integer_division")
	tiles_around = p.n_theta() / span
	@warning_ignore("integer_division")
	tiles_along = p.n_z() / span
	@warning_ignore("integer_division")
	slots = window_size / TILE


## Creates the window textures, uploads the macro maps, compiles detail.glsl and builds its uniform
## sets, on the render thread.
func setup(p: WorldParams, m: MacroMaps, window_size: int = 512, cell_size: float = 1.0) -> void:
	configure(p, window_size, cell_size)
	maps = m
	_resident.clear()
	RenderingServer.call_on_render_thread(_setup_rd)


func _setup_rd() -> void:
	_rd = RenderingServer.get_rendering_device()
	var spirv: RDShaderSPIRV = load("res://terrain/shaders/detail.glsl").get_spirv()
	if spirv.compile_error_compute != "":
		push_error("detail.glsl: %s" % spirv.compile_error_compute)
		return
	_shader = _rd.shader_create_from_spirv(spirv)
	if not _shader.is_valid():
		push_error("detail.glsl: shader creation failed")
		return
	_pipeline = _rd.compute_pipeline_create(_shader)
	if not _pipeline.is_valid():
		push_error("detail.glsl: pipeline creation failed")
		return
	var ss := RDSamplerState.new()
	ss.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	ss.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	ss.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	ss.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_sampler = _rd.sampler_create(ss)
	var macro_uniforms: Array[RDUniform] = []
	for name: String in MACRO:
		var img: Image = maps.get(name)
		var format := RenderingDevice.DATA_FORMAT_R32_SFLOAT
		if img.get_format() == Image.FORMAT_R8:
			format = RenderingDevice.DATA_FORMAT_R8_UNORM
		elif img.get_format() == Image.FORMAT_RGBF:
			img = img.duplicate()  # Metal has no 3-channel 32-bit float format
			img.convert(Image.FORMAT_RGBAF)
			format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
		var rid := _rd.texture_create(_format(img.get_width(), img.get_height(), format, RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT), RDTextureView.new(), [img.get_data()])
		_macro.append(rid)
		var u := RDUniform.new()
		u.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		u.binding = macro_uniforms.size()
		u.add_id(_sampler)
		u.add_id(rid)
		macro_uniforms.append(u)
	var usage := RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
	var window_uniforms: Array[RDUniform] = []
	for i in FIELDS.size():
		var format := RenderingDevice.DATA_FORMAT_R32_SFLOAT if i < 5 else RenderingDevice.DATA_FORMAT_R8_UNORM
		var rid := _rd.texture_create(_format(size, size, format, usage), RDTextureView.new())
		_textures[FIELDS[i]] = rid
		var u := RDUniform.new()
		u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		u.binding = i
		u.add_id(rid)
		window_uniforms.append(u)
	_sets = [_rd.uniform_set_create(macro_uniforms, _shader, 0), _rd.uniform_set_create(window_uniforms, _shader, 1)]


func _notification(what: int) -> void:
	if what != NOTIFICATION_PREDELETE or _rd == null:
		return
	for t: Texture2DRD in _wrappers.values():
		t.texture_rd_rid = RID()
	# Freeing the shader frees its pipeline and uniform sets.
	var rids: Array[RID] = [_shader, _sampler]
	rids.append_array(_textures.values())
	rids.append_array(_macro)
	RenderingServer.call_on_render_thread(_free_rids.bind(_rd, rids))


static func _free_rids(rd: RenderingDevice, rids: Array[RID]) -> void:
	for rid in rids:
		if rid.is_valid():
			rd.free_rid(rid)


func _format(w: int, h: int, format: RenderingDevice.DataFormat, usage: int) -> RDTextureFormat:
	var f := RDTextureFormat.new()
	f.width = w
	f.height = h
	f.format = format
	f.usage_bits = usage
	return f


## The window texture of `field`, wrapped for materials.
func texture_rd(field: String) -> Texture2DRD:
	if not _wrappers.has(field):
		var t := Texture2DRD.new()
		t.texture_rd_rid = _textures[field]
		_wrappers[field] = t
	return _wrappers[field]


func texture_rid(field: String) -> RID:
	return _textures[field]


## The macro map `field` as uploaded for detail.glsl, and the sampler bound with it (linear, theta
## repeats, z clamps).
func macro_rid(field: String) -> RID:
	return _macro[MACRO.find(field)]


func macro_sampler() -> RID:
	return _sampler


static func wrap_tile(ti: int, around: int) -> int:
	return posmod(ti, around)


func slot_of(tile: Vector2i) -> Vector2i:
	return Vector2i(posmod(tile.x, slots), posmod(tile.y, slots))


## Texel of the tile's first cell inside the window textures.
func texel_origin(tile: Vector2i) -> Vector2i:
	return slot_of(tile) * TILE


## The tile holding 1 m cell (i, j): i wraps around the circumference, j clamps to the station.
func tile_of_cell(i: int, j: int) -> Vector2i:
	var span := TILE * int(cell)
	@warning_ignore("integer_division")
	return Vector2i(posmod(i, params.n_theta()) / span, clampi(floori(j / float(span)), 0, tiles_along - 1))


## (theta, z) of the tile's centre.
func tile_center(tile: Vector2i) -> Vector2:
	var half := (TILE / 2.0) * cell
	return Vector2((tile.x * TILE * cell + half) * params.dtheta(), -params.length / 2.0 + tile.y * TILE * cell + half)


## The first tile of the wanted set around center: offset -slots/2 in theta, wrapped, and along z slid so
## the set stays within [0, tiles_along).
func wanted_origin(center: Vector2i) -> Vector2i:
	@warning_ignore("integer_division")
	var half := slots / 2
	return Vector2i(wrap_tile(center.x - half, tiles_around), clampi(center.y - half, 0, maxi(tiles_along - slots, 0)))


## The slots x slots tiles from wanted_origin(center) on, theta wrapped.
func wanted_tiles(center: Vector2i) -> Array[Vector2i]:
	var o := wanted_origin(center)
	var out: Array[Vector2i] = []
	for y in range(o.y, mini(o.y + slots, tiles_along)):
		for dx in slots:
			out.append(Vector2i(wrap_tile(o.x + dx, tiles_around), y))
	return out


## Brings the window to the tiles around center, generating every tile that is new to its slot
## in one compute list on the render thread.
func move_to(center: Vector2i) -> void:
	if not _pipeline.is_valid():
		push_error("TerrainWindow.move_to: no detail pipeline (setup not run or failed)")
		return
	center_tile = center
	var dirty: Array[Vector2i] = []
	for t in wanted_tiles(center):
		var s := slot_of(t)
		if _resident.get(s) != t:
			_resident[s] = t
			dirty.append(t)
	if dirty.is_empty():
		return
	RenderingServer.call_on_render_thread(_dispatch.bind(dirty))
	tiles_generated.emit(dirty)


func resident_tiles() -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	out.assign(_resident.values())
	return out


func _dispatch(tiles: Array[Vector2i]) -> void:
	var list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list, _pipeline)
	_rd.compute_list_bind_uniform_set(list, _sets[0], 0)
	_rd.compute_list_bind_uniform_set(list, _sets[1], 1)
	# Tiles write disjoint texels, so their dispatches share the list without barriers.
	for t in tiles:
		var pc := _push_constants(t)
		_rd.compute_list_set_push_constant(list, pc, pc.size())
		@warning_ignore("integer_division")
		_rd.compute_list_dispatch(list, TILE / 8, TILE / 8, 1)
	_rd.compute_list_end()


## Matches the Params block in detail.glsl (std430, 64 bytes with its padding).
func _push_constants(tile: Vector2i) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(64)
	var origin := texel_origin(tile)
	b.encode_s32(0, tile.x)
	b.encode_s32(4, tile.y)
	b.encode_s32(8, origin.x)
	b.encode_s32(12, origin.y)
	b.encode_s32(16, params.n_theta())
	b.encode_s32(20, params.seed)
	b.encode_float(24, cell)
	b.encode_float(28, params.dtheta())
	b.encode_float(32, params.radius)
	b.encode_float(36, params.h_sea)
	b.encode_float(40, params.h_sea + params.h_mtn())
	b.encode_float(44, params.macro_cell)
	b.encode_float(48, params.bank_distance)
	b.encode_float(52, tan(deg_to_rad(params.bank_slope_deg)))
	b.encode_float(56, params.cliff_min)
	return b
