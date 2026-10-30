extends SceneTree

var failed := false

func check(ok: bool, msg: String) -> void:
	if not ok:
		push_error(msg)
		failed = true

func _initialize() -> void:
	# Activity bookkeeping without a RenderingDevice: a 1024 window (64 slots) with its residency set by hand.
	var p := WorldParams.new()
	var w := TerrainWindow.new()
	w.configure(p, 1024, 1.0)
	w.center_tile = Vector2i(10, 20)
	for t in w.wanted_tiles(w.center_tile): w._resident[w.slot_of(t)] = t
	var sim := TerrainSim.new()
	sim.params = ToolParams.new()
	var flags := PackedInt32Array(); flags.resize(64)
	var s := w.slot_of(Vector2i(10, 20))
	flags[s.y * 8 + s.x] = 1
	check(sim.settle(w, 0.5, flags).is_empty() and sim.is_active(Vector2i(10, 20)) and sim.active_tiles().size() == 1, "a flagged slot's tile is active")
	flags.fill(0)
	check(sim.settle(w, 0.6, flags).is_empty() and sim.is_active(Vector2i(10, 20)), "quiet under settle_time stays active")
	check(sim.settle(w, 0.5, flags) == [Vector2i(10, 20)] and not sim.has_active(), "settled after settle_time, returned to pack")
	flags[s.y * 8 + s.x] = 2
	sim.settle(w, 0.0, flags)
	check(sim.is_active(Vector2i(10, 20)), "the neighbour bit activates")
	flags.fill(0)
	flags[w.slot_of(Vector2i(10, 20)).y * 8 + w.slot_of(Vector2i(10, 20)).x] = 1
	sim.settle(w, 0.0, flags)
	# At most MAX_ACTIVE: 20 more flagged slots keep 16 tiles active and hand the quietest 5 over for packing.
	for i in 20: flags[i + 8] = 1
	var out := sim.settle(w, 0.0, flags)
	check(sim.active_tiles().size() == TerrainSim.MAX_ACTIVE and out.size() == 5, "capped at %d: %d active, %d out" % [TerrainSim.MAX_ACTIVE, sim.active_tiles().size(), out.size()])
	sim.drop(sim.active_tiles())
	check(not sim.has_active(), "drop")
	# activate: the CPU-side activation for a lifted obstacle; resident tiles only.
	sim.activate([Vector2i(10, 20), Vector2i(999, 999)])
	check(sim.is_active(Vector2i(10, 20)) and sim.active_tiles().size() == 1, "activate resident tiles only")
	sim.drop(sim.active_tiles())
	# A landing from before a window move ignores the slots the move changed (they name other tiles now) and
	# keeps the rest, and its absorbed water counts: flags at slot (0, 0), evicted, and (1, 1), kept.
	var stale := PackedByteArray(); stale.resize(65 * 4); stale.encode_u32(0, 1); stale.encode_u32(9 * 4, 1)
	stale.encode_u32(64 * 4, 2000000)
	sim.invalidate([Vector2i(0, 0)])
	sim._on_stats(stale, 0)
	check(sim.settle(w, 0.0, sim._flags).is_empty() and not sim.is_active(w.tile_at(Vector2i(0, 0))) and sim.is_active(w.tile_at(Vector2i(1, 1))) \
			and sim.active_tiles().size() == 1 and is_equal_approx(sim.absorbed, 2.0), "a stale landing's evicted slots are ignored, its others count")
	sim.drop(sim.active_tiles())
	sim._on_stats(stale, 1)
	check(sim.settle(w, 0.0, sim._flags).is_empty() and sim.is_active(w.tile_at(Vector2i(0, 0))), "a current landing counts")
	check(sim.stats_landed == 2, "landings are counted")
	sim.drop(sim.active_tiles())
	# A flag on a slot with no resident tile is ignored.
	w._resident.clear()
	flags.fill(0); flags[3] = 1
	check(sim.settle(w, 0.0, flags).is_empty() and not sim.has_active(), "no tile, no activity")
	# invalidate asks for the stats at the old generation before it bumps it: a stamp's flag in flight for an
	# evicted slot is consumed by that request and ignored when it lands (the slot changed), instead of riding
	# the move frame's readback, asked at the new generation, onto the tile that takes the slot. Without a
	# device the request is recorded and skipped.
	var reads := sim.stats_reads
	var gen := sim._generation
	sim.invalidate([Vector2i(2, 2)])
	check(sim.stats_reads == reads + 1 and sim.last_asked_generation == gen and sim._generation == gen + 1, "invalidate asks once, at the old generation, then bumps it")
	# The push constants of sim.glsl: 112 bytes with the tunables at their offsets.
	w.configure(p, 512, 1.0)
	sim.materials = load("res://terrain/materials.tres")
	var b := sim._params(w, Vector2i(3, 4), 1, 1)
	check(b.size() == 112 and b.decode_s32(0) == 3 and b.decode_s32(20) == 4 and b.decode_s32(24) == 1 and b.decode_s32(28) == 1 \
			and b.decode_float(60) == 0.125 and absf(b.decode_float(76) - tan(deg_to_rad(35.0))) < 1e-6 \
			and absf(b.decode_float(84) - tan(deg_to_rad(20.0))) < 1e-6 and absf(b.decode_float(88) - 0.2) < 1e-6 \
			and b.decode_float(96) == 0.0 and b.decode_float(104) == 3.0 and absf(b.decode_float(108) - 1e-4) < 1e-10, "sim push constants")
	if failed: quit(1)
	else: print("PASS"); quit(0)
