## The ground inside the station: loads (or generates) the world, keeps the 1 m TerrainWindow around the
## viewer, and draws it as one tile mesh per window slot, each with a water mesh as its child, bent onto
## the cylinder by tile.gdshader and water.gdshader; FarTerrain draws beyond it, and a ColliderPatch under
## the viewer is the ground. The viewer is held still until the first patch is live, then stood on it at
## the spawn site. Floating origin: the whole station moves along its axis in ORIGIN_STEP steps to keep
## the viewer near the global origin; terrain works in station space only. Place it under the Station at
## its origin, so its space is station space.
class_name Terrain
extends Node3D

## Emitted once the ground collider at the spawn site exists and the viewer stands on it.
signal collider_live
## Emitted after each floating-origin shift, with the station's z shift in m.
signal origin_shifted(shift: float)

@export var station: Station
## The window follows this node.
@export var viewer: Node3D
## Directory under user://worlds/.
@export var world_name := "default"
## Window side in 1 m cells, a multiple of TerrainWindow.TILE.
@export var window_size := 512

## The station shifts along its axis by whole steps of this many m once the viewer is farther than this
## from the global origin.
const ORIGIN_STEP := 1024.0

var params: WorldParams
var maps: MacroMaps
var window: TerrainWindow
var patch: ColliderPatch

## One ground mesh per slot, slot (x, y) at index y * slots + x; its child is the water mesh.
var _tiles: Array[MeshInstance3D] = []
var _center := Vector2i(-1, -1)
## Set once the first patch is live and the viewer is released.
var _live := false
## Where the viewer was stood at the spawn site, in station space.
var _spawn_at: Vector3

@onready var far: FarTerrain = $Far


func _ready() -> void:
	viewer.process_mode = PROCESS_MODE_DISABLED
	# Children are ready before their parent, so the station may not have measured its hull yet.
	if station.radius == 0.0:
		await station.ready
	_load_world()
	window = TerrainWindow.new()
	window.setup(params, maps, window_size)
	_tiles = make_tiles(self, window)
	far.setup(window)
	# The viewer's scene position is under the sea floor: start the windows and the patch at the spawn site.
	patch = ColliderPatch.new()
	add_child(patch)
	patch.live.connect(_on_first_live, CONNECT_ONE_SHOT)
	var spawn := maps.spawn
	var cell := Vector2i(floori(spawn.x / params.dtheta()), floori(spawn.y + params.length / 2.0))
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
	# The shaders move every vertex; this box holds any tile in its node's frame, a cell of margin each
	# way. Across, a vertex sits up to R sin(a) from the centre, a = 64.5 cells of angle (79 m for a 1 m
	# tile on the default world, 631 m for an 8 m one); along, 64.5 cells; up, under h_sea + h_mtn plus
	# the curvature 2R sin^2(a / 2); down, a dry water vertex tucks 1 m under the hull-level sea floor and a
	# coarser level sinks a quarter cell.
	var p := w.params
	var a := (TerrainWindow.TILE / 2.0 + 0.5) * w.cell * p.dtheta()
	var across := p.radius * sin(a) + w.cell
	var along := (TerrainWindow.TILE / 2.0 + 1.5) * w.cell
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
		var wet := MeshInstance3D.new()
		wet.mesh = mesh
		wet.material_override = water
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


func _process(_delta: float) -> void:
	if not _live:
		return
	var cell := viewer_cell()
	_move_window(window.tile_of_cell(cell.x, cell.y))
	far.follow(cell)
	var p := station.to_local(viewer.global_position)
	if patch.needs_rebuild(p):
		patch.rebuild(window, Cyl.theta_of(p), p.z)


## Moves the window to the tiles around center and points every tile node at its tile, if center changed.
func _move_window(center: Vector2i) -> void:
	if center == _center:
		return
	_center = center
	window.move_to(center)
	place_tiles(window, _tiles, center)


## Points every node of tiles (from make_tiles) at its tile of w's wanted set around center.
static func place_tiles(w: TerrainWindow, tiles: Array[MeshInstance3D], center: Vector2i) -> void:
	var wanted := w.wanted_tiles(center)
	for n in wanted.size():
		var t := wanted[n]
		var s := w.slot_of(t)
		var tile := tiles[s.y * w.slots + s.x]
		var c := w.tile_center(t)
		tile.transform = Transform3D(
				Basis(Vector3(cos(c.x), sin(c.x), 0), Vector3(-sin(c.x), cos(c.x), 0), Vector3(0, 0, 1)),
				Cyl.position(c.x, c.y, 0, w.params.radius))
		@warning_ignore("integer_division")
		var edge := Vector2i(_edge(n % w.slots, w.slots), _edge(n / w.slots, w.slots))
		for g: GeometryInstance3D in [tile, tile.get_child(0)]:
			g.set_instance_shader_parameter("tile_theta", c.x)
			g.set_instance_shader_parameter("tile_z", c.y)
			g.set_instance_shader_parameter("slot_origin", w.texel_origin(t))
			g.set_instance_shader_parameter("clamp_edge", edge)


## -1 for the first of the wanted set's rows or columns, +1 for the last, 0 between.
static func _edge(i: int, slots: int) -> int:
	return -1 if i == 0 else (1 if i == slots - 1 else 0)


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
	# posmod: an angle a hair under TAU can still divide out to n_theta.
	return Vector2i(posmod(floori(Cyl.theta_of(p) / params.dtheta()), params.n_theta()), floori(p.z + params.length / 2.0))
