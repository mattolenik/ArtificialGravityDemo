## The ground collider around the viewer: one 257 x 257 heightfield at 1 m in the tangent frame of a
## cell centre (X spinward, Y toward the axis, Z axial, origin on the hull), with the cylinder's
## curvature baked in on the GPU by collider_bake.glsl from the window (the macro surface outside it) and
## read back asynchronously. map_data[j * 257 + i] is the height above that plane at x = i - 128,
## z = j - 128. A child of Terrain, so its space is station space. Loads headless: the RenderingDevice
## is touched only from rebuild().
class_name ColliderPatch
extends StaticBody3D

## A bake has landed: the shape and the frame now describe the ground around center (theta, z).
signal live(center: Vector2)

const SAMPLES := 257
## Rebuild once the viewer is this far from the centre, in m in the patch's plane.
const REBUILD_DISTANCE := 64.0
## The centre sample along each axis, (SAMPLES - 1) / 2.
const _MID := 128

## (theta, z) of the patch centre, a cell centre.
var center: Vector2

var _shape := HeightMapShape3D.new()
var _rd: RenderingDevice
var _shader: RID
var _pipeline: RID
var _staging: RID
var _set: RID
var _pending := false


func _init() -> void:
	_shape.map_width = SAMPLES
	_shape.map_depth = SAMPLES
	var c := CollisionShape3D.new()
	c.name = "CollisionShape3D"
	c.shape = _shape
	add_child(c)


func _notification(what: int) -> void:
	if what != NOTIFICATION_PREDELETE or _rd == null:
		return
	# Freeing the shader frees its pipeline and uniform set.
	var rids: Array[RID] = [_shader, _staging]
	RenderingServer.call_on_render_thread(TerrainWindow._free_rids.bind(_rd, rids))


## Puts the patch's frame on the hull of radius R at (theta, z), and makes that its centre.
func set_frame(theta: float, z: float, R: float) -> void:
	center = Vector2(theta, z)
	transform = Transform3D(Basis(Vector3(cos(theta), sin(theta), 0), Vector3(-sin(theta), cos(theta), 0), Vector3(0, 0, 1)),
			Cyl.position(theta, z, 0, R))


## Whether a station-space point is more than REBUILD_DISTANCE from the centre in the patch's XZ plane.
func needs_rebuild(viewer_local: Vector3) -> bool:
	var p := transform.affine_inverse() * viewer_local
	return Vector2(p.x, p.z).length() > REBUILD_DISTANCE


## Height of the surface above the hull at the centre, from the last bake.
func center_height() -> float:
	return _shape.map_data[_MID * SAMPLES + _MID]


## Bakes the patch around the cell centre nearest (theta, z) from the window as it now stands; the shape
## and the frame change together when the readback lands, then `live` fires. While a bake is in flight
## this does nothing: the staging texture is still being read, and Terrain asks again every frame until
## the landed patch covers the viewer.
func rebuild(window: TerrainWindow, center_theta: float, center_z: float) -> void:
	if _pending:
		return
	_pending = true
	var p := window.params
	var cell := Vector2i(posmod(floori(center_theta / p.dtheta()), p.n_theta()), floori(center_z + p.length / 2.0))
	RenderingServer.call_on_render_thread(_bake.bind(window, cell))


func _bake(window: TerrainWindow, cell: Vector2i) -> void:
	# A failed setup leaves _pending set, so the error shows once and no bake is attempted again.
	if _rd == null and not _setup_rd(window):
		return
	var p := window.params
	var first := window.wanted_origin(window.center_tile)
	var b := PackedByteArray()
	b.resize(48)
	b.encode_s32(0, cell.x)
	b.encode_s32(4, cell.y)
	b.encode_s32(8, first.x)
	b.encode_s32(12, first.y)
	b.encode_s32(16, p.n_theta())
	b.encode_s32(20, window.tiles_around)
	b.encode_s32(24, window.slots)
	# Enough samples either side that the outermost reaches past x = 128 m even at the highest ground.
	b.encode_s32(28, ceili(asin(minf((_MID + 1.0) / (p.radius - p.h_sea - p.h_mtn()), 1.0)) / p.dtheta()))
	b.encode_float(32, p.dtheta())
	b.encode_float(36, p.radius)
	b.encode_float(40, p.macro_cell)
	_rd.capture_timestamp("bake_begin")
	var list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list, _pipeline)
	_rd.compute_list_bind_uniform_set(list, _set, 0)
	_rd.compute_list_set_push_constant(list, b, b.size())
	_rd.compute_list_dispatch(list, ceili(SAMPLES / 64.0), 1, 1)
	_rd.compute_list_end()
	_rd.capture_timestamp("bake_end")
	var theta := (cell.x + 0.5) * p.dtheta()
	var z := -p.length / 2.0 + cell.y + 0.5
	_rd.texture_get_data_async(_staging, 0, _landed.bind(theta, z, p.radius))


## Runs where RenderingDevice callbacks run: the main thread under the default thread model.
func _landed(data: PackedByteArray, theta: float, z: float, R: float) -> void:
	_shape.map_data = data.to_float32_array()
	set_frame(theta, z, R)
	_pending = false
	live.emit(center)


func _setup_rd(window: TerrainWindow) -> bool:
	_rd = RenderingServer.get_rendering_device()
	var spirv: RDShaderSPIRV = load("res://terrain/shaders/collider_bake.glsl").get_spirv()
	if spirv.compile_error_compute != "":
		push_error("collider_bake.glsl: %s" % spirv.compile_error_compute)
		return false
	_shader = _rd.shader_create_from_spirv(spirv)
	_pipeline = _rd.compute_pipeline_create(_shader)
	if not _pipeline.is_valid():
		push_error("collider_bake.glsl: pipeline creation failed")
		return false
	var f := RDTextureFormat.new()
	f.width = SAMPLES
	f.height = SAMPLES
	f.format = RenderingDevice.DATA_FORMAT_R32_SFLOAT
	f.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	_staging = _rd.texture_create(f, RDTextureView.new())
	var w := RDUniform.new()
	w.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	w.binding = 0
	w.add_id(window.texture_rid("surface"))
	var m := RDUniform.new()
	m.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	m.binding = 1
	m.add_id(window.macro_sampler())
	m.add_id(window.macro_rid("surface"))
	var o := RDUniform.new()
	o.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	o.binding = 2
	o.add_id(_staging)
	var uniforms: Array[RDUniform] = [w, m, o]
	_set = _rd.uniform_set_create(uniforms, _shader, 0)
	return true
