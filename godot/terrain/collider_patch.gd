## The ground collider around the viewer: one 257 x 257 heightfield at 1 m in the tangent frame of a
## cell centre (X spinward, Y toward the axis, Z axial, origin on the hull), with the cylinder's
## curvature baked in on the GPU by collider_bake.glsl from the window (the macro surface outside it) and
## read back asynchronously. map_data[j * 257 + i] is the height above that plane at x = i - 128,
## z = j - 128. The same body carries a second, 65 x 65 heightfield, EditShape, in the tangent frame of its
## own centre (edit_frame); while has_zone the big patch has a NaN hole HOLE_HALF cells either way of zone,
## which Jolt reads as no ground, so the edit shape is the ground there. A child of Terrain, so its space
## is station space. Loads headless: the RenderingDevice is touched only from rebuild() and issue_again().
##
## Issue order (decision 8 of the terrain edits plan): on_edit and the readback landings only set and clear
## flags; issue_again, every frame from Terrain._process, requests the edit bake for zone first and the big
## bake with its hole only once an edit bake for that zone has been requested. Readbacks land in request
## order, so the shape for a zone always lands before the hole for it.
class_name ColliderPatch
extends StaticBody3D

## A bake has landed: the shape and the frame now describe the ground around center (theta, z).
signal live(center: Vector2)
## A readback has landed: "big" or "edit", with the CPU time its map_data assignment (the Jolt build) took.
signal baked(kind: String, cpu_ms: float)

const SAMPLES := 257
const EDIT_SAMPLES := 65
## Rebuild once the viewer is this far from the centre, in m in the patch's plane.
const REBUILD_DISTANCE := 64.0
## The centre sample along each axis, (SAMPLES - 1) / 2, and the edit shape's.
const _MID := 128
const _EDIT_MID := 32
## The hole under the edit zone reaches this many cells either side of it along both axes.
const HOLE_HALF := 22
## An edit whose disc stays within HOLE_HALF - ZONE_MARGIN cells of the zone keeps the zone.
const ZONE_MARGIN := 4
const NO_HOLE := Vector2i(-1, -1)

## (theta, z) of the patch centre, a cell centre.
var center: Vector2
## The cell the edit shape is centred on; while has_zone, a big bake punches its hole there.
var zone: Vector2i
var has_zone := false
## The cell the live big patch's hole is centred on, NO_HOLE while it has none.
var hole_zone := NO_HOLE
## The tangent frame at the edit shape's centre, in station space.
var edit_frame: Transform3D

var _shape := HeightMapShape3D.new()
var _edit_node := CollisionShape3D.new()
var _rd: RenderingDevice
var _shader: RID
var _pipeline: RID
## The big patch's staging texture (SAMPLES^2) and uniform set, and the edit patch's (EDIT_SAMPLES^2).
var _staging: RID
var _set: RID
var _staging_edit: RID
var _set_edit: RID
var _pending := false
var _pending_edit := false
## Bakes asked for and not yet issued: an edit bake for zone, a big bake with the hole at zone.
var _again_edit := false
var _again_big := false
## The zone of the last edit bake requested.
var _issued_zone := NO_HOLE
## From the window, at rebuild; on_edit has no window.
var _n_theta := 0
## Set by the first set_frame; until then the patch has no ground.
var _framed := false


func _init() -> void:
	_shape.map_width = SAMPLES
	_shape.map_depth = SAMPLES
	var c := CollisionShape3D.new()
	c.name = "CollisionShape3D"
	c.shape = _shape
	add_child(c)
	var e := HeightMapShape3D.new()
	e.map_width = EDIT_SAMPLES
	e.map_depth = EDIT_SAMPLES
	_edit_node.name = "EditShape"
	_edit_node.shape = e
	_edit_node.disabled = true  # until its first bake lands
	add_child(_edit_node)


func _notification(what: int) -> void:
	if what != NOTIFICATION_PREDELETE or _rd == null:
		return
	# Freeing the shader frees its pipeline and uniform sets.
	var rids: Array[RID] = [_shader, _staging, _staging_edit]
	RenderingServer.call_on_render_thread(TerrainWindow._free_rids.bind(_rd, rids))


## Puts the patch's frame on the hull of radius R at (theta, z), and makes that its centre. The edit shape
## keeps its place in station space.
func set_frame(theta: float, z: float, R: float) -> void:
	center = Vector2(theta, z)
	_framed = true
	transform = tangent_frame(theta, z, R)
	_edit_node.transform = transform.affine_inverse() * edit_frame


## Puts the edit shape's frame on the hull of radius R at (theta, z).
func set_edit_frame(theta: float, z: float, R: float) -> void:
	edit_frame = tangent_frame(theta, z, R)
	_edit_node.transform = transform.affine_inverse() * edit_frame


## The frame on the hull of radius R at (theta, z): X spinward, Y toward the axis, Z axial.
static func tangent_frame(theta: float, z: float, R: float) -> Transform3D:
	return Transform3D(Basis(Vector3(cos(theta), sin(theta), 0), Vector3(-sin(theta), cos(theta), 0), Vector3(0, 0, 1)),
			Cyl.position(theta, z, 0, R))


## Whether a station-space point is more than REBUILD_DISTANCE from the centre in the patch's XZ plane.
func needs_rebuild(viewer_local: Vector3) -> bool:
	var p := transform.affine_inverse() * viewer_local
	return Vector2(p.x, p.z).length() > REBUILD_DISTANCE


## Whether a station-space point is over the ground this patch holds: within _MID - 4 m (a margin of 4 m
## from the edge) of the centre along both axes of the patch's plane. A patch with no frame covers nothing.
func covers(viewer_local: Vector3) -> bool:
	if not _framed:
		return false
	var p := transform.affine_inverse() * viewer_local
	return maxf(absf(p.x), absf(p.z)) <= _MID - 4


## Height of the surface above the hull at the centre, from the last bake. Only for _on_first_live, before
## any zone exists: sample _MID is NaN once the hole is within HOLE_HALF cells of the centre.
func center_height() -> float:
	return _shape.map_data[_MID * SAMPLES + _MID]


## The station-space point `lift` m (along the patch's up) over the baked surface under the station-space
## point p, bilinear between the four samples around it; p should be covered by the patch. Where any of the
## four is NaN (the hole), the same from the edit shape in its own frame.
func surface_point(p: Vector3, lift: float) -> Vector3:
	var q := transform.affine_inverse() * p
	var y := _bilinear(_shape.map_data, SAMPLES, q.x + _MID, q.z + _MID)
	if is_nan(y):
		var e := edit_frame.affine_inverse() * p
		var edit: HeightMapShape3D = _edit_node.shape
		return edit_frame * Vector3(e.x, _bilinear(edit.map_data, EDIT_SAMPLES, e.x + _EDIT_MID, e.z + _EDIT_MID) + lift, e.z)
	return transform * Vector3(q.x, y + lift, q.z)


## Bilinear in an n x n heightfield d at sample coordinates (x, z), clamped to the samples. A NaN among the
## four samples around (x, z) makes the result NaN.
static func _bilinear(d: PackedFloat32Array, n: int, x: float, z: float) -> float:
	x = clampf(x, 0.0, n - 1.001)
	z = clampf(z, 0.0, n - 1.001)
	var i := int(x)
	var j := int(z)
	var low := lerpf(d[j * n + i], d[j * n + i + 1], x - i)
	var high := lerpf(d[(j + 1) * n + i], d[(j + 1) * n + i + 1], x - i)
	return lerpf(low, high, z - j)


## Bakes the patch around the cell centre nearest (theta, z) from the window as it now stands; the shape and
## the frame change together when the readback lands, then `live` fires. The hole goes in at zone only once
## the zone's edit bake has been requested (so that shape lands first); without it, issue_again bakes again
## with the hole after that request. While a bake is in flight this does nothing: the staging texture is
## still being read, and Terrain asks again every frame until the landed patch covers the viewer.
func rebuild(window: TerrainWindow, center_theta: float, center_z: float) -> void:
	if _pending:
		return
	_pending = true
	_n_theta = window.params.n_theta()
	var cell := window.params.cell_of(center_theta, center_z)
	var with_hole := has_zone and _issued_zone == zone
	_again_big = has_zone and not with_hole
	# Bound after _bake's (theta, z, R): _landed(data, theta, z, R, at).
	var landed := _landed.bind(zone if with_hole else NO_HOLE)
	RenderingServer.call_on_render_thread(func() -> void:
		# A failed setup leaves _pending set, so the error shows once and no bake is attempted again.
		if _rd != null or _setup_rd(window):
			_bake(window, cell, SAMPLES, _staging, _set, "bake", with_hole, landed))


## An edit stamped a disc of `radius` cells around cell: asks for an edit bake, and when the disc leaves the
## zone, moves the zone to cell and asks for a big bake too. Dispatches nothing: issue_again does, from the
## next Terrain._process, after the stamp's compute list.
func on_edit(cell: Vector2i, radius: int) -> void:
	if not (has_zone and zone_holds(zone, cell, radius, _n_theta)):
		zone = cell
		has_zone = true
		_again_big = true
	_again_edit = true


## Whether a disc of `radius` cells around cell stays within HOLE_HALF - ZONE_MARGIN cells of zone along
## both axes, theta the short way round.
static func zone_holds(zone: Vector2i, cell: Vector2i, radius: int, n_theta: int) -> bool:
	@warning_ignore("integer_division")
	var d_theta := wrapi(cell.x - zone.x, -n_theta / 2, n_theta / 2)
	var reach := HOLE_HALF - ZONE_MARGIN - radius
	return absi(d_theta) <= reach and absi(cell.y - zone.y) <= reach


## Issues the bakes on_edit and rebuild asked for: first the edit bake for zone, then the big bake at the
## current centre with the hole at zone, once that zone's edit bake has been requested. One of each kind in
## flight; the flags keep the rest. Every frame from Terrain._process, before its rebuild check.
func issue_again(window: TerrainWindow) -> void:
	# _set_edit is the last thing _setup_rd builds: until it is valid nothing is issued and the flags wait,
	# so no hole can go out without its shape.
	if not _set_edit.is_valid():
		return
	if _again_edit and not _pending_edit:
		_again_edit = false
		_pending_edit = true
		_issued_zone = zone
		var cell := zone
		RenderingServer.call_on_render_thread(func() -> void:
			_bake(window, cell, EDIT_SAMPLES, _staging_edit, _set_edit, "bake_edit", false, _landed_edit))
	if _again_big and not _pending and has_zone and _issued_zone == zone:
		rebuild(window, center.x, center.y)


## Samples either side of the centre that a row of mid samples either side needs, so that its outermost
## output (x = +-mid m) lies inside the polyline even at the highest ground.
static func half_n(mid: int, p: WorldParams) -> int:
	return ceili(asin(minf((mid + 1.0) / (p.radius - p.h_sea - p.h_mtn()), 1.0)) / p.dtheta())


## Dispatches collider_bake.glsl for an n x n patch centred on cell into staging (the output of set),
## between the timestamps <stamp>_begin and <stamp>_end, with the hole at zone if `hole`, and reads staging
## back into landed(data, theta, z, R), (theta, z) the cell's centre. On the render thread, after _setup_rd.
func _bake(window: TerrainWindow, cell: Vector2i, n: int, staging: RID, set: RID, stamp: String, hole: bool, landed: Callable) -> void:
	var p := window.params
	var first := window.wanted_origin(window.center_tile)
	# The Params block of collider_bake.glsl: std430, 64 bytes.
	var b := PackedByteArray()
	b.resize(64)
	b.encode_s32(0, cell.x)
	b.encode_s32(4, cell.y)
	b.encode_s32(8, first.x)
	b.encode_s32(12, first.y)
	b.encode_s32(16, p.n_theta())
	b.encode_s32(20, window.tiles_around)
	b.encode_s32(24, window.slots)
	@warning_ignore("integer_division")
	b.encode_s32(28, half_n((n - 1) / 2, p))
	b.encode_float(32, p.dtheta())
	b.encode_float(36, p.radius)
	b.encode_float(40, p.macro_cell)
	b.encode_s32(44, n)
	b.encode_s32(48, zone.x)
	b.encode_s32(52, zone.y)
	b.encode_s32(56, HOLE_HALF if hole else -1)
	b.encode_float(60, p.h_sea + p.h_mtn())
	_rd.capture_timestamp(stamp + "_begin")
	var list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list, _pipeline)
	_rd.compute_list_bind_uniform_set(list, set, 0)
	_rd.compute_list_set_push_constant(list, b, b.size())
	_rd.compute_list_dispatch(list, ceili(n / 8.0), ceili(n / 8.0), 1)
	_rd.compute_list_end()
	_rd.capture_timestamp(stamp + "_end")
	var theta := (cell.x + 0.5) * p.dtheta()
	var z := -p.length / 2.0 + cell.y + 0.5
	var err := _rd.texture_get_data_async(staging, 0, landed.bind(theta, z, p.radius))
	if err != OK:
		push_error("collider bake readback: %s" % error_string(err))
		# Handled as a readback that landed empty: the big bake keeps _pending set, the edit bake retries.
		landed.call(PackedByteArray(), theta, z, p.radius)


## Runs where RenderingDevice callbacks run: the main thread under the default thread model, inside the
## device's readback flush, where a compute list is discarded and an async readback reads zeros. So this,
## and whatever `baked` and `live` reach, does CPU work only and dispatches nothing.
func _landed(data: PackedByteArray, theta: float, z: float, R: float, at: Vector2i) -> void:
	if data.size() != SAMPLES * SAMPLES * 4:
		push_error("collider bake readback: %d bytes, expected %d" % [data.size(), SAMPLES * SAMPLES * 4])
		return  # _pending stays set, so the error shows once and the hold keeps the body safe
	var t := Time.get_ticks_usec()
	_shape.map_data = data.to_float32_array()
	var ms := (Time.get_ticks_usec() - t) / 1000.0
	set_frame(theta, z, R)
	hole_zone = at
	_pending = false
	baked.emit("big", ms)
	live.emit(center)


## The edit bake's landing, where _landed runs and under the same rule: CPU work only.
func _landed_edit(data: PackedByteArray, theta: float, z: float, R: float) -> void:
	if data.size() != EDIT_SAMPLES * EDIT_SAMPLES * 4:
		push_error("edit bake readback: %d bytes, expected %d" % [data.size(), EDIT_SAMPLES * EDIT_SAMPLES * 4])
		# Retried from the next issue_again, not held: the hole for zone may already be out, unbacked for the
		# two frames until the retry lands (a body over it drops under 5 mm and is pushed out).
		_pending_edit = false
		_again_edit = true
		return
	var t := Time.get_ticks_usec()
	(_edit_node.shape as HeightMapShape3D).map_data = data.to_float32_array()
	var ms := (Time.get_ticks_usec() - t) / 1000.0
	_edit_node.disabled = false
	set_edit_frame(theta, z, R)
	_pending_edit = false
	baked.emit("edit", ms)


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
	f.format = RenderingDevice.DATA_FORMAT_R32_SFLOAT
	f.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	f.width = SAMPLES
	f.height = SAMPLES
	_staging = _rd.texture_create(f, RDTextureView.new())
	f.width = EDIT_SAMPLES
	f.height = EDIT_SAMPLES
	_staging_edit = _rd.texture_create(f, RDTextureView.new())
	_set = _uniform_set(window, _staging)
	_set_edit = _uniform_set(window, _staging_edit)
	return true


## collider_bake.glsl's set 0: the window's surface, the macro surface, and staging as the output.
func _uniform_set(window: TerrainWindow, staging: RID) -> RID:
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
	o.add_id(staging)
	var uniforms: Array[RDUniform] = [w, m, o]
	return _rd.uniform_set_create(uniforms, _shader, 0)
