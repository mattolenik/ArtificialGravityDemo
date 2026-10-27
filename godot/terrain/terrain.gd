## The ground inside the station: loads (or generates) the world, keeps the 1 m TerrainWindow around the
## viewer, and draws it as one tile mesh per window slot, each with a water mesh as its child, bent onto
## the cylinder by tile.gdshader and water.gdshader. Place it under the Station at its origin, so its
## space is station space.
class_name Terrain
extends Node3D

## Emitted once the ground collider around the viewer exists (Task 7).
@warning_ignore("unused_signal")
signal collider_live

@export var station: Station
## The window follows this node.
@export var viewer: Node3D
## Directory under user://worlds/.
@export var world_name := "default"
## Window side in 1 m cells, a multiple of TerrainWindow.TILE.
@export var window_size := 512

var params: WorldParams
var maps: MacroMaps
var window: TerrainWindow

## One ground mesh per slot, slot (x, y) at index y * slots + x; its child is the water mesh.
var _tiles: Array[MeshInstance3D] = []
var _center := Vector2i(-1, -1)


func _ready() -> void:
	# Children are ready before their parent, so the station may not have measured its hull yet.
	if station.radius == 0.0:
		await station.ready
	_load_world()
	window = TerrainWindow.new()
	window.setup(params, maps, window_size)
	var mesh := PlaneMesh.new()
	mesh.size = Vector2.ONE * TerrainWindow.TILE
	mesh.subdivide_width = TerrainWindow.TILE - 1
	mesh.subdivide_depth = TerrainWindow.TILE - 1
	# The shaders move every vertex; this box holds any tile in its node's frame. Across, a vertex sits up
	# to (R - h) sin(64.5 dtheta) from the centre (about 79 m at the hull on the default world, where a
	# cell is 1.23 m wide); along, 64.5 m; up, under h_sea + h_mtn plus 1 m of curvature.
	var half := params.radius * sin((TerrainWindow.TILE / 2.0 + 1.0) * params.dtheta()) + 1.0
	mesh.custom_aabb = AABB(Vector3(-half, -10, -half), Vector3(2.0 * half, 2100, 2.0 * half))
	var ground := _material(preload("res://terrain/shaders/tile.gdshader"))
	ground.set_shader_parameter("material_tex", window.texture_rd("material"))
	ground.set_shader_parameter("material_color", preload("res://terrain/materials.tres").color)
	ground.set_shader_parameter("n_theta", params.n_theta())
	var water := _material(preload("res://terrain/shaders/water.gdshader"))
	for i in window.slots * window.slots:
		var tile := MeshInstance3D.new()
		tile.mesh = mesh
		tile.material_override = ground
		var w := MeshInstance3D.new()
		w.mesh = mesh
		w.material_override = water
		tile.add_child(w)
		add_child(tile)
		_tiles.append(tile)


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


func _material(shader: Shader) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = shader
	m.set_shader_parameter("surface_tex", window.texture_rd("surface"))
	m.set_shader_parameter("water_tex", window.texture_rd("water_surface"))
	m.set_shader_parameter("R", params.radius)
	m.set_shader_parameter("dtheta", params.dtheta())
	m.set_shader_parameter("dz", window.cell)
	m.set_shader_parameter("height_scale", TerrainWindow.HEIGHT_SCALE)
	m.set_shader_parameter("window_size", window_size)
	return m


func _process(_delta: float) -> void:
	var cell := viewer_cell()
	var center := window.tile_of_cell(cell.x, cell.y)
	if center == _center:
		return
	_center = center
	window.move_to(center)
	var wanted := window.wanted_tiles(center)
	for n in wanted.size():
		var t := wanted[n]
		var s := window.slot_of(t)
		var tile := _tiles[s.y * window.slots + s.x]
		var c := window.tile_center(t)
		tile.transform = Transform3D(
				Basis(Vector3(cos(c.x), sin(c.x), 0), Vector3(-sin(c.x), cos(c.x), 0), Vector3(0, 0, 1)),
				Cyl.position(c.x, c.y, 0, params.radius))
		@warning_ignore("integer_division")
		var edge := Vector2i(_edge(n % window.slots), _edge(n / window.slots))
		for g: GeometryInstance3D in [tile, tile.get_child(0)]:
			g.set_instance_shader_parameter("tile_theta", c.x)
			g.set_instance_shader_parameter("tile_z", c.y)
			g.set_instance_shader_parameter("slot_origin", window.texel_origin(t))
			g.set_instance_shader_parameter("clamp_edge", edge)


## -1 for the first of the wanted set's rows or columns, +1 for the last, 0 between.
func _edge(i: int) -> int:
	return -1 if i == 0 else (1 if i == window.slots - 1 else 0)


## Surface height in m at (theta, z), bilinear from the 32 m macro map: approximate, no detail.
func height_at(theta: float, z: float) -> float:
	return maps.sample(maps.surface, theta, z, params)


## Station-space point 2 m above the macro surface at the world's spawn site.
func spawn_position() -> Vector3:
	return Cyl.position(maps.spawn.x, maps.spawn.y, height_at(maps.spawn.x, maps.spawn.y) + 2.0, params.radius)


## The 1 m cell (theta index, z index) under the viewer.
func viewer_cell() -> Vector2i:
	var p := station.to_local(viewer.global_position)
	# posmod: an angle a hair under TAU can still divide out to n_theta.
	return Vector2i(posmod(floori(Cyl.theta_of(p) / params.dtheta()), params.n_theta()), floori(p.z + params.length / 2.0))
