## A touched chunk of the voxel box (the tunnels design): its surface-nets mesh (box_mesh.glsl, read back by
## VoxelBox.remesh_dirty) drawn by chunk.gdshader with the material per vertex in COLOR, and collided as a
## trimesh. A child of Terrain, so its space is station space and its vertices need no transform.
class_name ChunkMesh
extends StaticBody3D

## Triangles of the last arrays taken.
var faces := 0
## The CPU ms of the last trimesh build.
var build_ms := 0.0
var _mesh := MeshInstance3D.new()
var _shape := CollisionShape3D.new()


func _init(material: Material) -> void:
	_mesh.material_override = material
	_mesh.layers = Terrain.RENDER_LAYER
	add_child(_mesh)
	add_child(_shape)


## Takes a mesh's arrays: the ArrayMesh surface and the trimesh shape rebuilt in one go (the old shape stays
## until the new one is assigned); empty arrays clear both.
func set_arrays(vertices: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray, indices: PackedInt32Array) -> void:
	@warning_ignore("integer_division")
	faces = indices.size() / 3
	if faces == 0:
		_mesh.mesh = null
		_shape.shape = null
		return
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_mesh.mesh = m
	var t := Time.get_ticks_usec()
	var shape := m.create_trimesh_shape()
	shape.backface_collision = true
	_shape.shape = shape
	build_ms = (Time.get_ticks_usec() - t) / 1000.0
