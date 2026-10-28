## The terrain beyond the 1 m window, in two levels. Level 1 is a second TerrainWindow at 8 m (4 km
## square) sharing the main window's macro uploads and pipeline, drawn as 16 tiles of 1024 m with
## tile.gdshader and water.gdshader, discarding inside the main window. Level 2 is one 32 m mesh of the
## whole station from the macro maps (far.gdshader), discarding inside both windows; it also covers the
## last 256 m of the station, where the 8 m window has no tile. A child of Terrain, so its space is
## station space.
class_name FarTerrain
extends Node3D

## Level 1's cell in m and side in cells.
const CELL := 8.0
const SIZE := 512

var window: TerrainWindow

var _main: TerrainWindow
var _tiles: Array[MeshInstance3D] = []
var _whole: ShaderMaterial
var _center := Vector2i(-1, -1)
var _inner := Vector4.ZERO


## Builds both levels on the main window, which must be set up.
func setup(main: TerrainWindow) -> void:
	_main = main
	var p := main.params
	var R := p.radius
	window = TerrainWindow.new()
	window.setup(p, main.maps, SIZE, CELL, main)
	_tiles = Terrain.make_tiles(self, window)
	var mesh := PlaneMesh.new()
	mesh.size = Vector2(p.macro_w(), p.macro_h() + 1)
	mesh.subdivide_width = p.macro_w() - 1
	mesh.subdivide_depth = p.macro_h()
	# The shader places every vertex; the mesh spans the whole station.
	mesh.custom_aabb = AABB(Vector3(-R, -R, -p.length / 2.0), Vector3(2 * R, 2 * R, p.length))
	_whole = ShaderMaterial.new()
	_whole.shader = preload("res://terrain/shaders/far.gdshader")
	_whole.set_shader_parameter("surface_tex", main.macro_texture_rd("surface"))
	_whole.set_shader_parameter("water_tex", main.macro_texture_rd("water_surface"))
	_whole.set_shader_parameter("bedrock_tex", main.macro_texture_rd("bedrock_top"))
	_whole.set_shader_parameter("material_color", preload("res://terrain/materials.tres").color)
	_whole.set_shader_parameter("R", R)
	_whole.set_shader_parameter("macro_dtheta", TAU / p.macro_w())
	_whole.set_shader_parameter("macro_cell", p.macro_cell)
	_whole.set_shader_parameter("station_length", p.length)
	var whole := MeshInstance3D.new()
	whole.mesh = mesh
	whole.material_override = _whole
	whole.layers = Terrain.RENDER_LAYER
	add_child(whole)


## Moves level 1 to the 1 m cell (theta index, z index) under the viewer and points both levels' holes
## at the windows as they stand. Call after the main window has moved.
func follow(cell: Vector2i) -> void:
	var c := window.tile_of_cell(cell.x, cell.y)
	if c != _center:
		_center = c
		window.move_to(c)
		Terrain.place_tiles(window, _tiles, c)
		_whole.set_shader_parameter("hole_far", window.extent())
	var inner := _main.extent()
	if inner != _inner:
		_inner = inner
		_whole.set_shader_parameter("hole_near", inner)
		for m: ShaderMaterial in [_tiles[0].material_override, _tiles[0].get_child(0).material_override]:
			m.set_shader_parameter("hole", inner)
