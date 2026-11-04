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
	# The cave-in's free height (the tunnels design): a step fails only when it is both steeper than the stand
	# slope over the edge distance and taller than the free height.
	check(not VoxelBox.wall_fails(3.0, 1.0, 1.0, 4.0) and VoxelBox.wall_fails(5.0, 1.0, 1.0, 4.0) and not VoxelBox.wall_fails(0.9, 1.0, 1.0, 0.0), "wall_fails")
	# The Materials block of box_sand.glsl: tan of the stand slopes dry and saturated, the swell, the free
	# heights dry and saturated (the roof spans), per material.
	b.materials = load("res://terrain/materials.tres")
	var m := b.material_table()
	check(m.size() == 80 and absf(m.decode_float(0) - tan(deg_to_rad(45.0))) < 1e-6 and absf(m.decode_float(4) - tan(deg_to_rad(70.0))) < 1e-5 \
			and absf(m.decode_float(16) - tan(deg_to_rad(35.0))) < 1e-6 and m.decode_float(32) == 1.25 and absf(m.decode_float(44) - 1.6) < 1e-6 \
			and m.decode_float(48) == 4.0 and m.decode_float(52) == 6.0 and m.decode_float(64) == 1.5 and m.decode_float(68) == 2.0, "box material table")
	# The activity bookkeeping without a device: a flagged slot's brick (in the origin's frame) is active with
	# quiet 0, settles after settle_time, at most MAX_ACTIVE_BRICKS at once.
	b.tool_params = ToolParams.new()
	var flags := PackedInt32Array()
	flags.resize(VoxelBox.SLOTS)
	flags[VoxelBox.slot_index(VoxelBox.slot_of(Vector3i(6, 12, 25)))] = 1
	check(b.settle(0.5, flags).is_empty() and b.is_active(Vector3i(6, 12, 25)) and b.active_bricks().size() == 1, "a flagged slot's brick is active")
	flags.fill(0)
	check(b.settle(0.6, flags).is_empty() and b.is_active(Vector3i(6, 12, 25)), "quiet under settle_time stays active")
	check(b.settle(0.5, flags) == [Vector3i(6, 12, 25)] and not b.has_active(), "settled after settle_time")
	for i in VoxelBox.MAX_ACTIVE_BRICKS + 10:
		flags[i] = 1
	var out := b.settle(0.0, flags)
	check(b.active_bricks().size() == VoxelBox.MAX_ACTIVE_BRICKS and out.size() == 10, "capped at %d: %d active, %d out" % [VoxelBox.MAX_ACTIVE_BRICKS, b.active_bricks().size(), out.size()])
	b.drop(b.active_bricks())
	b.activate_cells([Vector2i(100, 200)])
	check(b.active_bricks().size() == 4 and b.is_active(Vector3i(6, 12, 23)) and b.is_active(Vector3i(6, 12, 26)), "activate_cells wakes a column's four bricks")
	# Chunks of 16 m (the tunnels design's drawing and colliding; a brick column): the chunk of a cell, and the
	# touched chunks from the chunk words the pack and the unpack flag (a word per chunk slot, chunk mod 32
	# along each axis; bit 1 a column with a gap in the box's height range), resolved to world chunks within
	# the box, theta wrapped: the box under the origin (-2, 4, 23) spans the chunks [-2, 14) x [4, 20).
	check(VoxelBox.chunk_of_cell(Vector2i(100, 200)) == Vector2i(6, 12) and VoxelBox.chunk_of_cell(Vector2i(31, 63)) == Vector2i(1, 3), "chunk of cell")
	var words := PackedInt32Array()
	words.resize(VoxelBox.CHUNK_SLOTS)
	words[6 * 32 + 3] = 2
	words[9 * 32 + 30] = 3
	words[9 * 32 + 14] = 2  # chunk 14: outside the box
	words[0] = 1  # packed without a gap: not touched
	var touched := b.touched_from(words)
	check(touched.size() == 2 and touched[0] == Vector2i(3, 6) and touched[1] == Vector2i(1022, 9), "touched chunks %s" % [touched])
	if failed: quit(1)
	else: print("PASS"); quit(0)
