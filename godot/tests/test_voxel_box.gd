extends SceneTree

## The voxel box's arithmetic (VoxelBox): the origin from the feet, brick slots, the brick of a cell, a voxel's
## words. No RenderingDevice here; the box itself is proven by box_run.tscn.

var failed := false

func check(ok: bool, msg: String) -> void:
	if not ok:
		push_error(msg)
		failed = true

func _initialize() -> void:
	# The feet's brick is the middle one across and along; the bottom brick is 40 m under the feet.
	check(VoxelBox.box_origin_for(Vector2i(100, 200), 410.0) == Vector3i(-2, 4, 23), "origin %s" % VoxelBox.box_origin_for(Vector2i(100, 200), 410.0))
	check(VoxelBox.box_origin_for(Vector2i(16380, 0), 40.0) == Vector3i(1023 - 8, -8, 0), "origin at the seam")
	# Slots wrap 16, 16, 4.
	check(VoxelBox.slot_of(Vector3i(-2, 4, 23)) == Vector3i(14, 4, 3) and VoxelBox.slot_of(Vector3i(17, 16, 4)) == Vector3i(1, 0, 0), "slots")
	check(VoxelBox.slot_index(Vector3i(1, 2, 3)) == (3 * 16 + 2) * 16 + 1, "slot index")
	# The brick of a cell, in the origin's frame (theta the short way round past the seam).
	var p := WorldParams.new()
	var b := VoxelBox.new()
	b.configure(p)
	b._origin = VoxelBox.box_origin_for(Vector2i(100, 200), 410.0)
	check(b.brick_of_cell(Vector2i(100, 200), 410) == Vector3i(6, 12, 25) and b.brick_of_cell(Vector2i(16380, 200), 400) == Vector3i(-1, 12, 25), "brick of cell %s %s" % [b.brick_of_cell(Vector2i(100, 200), 410), b.brick_of_cell(Vector2i(16380, 200), 400)])
	check(b.origin() == Vector3i(-2, 4, 23) and b.bottom() == 23 * 16, "origin and bottom")
	check(b.column_slot(Vector2i(100, 200)) == Vector2i(100, 200) and b.column_slot(Vector2i(16380, 300)) == Vector2i(15 * 16 + 12, 2 * 16 + 12), "column slot %s" % b.column_slot(Vector2i(16380, 300)))
	# A voxel's two words: solid16 | loose16 << 16, material | compaction << 8 | saturation << 16.
	var brick := PackedByteArray()
	brick.resize(VoxelBox.BRICK_BYTES)
	var o := ((5 * 16 + 7) * 16 + 3) * 8
	brick.encode_u32(o, 24248 | (1000 << 16))
	brick.encode_u32(o + 4, 1 | (50 << 8) | (7 << 16) | (1 << 24))
	var v := VoxelBox.voxel(brick, 3, 5, 7)
	check(v.solid == 24248 and v.loose == 1000 and v.material == 1 and v.compaction == 50 and v.saturation == 7 and v.hanging == 1, "voxel %s" % v)
	check(VoxelBox.voxel(brick, 4, 5, 7).solid == 0, "another voxel")
	if failed: quit(1)
	else: print("PASS"); quit(0)
