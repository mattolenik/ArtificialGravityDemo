## The ground inside the station: loads (or generates) the world, keeps the 1 m TerrainWindow around the
## viewer, and draws it as one tile mesh per window slot, each with a water mesh as its child, bent onto
## the cylinder by tile.gdshader and water.gdshader; FarTerrain draws beyond it, and a ColliderPatch under
## the viewer is the ground. The ground body (the viewer at the start) is held still until the first patch
## is live, then stood on it at the spawn site, and held again whenever the live patch does not cover it.
## Floating origin: the whole station moves along its axis in ORIGIN_STEP steps to keep the viewer near
## the global origin; terrain works in station space only. Place it under the Station at its origin, so
## its space is station space.
class_name Terrain
extends Node3D

## Emitted once the ground collider at the spawn site exists and the viewer stands on it.
signal collider_live
## Emitted after each floating-origin shift, with the station's z shift in m.
signal origin_shifted(shift: float)
## Emitted when Terrain starts or stops holding the ground body for want of a patch under it.
signal body_held(held: bool)

@export var station: Station
## The window follows this node.
@export var viewer: Node3D
## Directory under user://worlds/.
@export var world_name := "default"
## Window side in 1 m cells, a multiple of TerrainWindow.TILE.
@export var window_size := 512
## Whether edited tiles are saved to the world's tiles/ directory (edits are always loaded). Windowed test
## drivers set it false, so they never write into a real world.
@export var persist_edits := true

## The station shifts along its axis by whole steps of this many m once the viewer is farther than this
## from the global origin.
const ORIGIN_STEP := 1024.0
## Render layer mask of every terrain mesh: the LightBar lights the terrain through its own shaders and
## everything else through a plain directional light, split on this layer.
const RENDER_LAYER := 2
## Seconds between autosaves of the edited tiles that have been read back since the last one.
const SAVE_INTERVAL := 30.0
## Bodies in this group are held while no live collider patch covers them (the ground body always is).
const GROUND_GROUP := "terrain_ground"
## Meta key of a body's hold state: true while Terrain is holding it.
const HELD_META := "terrain_held"

var params: WorldParams
var maps: MacroMaps
var window: TerrainWindow
var patch: ColliderPatch

## One ground mesh per slot, slot (x, y) at index y * slots + x; its child is the water mesh.
var _tiles: Array[MeshInstance3D] = []
var _center := Vector2i(-1, -1)
## Set once the first patch is live and the viewer is released.
var _live := false
## The node stood on the ground at spawn; the viewer may later become the FlyCamera.
var _body: Node3D
## Set by teleport() while the body waits, held, for a patch at its new place; cleared once stood on one.
var _teleporting := false
## Where the viewer was stood at the spawn site, in station space.
var _spawn_at: Vector3
## Seconds since the edits were last saved.
var _since_save := 0.0

@onready var far: FarTerrain = $Far


func _ready() -> void:
	_body = viewer
	_body.process_mode = PROCESS_MODE_DISABLED
	# Children are ready before their parent, so the station may not have measured its hull yet.
	if station.radius == 0.0:
		await station.ready
	_load_world()
	window = TerrainWindow.new()
	window.setup(params, maps, window_size)
	window.edits = EditLayer.new()
	window.edits.setup(window)
	# Before the first move_to, so the spawn tiles get their edits in their first dispatch.
	window.edits.blobs = WorldIO.load_edits(world_name)
	if not window.edits.blobs.is_empty():
		print("Loaded %d edited tiles" % window.edits.blobs.size())
	_tiles = make_tiles(self, window)
	far.setup(window)
	# The viewer's scene position is under the sea floor: start the windows and the patch at the spawn site.
	patch = ColliderPatch.new()
	add_child(patch)
	patch.live.connect(_on_first_live, CONNECT_ONE_SHOT)
	patch.live.connect(_on_live)
	var spawn := maps.spawn
	var cell := params.cell_of(spawn.x, spawn.y)
	_move_window(window.tile_of_cell(cell.x, cell.y))
	far.follow(cell)
	patch.rebuild(window, spawn.x, spawn.y)


## The station's z shift that brings a viewer at global z back within ORIGIN_STEP / 2 of the origin, in
## whole steps, once it is farther than ORIGIN_STEP; 0 until then.
static func origin_shift_for(viewer_global_z: float) -> float:
	if absf(viewer_global_z) <= ORIGIN_STEP:
		return 0.0
	return -roundf(viewer_global_z / ORIGIN_STEP) * ORIGIN_STEP


## One ground mesh per slot of w, slot (x, y) at index y * slots + x, each with a water mesh as its child,
## added under parent and reading w's textures.
static func make_tiles(parent: Node3D, w: TerrainWindow) -> Array[MeshInstance3D]:
	var mesh := PlaneMesh.new()
	mesh.size = Vector2.ONE * TerrainWindow.TILE
	mesh.subdivide_width = TerrainWindow.TILE - 1
	mesh.subdivide_depth = TerrainWindow.TILE - 1
	# The shaders move every vertex; every tile is drawn in the frame of the wanted set's middle (see
	# place_tiles), so this box holds the whole window in it, a cell of margin each way. Across, a vertex
	# sits up to R sin(a) from the middle, a = half the window plus half a cell of angle (314 m for the 1 m
	# window on the default world, 2266 m for the 8 m one); along, half the window plus half a cell; up,
	# under h_sea + h_mtn plus the curvature 2R sin^2(a / 2); down, a dry water vertex tucks 1 m under the
	# hull-level sea floor and a coarser level sinks a quarter cell.
	var p := w.params
	var a := (w.size / 2.0 + 0.5) * w.cell * p.dtheta()
	var across := p.radius * sin(a) + w.cell
	var along := (w.size / 2.0 + 1.5) * w.cell
	var top := p.h_sea + p.h_mtn() + 2.0 * p.radius * sin(a / 2.0) ** 2 + w.cell
	mesh.custom_aabb = AABB(Vector3(-across, -10, -along), Vector3(2.0 * across, top + 10, 2.0 * along))
	var ground := _material(preload("res://terrain/shaders/tile.gdshader"), w)
	ground.set_shader_parameter("material_tex", w.texture_rd("material"))
	ground.set_shader_parameter("material_color", preload("res://terrain/materials.tres").color)
	ground.set_shader_parameter("n_theta", w.params.n_theta())
	var water := _material(preload("res://terrain/shaders/water.gdshader"), w)
	var tiles: Array[MeshInstance3D] = []
	for i in w.slots * w.slots:
		var tile := MeshInstance3D.new()
		tile.mesh = mesh
		tile.material_override = ground
		tile.layers = RENDER_LAYER
		var wet := MeshInstance3D.new()
		wet.mesh = mesh
		wet.material_override = water
		wet.layers = RENDER_LAYER
		tile.add_child(wet)
		parent.add_child(tile)
		tiles.append(tile)
	return tiles


## Stands the viewer 2 m above the patch's centre, facing spinward with its up toward the axis, and lets
## it go.
func _on_first_live(center: Vector2) -> void:
	var up := Vector3(-sin(center.x), cos(center.x), 0)
	var forward := Vector3(cos(center.x), sin(center.x), 0)
	_spawn_at = Cyl.position(center.x, center.y, patch.center_height() + 2.0, params.radius)
	viewer.global_transform = station.global_transform * Transform3D(Basis(up.cross(-forward), up, -forward), _spawn_at)
	viewer.process_mode = PROCESS_MODE_INHERIT
	_live = true
	collider_live.emit()


func _load_world() -> void:
	var world := WorldIO.load_world(world_name)
	if world.is_empty():
		params = WorldParams.new()
		params.radius = station.radius
		params.length = station.length
		params.g_hull = station.acceleration
		print("Generating world '%s'..." % world_name)
		maps = MacroGenerator.new().generate(params, func(stage: String, fraction: float) -> void:
			print("  %3d%% %s" % [roundi(fraction * 100), stage]))
		var err := WorldIO.save(maps, params, world_name)
		if err != OK:
			push_error("Saving world '%s' failed: %s" % [world_name, error_string(err)])
		return
	params = world[0]
	maps = world[1]
	if not is_equal_approx(params.radius, station.radius):
		push_warning("World '%s' was made for radius %.1f m, the station's is %.1f m; using the world's." \
				% [world_name, params.radius, station.radius])


static func _material(shader: Shader, w: TerrainWindow) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = shader
	m.set_shader_parameter("surface_tex", w.texture_rd("surface"))
	m.set_shader_parameter("water_tex", w.texture_rd("water_surface"))
	m.set_shader_parameter("R", w.params.radius)
	m.set_shader_parameter("dtheta", w.params.dtheta())
	m.set_shader_parameter("cell", w.cell)
	m.set_shader_parameter("height_scale", TerrainWindow.HEIGHT_SCALE)
	m.set_shader_parameter("window_size", w.size)
	return m


## The floating-origin shift: everything in the world is under the station, so one move takes it all
## along. Moving the station re-sends every body's node transform to the physics server, so this runs
## here, where those transforms hold the latest physics state (from _process they are a step stale and a
## moving body would lose that step), and only when there is a shift (every frame would pin rigid bodies).
func _physics_process(_delta: float) -> void:
	if not _live:
		return
	var shift := origin_shift_for(viewer.global_position.z)
	if shift != 0.0:
		station.position.z += shift
		origin_shifted.emit(shift)


func _process(delta: float) -> void:
	if not _live:
		return
	_since_save += delta
	if _since_save >= SAVE_INTERVAL:
		_save_edits()
	var cell := viewer_cell()
	_move_window(window.tile_of_cell(cell.x, cell.y))
	far.follow(cell)
	var p := station.to_local(viewer.global_position)
	patch.issue_again(window)
	if patch.needs_rebuild(p):
		patch.rebuild(window, Cyl.theta_of(p), p.z)
	_hold_body(not patch.covers(station.to_local(_body.global_position)))
	for b: Node3D in get_tree().get_nodes_in_group(GROUND_GROUP):
		_hold(b, not patch.covers(station.to_local(b.global_position)))


func _exit_tree() -> void:
	_save_edits()


## Writes the tiles whose blobs have landed since the last save (all of window.edits.unsaved: no GPU wait,
## so a tile still being read back is saved by the next call) and forgets them once written. A tile whose
## readback lands after _exit_tree's save is lost: the exit does not wait for it.
func _save_edits() -> void:
	_since_save = 0.0
	if not persist_edits or window == null or window.edits.unsaved.is_empty():
		return
	var landed := {}
	for tile: Vector2i in window.edits.unsaved:
		landed[tile] = window.edits.blobs[tile]
	var err := WorldIO.save_edits(world_name, landed)
	if err != OK:
		push_error("Saving the edits of world '%s' failed: %s" % [world_name, error_string(err)])
		return
	window.edits.unsaved.clear()


## Holds _body while there is no ground under it, and lets it go once there is.
func _hold_body(hold: bool) -> void:
	if _hold(_body, hold):
		body_held.emit(hold)


## Holds a body (frozen, out of the physics space with its state) or releases it; the state is kept in its
## meta terrain_held. A body that something else already disabled (the FlyCamera freezing the player) is
## neither taken nor released. Returns whether anything changed.
func _hold(body: Node3D, hold: bool) -> bool:
	if hold == body.get_meta(HELD_META, false) or (hold and body.process_mode == PROCESS_MODE_DISABLED):
		return false
	body.set_meta(HELD_META, hold)
	body.process_mode = PROCESS_MODE_DISABLED if hold else PROCESS_MODE_INHERIT
	return true


## Moves the ground body to stand on the surface at (theta, z), with no velocity. Over the live patch it
## is stood on it at once; elsewhere it is put 2 m over the macro surface and held until a patch covers
## it, then stood on that (_on_live). Nothing before the first patch is live.
func teleport(theta: float, z: float) -> void:
	if not _live:
		return
	var p := Cyl.position(theta, z, height_at(theta, z) + 2.0, params.radius)
	if patch.covers(p):
		p = patch.surface_point(p, 2.0)
	else:
		_teleporting = true
		_hold_body(true)
	if _body is CharacterBody3D:
		(_body as CharacterBody3D).velocity = Vector3.ZERO
	_body.global_position = station.global_transform * p


## Stands a teleported body on the patch that has just landed under it.
func _on_live(_center: Vector2) -> void:
	if not _teleporting:
		return
	var p := station.to_local(_body.global_position)
	if not patch.covers(p):
		return
	_teleporting = false
	_body.global_position = station.global_transform * patch.surface_point(p, 2.0)


## Moves the window to the tiles around center and points every tile node at its tile, if center changed.
func _move_window(center: Vector2i) -> void:
	if center == _center:
		return
	_center = center
	window.move_to(center)
	place_tiles(window, _tiles, center)


## Points every node of tiles (from make_tiles) at its tile of w's wanted set around center. All nodes
## share one transform, the frame on the hull at the wanted set's middle grid point, and each tile's
## `tile_offset` is its centre's offset from there in window cells (theta the short way round), so tiles
## that share an edge bend identical numbers in one frame and their edge vertices match bit for bit.
static func place_tiles(w: TerrainWindow, tiles: Array[MeshInstance3D], center: Vector2i) -> void:
	var wanted := w.wanted_tiles(center)
	@warning_ignore("integer_division")
	var mid := w.wanted_origin(center) * TerrainWindow.TILE + Vector2i.ONE * (w.size / 2)
	var theta := mid.x * w.cell * w.params.dtheta()
	var frame := Transform3D(
			Basis(Vector3(cos(theta), sin(theta), 0), Vector3(-sin(theta), cos(theta), 0), Vector3(0, 0, 1)),
			Cyl.position(theta, -w.params.length / 2.0 + mid.y * w.cell, 0, w.params.radius))
	@warning_ignore("integer_division")
	var half_around := w.tiles_around * TerrainWindow.TILE / 2
	for n in wanted.size():
		var t := wanted[n]
		var s := w.slot_of(t)
		var tile := tiles[s.y * w.slots + s.x]
		tile.transform = frame
		var c := w.tile_center(t)
		@warning_ignore("integer_division")
		var k := t * TerrainWindow.TILE + Vector2i.ONE * (TerrainWindow.TILE / 2) - mid
		var offset := Vector2i(wrapi(k.x, -half_around, half_around), k.y)
		@warning_ignore("integer_division")
		var edge := Vector2i(_edge(n % w.slots, w.slots), _edge(n / w.slots, w.slots))
		for g: GeometryInstance3D in [tile, tile.get_child(0)]:
			g.set_instance_shader_parameter("tile_theta", c.x)
			g.set_instance_shader_parameter("tile_z", c.y)
			g.set_instance_shader_parameter("tile_offset", offset)
			g.set_instance_shader_parameter("slot_origin", w.texel_origin(t))
			g.set_instance_shader_parameter("clamp_edge", edge)


## -1 for the first of the wanted set's rows or columns, +1 for the last, 0 between.
static func _edge(i: int, slots: int) -> int:
	return -1 if i == 0 else (1 if i == slots - 1 else 0)


## Raises (dh > 0) or lowers (dh < 0) the ground in a disc around the cell at (theta, z) by dh m at its
## centre with a parabolic falloff to its edge (EditLayer.stamp; decision 7 of the terrain edits plan).
## radius is in cells, not metres, and at most 64 (four tiles): a cell is 1 m along the axis and (R - h) dtheta
## across, 1.23 m on the hull and 0.64 m at h_sea + h_mtn with the default WorldParams, so the disc is an
## ellipse in metres. Digging cuts the strata down with the surface; raising adds dirt. The collider follows
## from the next frame (ColliderPatch.on_edit). False, and nothing changes, before the first patch is live,
## for a radius out of range, when the disc is wholly off the station's ends, or when it is not wholly inside
## the 1 m window.
func edit(theta: float, z: float, radius: float, dh: float) -> bool:
	var r := ceili(radius)
	# r >= TILE is refused before stamp_tiles, which loops over every tile of the box.
	if not _live or r < 0 or r >= TerrainWindow.TILE:
		return false
	var cell := params.cell_of(theta, z)
	var tiles := EditLayer.stamp_tiles(window, cell, r)
	# Empty: the disc is wholly off the station's ends. From r = 65 the box can span three tiles per axis,
	# more than the pack's slots.
	if tiles.is_empty() or tiles.size() > EditLayer.DOWN_SLOTS:
		return false
	for t in tiles:
		if not window.is_resident(t):
			return false
	window.edits.stamp(window, cell, r, dh)
	patch.on_edit(cell, r)
	return true


## Surface height in m at (theta, z), bilinear from the 32 m macro map: approximate, no detail.
func height_at(theta: float, z: float) -> float:
	return maps.sample(maps.surface, theta, z, params)


## Station-space point where the viewer was stood at the spawn site once the first patch is live; until
## then, 2 m above the macro surface there.
func spawn_position() -> Vector3:
	if _live:
		return _spawn_at
	return Cyl.position(maps.spawn.x, maps.spawn.y, height_at(maps.spawn.x, maps.spawn.y) + 2.0, params.radius)


## The 1 m cell (theta index, z index) under the viewer.
func viewer_cell() -> Vector2i:
	var p := station.to_local(viewer.global_position)
	return params.cell_of(Cyl.theta_of(p), p.z)
