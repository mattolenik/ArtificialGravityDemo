extends SceneTree

var failed := false

func check(ok: bool, msg: String) -> void:
	if not ok:
		push_error(msg)
		failed = true

func _initialize() -> void:
	# A chunk mesh's arrays: the surface holds the vertices, the trimesh holds the triangles de-indexed in order
	# and collides on both faces; empty arrays clear both.
	var cm := ChunkMesh.new(null)
	var vs := PackedVector3Array([Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(1, 0, 1), Vector3(0, 0, 1)])
	var ns := PackedVector3Array([Vector3.UP, Vector3.UP, Vector3.UP, Vector3.UP])
	var cs := PackedColorArray([Color.WHITE, Color.WHITE, Color.WHITE, Color.WHITE])
	cm.set_arrays(vs, ns, cs, PackedInt32Array([0, 1, 2, 0, 2, 3]))
	var shape := cm._shape.shape as ConcavePolygonShape3D
	check(cm.faces == 2 and cm._mesh.mesh.get_surface_count() == 1 and cm._mesh.mesh.surface_get_array_len(0) == 4, "two faces on a four-vertex surface")
	check(shape != null and shape.backface_collision and shape.get_faces() == PackedVector3Array([vs[0], vs[1], vs[2], vs[0], vs[2], vs[3]]), "the trimesh is the triangles in order, both faces")
	cm.set_arrays(PackedVector3Array(), PackedVector3Array(), PackedColorArray(), PackedInt32Array())
	check(cm.faces == 0 and cm._shape.shape == null and cm._mesh.mesh == null, "empty arrays clear the mesh and the shape")
	cm.free()
	if failed: quit(1)
	else: print("PASS"); quit(0)
