# Terrain Edits Implementation Plan (version A)

> Not chosen. The comparison is in [review-terrain-edits.md](review-terrain-edits.md); the chosen plan is [2026-10-27-terrain-edits-C.md](2026-10-27-terrain-edits-C.md), which absorbed this plan's `--blackout` smoke route, 30 s autosave and crosshair aim. Kept as the fallback if an in-place collider rebake is preferred to C's edit shape (see the review's last paragraph).

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A per-cell edit of the terrain survives the window scrolling away and back and a restart, is drawn by the detail pass and stood on by the collider, and the collider keeps up with edits at a hand tool's rate without a visible hitch.

**Architecture:** Edits are absolute per-cell overrides held as one dense 393,216-byte blob per edited 128-cell tile, all eight fields plus a `flags` byte. For resident tiles the GPU window is the truth: a stamp pass applies an op (a disc lowered or raised) to the window textures in place and sets each cell's `EDITED` flag; a snapshot pass reads the tile's flagged cells back asynchronously into the tile's blob; `detail.glsl` writes a blob's flagged cells over its own output whenever the tile regenerates, inside the same dispatch. The collider rebakes in place, throttled, after a stamp touches it; the bake shader is rewritten for occupancy. Blobs persist as one zstd file per tile under the world's `tiles/` directory.

**Tech Stack:** Godot 4.7.2 standard build, Forward+, Jolt, GDScript, GLSL compute on the main `RenderingDevice` (storage buffers for upload and readback, `buffer_update`, `buffer_get_data_async`), `HeightMapShape3D`, `FileAccess.open_compressed`.

**Spec:** No spec is reachable for this slice. The plan argues from three documents, which travel with it: the follow-ups doc that sets the scope, [docs/superpowers/plans/2026-10-27-terrain-slice-1-followups.md](2026-10-27-terrain-slice-1-followups.md) (R1, R3 and the folded items R4 to R7, topsoil, bake occupancy, second patch); the slice 1 design, the authority on conventions and the datum, [docs/superpowers/specs/2026-10-24-terrain-slice-1-design.md](../specs/2026-10-24-terrain-slice-1-design.md) (sections 4.2, 6.2, 7, 9, 12); and the research doc sections 6.1, 6.6 and 6.8, [docs/terrain-research.md](../../terrain-research.md) (span columns, staging and SSBO atomics, the CPU boundary). Where this plan's Decisions depart from a sentence in those documents they say so.

## Decisions

Each decision names the alternative and why it lost. "Blob" below means one tile's edit record.

- **D1. Edit storage: dense per tile, keyed by tile, all eight fields plus flags.** A blob is `TerrainEdits.BLOB_BYTES = 6 planes × 16384 cells × 4 B = 393,216 B`: planes 0 to 4 are `surface`, `bedrock_top`, `clay_bottom`, `clay_top`, `water_surface` as float32 metres (the window stores heights as `R32_SFLOAT`, so the override is bit-exact); plane 5 is a packed `u32` = `material | compaction << 8 | saturation << 16 | flags << 24`. Cell `(lx, ly)` of the tile is index `ly * 128 + lx`, the same order as `gl_GlobalInvocationID.xy` in `detail.glsl`. A cell is overridden only where `flags & EDITED`; unedited cells hold zeros. Keyed by world tile `Vector2i(ti, tj)` in `TerrainEdits.blobs`. Alternative: a sparse list of `(cell, column)` records, on the CPU as a Dictionary or on the GPU via an SSBO append with atomics. Rejected: its worst case (a fully dug tile) is 524 KB, larger than dense; records need deduplication so the latest write wins; and a CPU list puts a per-cell GDScript loop on the write path. Dense with a mask is a fixed layout that `buffer_update` and `buffer_get_data_async` move whole, and zstd makes the zeros free on disk. Memory: CPU 393 KB per edited tile (a hundred edited tiles is 39 MB; `# ponytail: unbounded, evict blobs to disk when a world has thousands`); GPU upload ring of `slots` blobs (1.5 MB at a 512 window, 3 MB at 1024), snapshot ring of 4 blobs plus 1 flush blob (1.9 MB); the window gains one `R8` field (0.26 MB at 512, 1 MB at 1024), so the window is 6.25 MB at 512 and 25 MB at 1024 (slice 1 chose `R32_SFLOAT` heights over the spec's `R16_UNORM`, which is why the spec's 4 and 16 MB are already exceeded; this plan does not revisit that). Disk: one `tiles/<ti>_<tj>.edits` file per edited tile, zstd, a few KB for hand edits.
- **D2. The GPU window is the truth for resident tiles; blobs are snapshots of it.** A stamp changes the window in place on the GPU and the tile is marked dirty; a snapshot pass copies the tile's flagged cells into a readback SSBO and `buffer_get_data_async` delivers the blob two frames later. Alternative: CPU-authoritative blobs, with ops applied in GDScript and uploaded. Rejected: the CPU does not know a cell's current values (it holds the 32 m macro maps; the detail pass runs only on the GPU), so the first op on a tile needs a readback anyway, and the research doc's architecture (6.8, "uploads are op lists… one kernel applies them") is GPU-side ops; a CPU path would be thrown away by the auger slice.
- **D3. The override runs inside `detail.glsl`, not as a second pass.** The detail pass binds the upload ring as set 1 binding 9 and a push constant `edit_index` (−1 for no blob); at the end of `main` it replaces its nine stores with the blob's values where the cell's `EDITED` bit is set. R1's "same compute list" is therefore the same dispatch. Alternative: an `apply_edits.glsl` after a barrier. Rejected: one more shader, pipeline and uniform set for ten lines of GLSL.
- **D4. The edit API is a GPU op.** `Terrain.edit(theta, z, radius, dh) -> bool` applies one disc op through `TerrainWindow.stamp(i, j, radius, dh)`, the only op kind in this slice (surface ± a cosine-falloff disc, strata and material re-clamped). Absolute per-cell writes from the CPU exist for tests and rare tools: `TerrainEdits.set_cell(tile, local, column)` then `TerrainWindow.regenerate(tile)`, valid only after `flush_edits()` so no un-snapshotted stamp is lost. The real tools (auger, tamper, compaction stamps) are a later slice and will be more op kinds in `stamp.glsl` or a sibling kernel, as the research doc's op list.
- **D5. The debug edit is two keys at the crosshair.** `debug_edit.gd` under `Main`: `G` lowers and `H` raises a disc of radius 4 cells by 0.5 m per op, 10 ops per second while held, centred on the ground under the screen centre found by a physics ray against the live collider (exact, and only where the collider exists, which is where edits mean anything). Alternative: Ctrl-click at the cursor. Rejected: Ctrl is taken by teleport, and a held key gives the 10 Hz hand-tool rate the collider must keep up with.
- **D6. R6 is a flag bit in a new `flags` window field.** `flags` is the ninth window field (`R8_UNORM`): bit 0 `EDITED` (the cell is read from the edit store), bit 1 `ROCK_FACE` (the detail pass set `bedrock_top = surface` because the face is steeper than 60°; a reader of bedrock gradients treats the jump as this flag, not a stratum). A stamp sets `EDITED` and clears `ROCK_FACE` (after a dig the cell's column is explicit). Alternatives: material id 3 "rock face" (changes with every edit and overloads a field two shaders read), or a documented rule that readers recompute the slope (not self-contained; wrong after an edit changes the slope). The field is needed for `EDITED` anyway, so the second bit is free.
- **D7. R3: rebake in place, throttled, only when touched; bake shader at full occupancy; the 2.8 ms `map_data` is measured and accepted up to 4 ms.** A stamp that touches the live patch (Chebyshev distance from the centre within 128 m plus the radius) sets `Terrain._edit_pending`; `_process` rebakes at the *same* centre at most every `EDIT_REBAKE_INTERVAL = 0.1 s` and never while a bake is in flight, so the frame never changes, `covers` never flips, and the player is never held by a rebake. The CPU cost is one `map_data` assignment per rebake (Jolt rebuilds the shape; GDScript cannot reduce it): at most 10 per second, each under the spec's 4 ms hitch budget for a window step (measured in Task 10). Alternatives: a second small `HeightMapShape3D` over the edit zone (rejected: overlapping heightfields cannot *lower* ground, the big patch still holds the old surface; NaN-holing the big patch costs the same full rebuild); rebaking every stamp (rejected: 60 × 2.8 ms). Occupancy: the bake becomes one workgroup of 257 threads per row, the row's mapped samples in shared memory, one output column per thread with the same full-scan upper-envelope rule as `Cyl.bake_row` (expected under 0.1 ms, from 0.4 to 1.8 ms). Alternatives: a binary search per column (rejected: needs a fold-back window assumption to be provably right), a two-pass map-then-max (rejected: a scratch buffer and a barrier for the same result).
- **D8. R4: the far window keeps ignoring edits; a documented limit.** The 8 m far window regenerates from the macro maps. A hand-tool edit under 8 m cannot show at 8 m sampling beyond 256 m, so nothing is visible today. Sketch for when excavations get large: have the snapshot pass also emit a 16 × 16 downsample of the tile's flagged cells (6 KB), and bind the 64 mini-blobs an 8 m tile covers. The same limit applies to the collider bake's macro fallback outside the window (the patch's outer samples at low ground reach past the window on one side): an edit there is missed until the window moves. Both are stated in the code comments; no task.
- **D9. R5: the headless half pins `ColliderPatch.covers` and `Terrain._hold_body` on stubs; the windowed half is a `--blackout` route in `smoke_run.gd`** that turns `RenderingServer.render_loop_enabled` off for 10 s while the player runs, then asserts held at least once, never fallen, released after. One task owns both (Task 2), before any collider change.
- **D10. R7: `Cyl.theta_of` returns strictly inside `[0, TAU)`; no consumer loses a wrap.** The two `posmod(floori(theta / dtheta), n_theta)` sites (`Terrain.viewer_cell`, `ColliderPatch.rebuild`) guard the float division reaching `n_theta`, a different hazard, and are folded into a new `WorldParams.cell_of(theta, z)` that the stamp also needs (a fifth copy of that line would be worse; the follow-ups' minor item is pulled in for that reason only). `smoke_run`'s `wrapf` of a difference, `LightBar.day`'s cosine and `Emitter`'s sine stay as they are.
- **D11. Topsoil thins with macro slope through one knob.** `WorldParams.soil_slope_deg = 40`: in `_strata` the cover depth `D` scales by `clamp(1 − (slope_deg / soil_slope_deg)², 0, 1)` with `slope_deg` from central differences over the two macro neighbours, so half the angle keeps three quarters of the cover and the knob angle is bare rock. Alternative: linear, or two knobs (full-depth and bare angles). Rejected: linear halves hills' cover at 20°; two knobs for a tuning pass the user has not seen yet.
- **D12. A second collider patch per rigid body is deferred; uncovered rigid bodies are held instead.** Boxes join a `ground_bodies` group when spawned; `Terrain._process` holds any group member the live patch does not cover (`process_mode = DISABLED`, which removes it from the physics space, as the player's hold does) and releases it when covered. So boxes the player flies away from stop where they are instead of falling to the hull, and resume when the player returns; one frozen mid-air is the stated cost. Sketch for the per-body design, so the next slice can pick it up: `ColliderPatch` takes `samples` in `_init` (the bake shader's `N` becomes a push constant and the staging texture is sized to match); `Terrain` keeps a `Dictionary` body → patch for group members outside the main patch, 65 × 65 samples (64 m) centred on the body, rebuilt when the body moves 16 m from its centre, 16 KB readback, about 0.2 ms of `map_data`; a body's patch is freed when the main patch covers it again; a body is held only while neither covers it. Overlap between a body patch and the main patch is the same surface in two tangent frames (millimetre differences), so a resting box sees no seam.
- **D13. Persistence: flush and save on `_exit_tree`, autosave landed blobs every 30 s.** `SceneTree.quit()` does not send `WM_CLOSE_REQUEST`, so `Terrain._exit_tree` is the one hook that both the close button and a scripted quit reach while the `RenderingDevice` is still alive; it runs a synchronous snapshot of dirty and in-flight tiles (`flush_edits`, a stall of a few ms) and writes unsaved blobs. The autosave writes only blobs that have landed (no stall), at most a few 393 KB zstd compressions. Alternative: save only at quit. Rejected: a crash in a GPU-heavy dev build would lose everything.
- **D14. Snapshot cadence: 30 frames after a tile first became dirty, at eviction, at flush.** A ring of 4 readback blobs; if the ring is full, a dirty tile waits, and an evicted dirty tile takes the synchronous flush slot instead (`# ponytail: sync fallback stalls; grow the ring if teleports show it`). Each snapshot carries a generation number so a late landing never overwrites a newer blob. A tile re-entering the window while its eviction snapshot is in flight is regenerated again when the blob lands.

## Global Constraints

- Godot 4.7.2 standard build only, no GDExtension. Forward+, Jolt, GDScript plus GLSL compute on the main `RenderingDevice`.
- Grid and datum as slice 1: `Δθ = 2π / 16384`, 1 m cells, heights radial from the hull in metres, `h_sea = 400`, `H_mtn = H_ref · g_ref / g_sea`; 512 window (`terrain/window_size`, 1024 is the option), tiles of 128, 4 × 4 tile ring buffer at 512; window heights `R32_SFLOAT`, byte fields `R8_UNORM`; ordering invariant `0 ≤ bedrock_top ≤ clay_bottom ≤ clay_top ≤ surface` holds after every edit.
- Collider patch 257 × 257 samples at 1 m, rebuilt when the viewer is more than 64 m from its centre; coverage is 124 m Chebyshev; the ground body is held while no live patch covers it.
- No per-cell GDScript loop on any per-frame path. A debug readback (`TerrainWindow.debug_read`, the P dump, the drivers' probes) may loop and stall; nothing in `_process` may.
- Everything in the world is a child of `Station`; terrain code works in station-local `(theta, z)` only.
- Headless tests cannot create a `RenderingDevice`: they follow the existing pattern (`extends SceneTree`, `_initialize`, `check`, print `PASS`, `quit`) and run via `cd godot && sh tests/run.sh`. GPU work is verified by short windowed drivers that print numbers and save screenshots under `user://debug/`; a windowed run opens a window on the user's screen, so every driver quits by itself within about a minute.
- Budgets (slice 1 spec section 12) still apply: detail under 2 ms per tile, bake under 1 ms, GPU frame mean under 6 ms at 1440p, hitch on a window step or origin shift under 4 ms. GPU times come from `RenderingDevice.capture_timestamp` pairs read by `timing_overlay.gd`, and only under `--rendering-driver vulkan` (MoltenVK); Metal returns zeros.
- Commit after each task with the message given. Do not run two windowed drivers at once.

## Review Focus

1. A stamp disc straddling θ = 2π or the window's toroidal edge: both tiles' texels must be written and both tiles dirtied, so neither half is lost at eviction. Pinned by the `tiles_touched` seam test and edit_check's `--seam` step, both Task 6.
2. A tile evicted with its snapshot in flight and re-entered before the blob lands (teleport away and straight back): the fresh blob must be applied when it lands, not the stale one the re-entry found. Pinned by edit_check's race step (Task 7), probed through the collider in Task 8.
3. Quitting within a frame of the last stamp: the synchronous flush must capture the GPU state and the next run must show the hole. Pinned by edit_check `--verify` (Task 7, extended in Task 8).
4. Digging under the player's own feet: the player must land in the hole after the throttled rebake, never be held (the patch frame does not change) and never be launched; a stamp during an in-flight positional bake must not be lost. Pinned by edit_check's feet step (Task 8).
5. An edit aimed outside the resident window or past a station end: nothing written, nothing dirtied, no error, `edit` returns false. Pinned by the `tiles_touched` end-row tests and edit_check's outside step (Task 6).

## File structure

| file | role |
|---|---|
| `godot/terrain/terrain_edits.gd` (new) | `TerrainEdits`: the CPU store of tile blobs, layout constants, cell get/set; headless |
| `godot/terrain/shaders/stamp.glsl` (new) | one disc op applied to the window in place |
| `godot/terrain/shaders/snapshot.glsl` (new) | one tile's flagged cells copied into a readback blob |
| `godot/terrain/debug_edit.gd` (new) | G/H debug digging at the crosshair |
| `godot/terrain/edit_check.gd`, `edit_check.tscn` (new) | the windowed driver for edits: digs, scrolls, restarts, probes the collider, prints timings |
| `godot/terrain/terrain_window.gd` | `flags` field, upload ring, stamp and snapshot dispatch, dirty tracking, flush |
| `godot/terrain/shaders/detail.glsl` | writes `flags`, reads the upload ring |
| `godot/terrain/shaders/collider_bake.glsl` | row per workgroup, column per thread |
| `godot/terrain/collider_patch.gd` | `touches`, `is_pending`, `half_n`, `map_data` timing |
| `godot/terrain/terrain.gd` | `edit`, edit rebake, snapshot and save cadence, group hold |
| `godot/terrain/world_io.gd` | edit files |
| `godot/terrain/cyl.gd`, `world_params.gd`, `macro_generator.gd` | R7, `cell_of`, topsoil knob |
| `godot/terrain/smoke_run.gd`, `timing_overlay.gd`, `debug_window.gd`, `debug_window_dump.gd`, `godot/emitter.gd`, `godot/main.tscn` | blackout route, overlay fields, spike check, group registration, scene nodes |
| `godot/tests/test_hold_rule.gd`, `test_terrain_edits.gd` (new); `test_cylinder_math.gd`, `test_macro_maps.gd`, `test_macro_generator.gd`, `test_terrain_window_math.gd`, `test_emitter.gd` | headless tests |

---

### Task 1: theta_of range, cell_of, topsoil on slopes

**Files:**
- Modify: `godot/terrain/cyl.gd:12-14`, `godot/terrain/world_params.gd` (new export and function), `godot/terrain/terrain.gd:297-301` (`viewer_cell`), `godot/terrain/collider_patch.gd:96-102` (`rebuild`), `godot/terrain/macro_generator.gd:475-537` (`_strata`)
- Test: `godot/tests/test_cylinder_math.gd`, `godot/tests/test_macro_maps.gd`, `godot/tests/test_macro_generator.gd`

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `Cyl.theta_of(p: Vector3) -> float`, strictly in `[0, TAU)`: `fposmod` as today, then `0.0` where the result reached `TAU`.
  - `WorldParams.cell_of(theta: float, z: float) -> Vector2i` = `(posmod(floori(theta / dtheta()), n_theta()), floori(z + length / 2.0))`; `viewer_cell` and `rebuild` call it instead of their own copies.
  - `@export var soil_slope_deg: float = 40.0` on `WorldParams`, doc comment: "Macro slope in degrees at which the soil cover reaches zero; the cover depth scales by 1 − (slope / soil_slope_deg)², so half the angle keeps three quarters."
  - In `_strata`, after `d` is drawn from `bedrock_depth` and before the island taper: `slope_deg = rad_to_deg(atan(sqrt(gx² + gy²) / (2 · macro_cell)))` with `gx`, `gy` the central differences of `surface` over the θ-wrapped and z-clamped neighbours exactly as `_spawn` computes them (`macro_generator.gd:640-641`); `d *= clampf(1.0 - (slope_deg / p.soil_slope_deg) ** 2, 0.0, 1.0)`.

- [ ] **Step 1: Write the failing tests**

Append to `test_cylinder_math.gd` before the station-length check:

```gdscript
	# theta_of is strictly inside [0, TAU): a hair antispinward of the bottom must not round up to TAU.
	for q: Vector3 in [Vector3(-1e-20, -3200, 0), Vector3(-0.0, -3200, 0), Vector3(0, -3200, 0)]:
		var th := Cyl.theta_of(q)
		check(th >= 0.0 and th < TAU, "theta_of %s = %.17f" % [q, th])
```

Append to `test_macro_maps.gd` after the `h_mtn` check (default world):

```gdscript
	check(p.cell_of(0.0, -p.length / 2.0) == Vector2i(0, 0), "first cell")
	check(p.cell_of(TAU, -p.length / 2.0) == Vector2i(0, 0), "TAU wraps to cell 0")
	check(p.cell_of(-0.5 * p.dtheta(), 0.0) == Vector2i(p.n_theta() - 1, 16000), "negative theta wraps")
	check(p.cell_of(1.5 * p.dtheta(), 123.7) == Vector2i(1, 16123), "cell from theta and z")
```

Append to `test_macro_generator.gd` after the clay-lens check (`m` is the seed-7 world, `p` its params, default `soil_slope_deg`):

```gdscript
	# Topsoil thins with macro slope: a land cell at or over soil_slope_deg is bare rock, and turning the
	# rule off (an unreachable angle) never raises bedrock anywhere and lowers it somewhere.
	var grade := tan(deg_to_rad(p.soil_slope_deg)) * 2.0 * p.macro_cell
	for y in range(1, h - 1): for x in w:
		if m.region.get_pixel(x, y).r8 == 0: continue
		var gx := m.surface.get_pixel(posmod(x + 1, w), y).r - m.surface.get_pixel(posmod(x - 1, w), y).r
		var gy := m.surface.get_pixel(x, y + 1).r - m.surface.get_pixel(x, y - 1).r
		if gx * gx + gy * gy >= grade * grade:
			check(m.bedrock_top.get_pixel(x, y).r >= m.surface.get_pixel(x, y).r - 1e-3, "steep cell %d %d keeps soil" % [x, y])
	var loose := small_params(7); loose.soil_slope_deg = 1e9
	var ml := MacroGenerator.new().generate(loose)
	var thinned := 0
	for y in h: for x in w:
		var dd := m.bedrock_top.get_pixel(x, y).r - ml.bedrock_top.get_pixel(x, y).r
		check(dd >= -1e-3, "slope rule raised soil at %d %d" % [x, y])
		if dd > 1.0: thinned += 1
	check(thinned > 0, "slope rule had no effect")
```

- [ ] **Step 2: Run them to verify they fail**

Run: `cd godot && for t in test_cylinder_math test_macro_maps test_macro_generator; do godot --headless --path . --fixed-fps 60 --quit-after 7200 -s res://tests/$t.gd 2>&1 | tail -n 3; done`
Expected: `cell_of` not found; `soil_slope_deg` not found; the `theta_of` check fails for the `-1e-20` point.

- [ ] **Step 3: Implement the three changes**

`theta_of` is two lines. `cell_of` replaces the bodies at `terrain.gd:301` and `collider_patch.gd:101` (keep the comment about the float division on `cell_of`). The `_strata` change is three lines inside the existing per-cell loop; the slope uses the same neighbour indexing as `_spawn`.

- [ ] **Step 4: Run the suite**

Run: `cd godot && sh tests/run.sh`
Expected: every test `PASS`.

- [ ] **Step 5: Commit**

```bash
git add godot/terrain/cyl.gd godot/terrain/world_params.gd godot/terrain/terrain.gd godot/terrain/collider_patch.gd godot/terrain/macro_generator.gd godot/tests/test_cylinder_math.gd godot/tests/test_macro_maps.gd godot/tests/test_macro_generator.gd
git commit -m "Terrain: theta_of strictly inside [0, TAU), WorldParams.cell_of, topsoil thins with macro slope"
```

---

### Task 2: Hold-rule tests (R5)

**Files:**
- Create: `godot/tests/test_hold_rule.gd`
- Modify: `godot/terrain/smoke_run.gd` (a `--blackout` route)

**Interfaces:**
- Consumes: `Terrain._hold_body(hold: bool)`, `Terrain.body_held(held)`, `Terrain._body`, `ColliderPatch.covers`, `ColliderPatch.set_frame`, all as they stand.
- Produces: `smoke_run.gd` with user arg `--blackout`: route = hold 2 s; `RenderingServer.render_loop_enabled = false`; phase `blackout`, 10 s with `W` held; `render_loop_enabled = true`; phase `recover`, 3 s; then `push_error` unless `_holds >= 1`, `_stats.blackout.low >= FELL` and `_holding == false`; then the summary and quit. The default route is unchanged.

- [ ] **Step 1: Write the failing headless test**

`godot/tests/test_hold_rule.gd`:

```gdscript
extends SceneTree

var failed := false

func check(ok: bool, msg: String) -> void:
	if not ok:
		push_error(msg)
		failed = true

func _initialize() -> void:
	var t := Terrain.new()
	var body := Node3D.new()
	t._body = body
	var seen: Array[bool] = []
	t.body_held.connect(func(h: bool) -> void: seen.append(h))
	t._hold_body(false)
	check(seen.is_empty() and body.process_mode == Node.PROCESS_MODE_INHERIT, "releasing an unheld body does nothing")
	t._hold_body(true)
	check(seen.size() == 1 and seen[0] and body.process_mode == Node.PROCESS_MODE_DISABLED, "held")
	t._hold_body(true)
	check(seen.size() == 1, "holding twice emits once")
	t._hold_body(false)
	check(seen.size() == 2 and not seen[1] and body.process_mode == Node.PROCESS_MODE_INHERIT, "released")
	# A body something else disabled (the FlyCamera freezing the player) is not Terrain's to hold or release.
	body.process_mode = Node.PROCESS_MODE_DISABLED
	t._hold_body(true)
	t._hold_body(false)
	check(seen.size() == 2 and body.process_mode == Node.PROCESS_MODE_DISABLED, "a body held elsewhere is left alone")
	# Coverage drives the hold: 124 m of the 128 m half extent, and nothing before the first frame.
	var patch := ColliderPatch.new()
	check(not patch.covers(Vector3.ZERO), "no frame, no cover")
	patch.set_frame(0.0, 0.0, 3200.0)
	check(patch.covers(patch.transform * Vector3(124, 0, -124)) and not patch.covers(patch.transform * Vector3(125, 0, 0)), "coverage edge")
	patch.free()
	body.free()
	t.free()
	if failed: quit(1)
	else: print("PASS"); quit(0)
```

- [ ] **Step 2: Run it**

Run: `cd godot && godot --headless --path . --fixed-fps 60 --quit-after 7200 -s res://tests/test_hold_rule.gd`
Expected: `PASS` (this pins existing behaviour; if any check fails, the rule has a bug and the fix belongs in this task).

- [ ] **Step 3: Add the blackout route to `smoke_run.gd`**

A `_route_blackout()` chosen in `_ready` when `--blackout` is among the user args, built from `_run`, `_summary` and the existing counters; the three assertions are `push_error` lines prefixed `blackout:`. The `blackout` phase row shows GPU `n/a`, which is expected.

- [ ] **Step 4: Run the windowed check**

Run: `cd godot && godot --path . res://terrain/smoke.tscn -- --blackout`
Expected: about 15 s; the window freezes for 10 s; the summary shows `held: 1 times` with a nonzero frame count, the `blackout` row without `FELL THROUGH`, the `recover` row, and no `ERROR` lines. The player stands where it was held, about 124 m spinward of spawn, once the loop resumes.

- [ ] **Step 5: Commit**

```bash
git add godot/tests/test_hold_rule.gd godot/terrain/smoke_run.gd
git commit -m "Terrain: hold-rule tests, headless and a render-loop blackout route in the smoke run"
```

---

### Task 3: The `flags` window field (R6)

**Files:**
- Modify: `godot/terrain/terrain_window.gd:12-17` (constants), `:81-93` (textures), `godot/terrain/shaders/detail.glsl:21-28, 258-343`, `godot/terrain/debug_window_dump.gd`
- Test: `godot/tests/test_terrain_window_math.gd`; windowed `debug_window.tscn`

**Interfaces:**
- Consumes: `TerrainWindow.FIELDS`, the set 1 image bindings of `detail.glsl`.
- Produces:
  - `TerrainWindow.FIELDS` gains a ninth entry `"flags"` (`R8_UNORM`, binding 8); `const FLAG_EDITED := 1`, `const FLAG_ROCK_FACE := 2`, with the doc comment of D6 on `FIELDS`. The texture loop in `_setup_rd` already makes index ≥ 5 an `R8`.
  - `detail.glsl`: `layout(set = 1, binding = 8, r8) uniform restrict writeonly image2D o_flags;` stored as `flags / 255.0`; `flags = face ? 2 : 0`. `bedrock_top` on a face stays `h` (unchanged).
  - `TerrainWindow.debug_read(field: String) -> PackedByteArray`: synchronous `texture_get_data` of the field (debug only, stalls); the dump uses it.
  - `debug_window_dump.gd` also reads `flags` and `bedrock_top` and prints `rock faces N, inconsistent M`, where `M` counts flagged cells with `material != 2` or `bedrock_top != surface`. It also prints the centre cell of the window: `centre cell tile %s local (64, 64): surface %.3f bedrock %.3f water %.3f material %d flags %d` (used by Task 5).

- [ ] **Step 1: Write the failing test**

Append to `test_terrain_window_math.gd` before `if failed:`:

```gdscript
	check(TerrainWindow.FIELDS.size() == 9 and TerrainWindow.FIELDS[8] == "flags", "flags is the ninth field")
	check(TerrainWindow.FLAG_EDITED == 1 and TerrainWindow.FLAG_ROCK_FACE == 2, "flag bits")
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd godot && godot --headless --path . --fixed-fps 60 --quit-after 7200 -s res://tests/test_terrain_window_math.gd`
Expected: `FLAG_EDITED` not found.

- [ ] **Step 3: Implement**

Shader, constants, `debug_read`, the dump's two new prints. `FarTerrain`'s window goes through the same `_setup_rd`, so it gains the field with no change.

- [ ] **Step 4: Run the suite and the windowed dump**

Run: `cd godot && sh tests/run.sh`
Expected: all `PASS`.

Run: `cd godot && godot --path . res://terrain/debug_window.tscn -- --spawn --auto`
Expected: the dump prints `rock faces N, inconsistent 0` with `N > 0` on the default world near spawn (cliff bands within 256 m; if `N == 0` there, re-run with `--at=0,16000`), the centre-cell line, and no errors.

- [ ] **Step 5: Commit**

```bash
git add godot/terrain/terrain_window.gd godot/terrain/shaders/detail.glsl godot/terrain/debug_window_dump.gd godot/tests/test_terrain_window_math.gd
git commit -m "Terrain: flags window field with EDITED and ROCK_FACE bits"
```

---

### Task 4: The edit store and its files (R1, CPU half)

**Files:**
- Create: `godot/terrain/terrain_edits.gd`
- Modify: `godot/terrain/world_io.gd`
- Test: `godot/tests/test_terrain_edits.gd`

**Interfaces:**
- Consumes: `TerrainWindow.TILE`, `TerrainWindow.FLAG_EDITED`.
- Produces: `class_name TerrainEdits extends RefCounted`:
  - `const CELLS := TerrainWindow.TILE * TerrainWindow.TILE` (16384), `const PLANES := 6`, `const BLOB_BYTES := PLANES * CELLS * 4` (393216), `const FORMAT := 1`.
  - `var blobs := {}` (tile `Vector2i` → `PackedByteArray` of `BLOB_BYTES`), `var unsaved := {}` (tile → `true`).
  - `static func offset(plane: int, local: Vector2i) -> int` = `(plane * CELLS + local.y * TerrainWindow.TILE + local.x) * 4`.
  - `func blob(tile: Vector2i) -> PackedByteArray`: the tile's blob, created zeroed (and marked unsaved) if absent.
  - `func get_cell(tile: Vector2i, local: Vector2i) -> PackedFloat32Array`: nine values `[surface, bedrock_top, clay_bottom, clay_top, water_surface, material, compaction, saturation, flags]`, or empty when the tile has no blob or the cell's `EDITED` bit is clear.
  - `func set_cell(tile: Vector2i, local: Vector2i, column: PackedFloat32Array) -> void`: eight values, stored with `flags = FLAG_EDITED`; marks the tile unsaved.
  - `func store(tile: Vector2i, bytes: PackedByteArray) -> void`: replaces the blob (a landed snapshot); marks unsaved.
- `WorldIO`:
  - `static func save_edits(edits: TerrainEdits, name: String) -> Error`: for each tile in `edits.unsaved`, writes `user://worlds/<name>/tiles/<x>_<y>.edits` with `FileAccess.open_compressed(path, FileAccess.WRITE, FileAccess.COMPRESSION_ZSTD)`: `store_32(TerrainEdits.FORMAT)` then `store_buffer(blob)`; creates `tiles/` if missing; clears `unsaved` on success.
  - `static func load_edits(name: String) -> TerrainEdits`: reads every `tiles/*.edits`; a file that fails to open, whose first word is not `FORMAT` or whose payload is not `BLOB_BYTES` is skipped with `push_warning`; the result has an empty `unsaved`.

- [ ] **Step 1: Write the failing test**

`godot/tests/test_terrain_edits.gd`:

```gdscript
extends SceneTree

var failed := false

func check(ok: bool, msg: String) -> void:
	if not ok:
		push_error(msg)
		failed = true

func _initialize() -> void:
	var e := TerrainEdits.new()
	check(TerrainEdits.BLOB_BYTES == 393216, "blob size")
	check(TerrainEdits.offset(0, Vector2i(0, 0)) == 0 and TerrainEdits.offset(1, Vector2i(3, 2)) == (16384 + 2 * 128 + 3) * 4 \
			and TerrainEdits.offset(5, Vector2i(127, 127)) == 393212, "layout")
	check(e.get_cell(Vector2i(5, 9), Vector2i(1, 1)).is_empty() and e.blobs.is_empty(), "nothing edited, nothing allocated")
	e.set_cell(Vector2i(5, 9), Vector2i(1, 1), PackedFloat32Array([777.125, 700.0, 700.0, 700.0, 0.0, 2, 0, 0]))
	e.set_cell(Vector2i(127, 249), Vector2i(127, 127), PackedFloat32Array([12.5, 0.0, 0.0, 0.0, 400.0, 0, 7, 9]))
	var c := e.get_cell(Vector2i(5, 9), Vector2i(1, 1))
	check(c.size() == 9 and c[0] == 777.125 and c[1] == 700.0 and c[5] == 2 and int(c[8]) == TerrainWindow.FLAG_EDITED, "cell round trip %s" % c)
	check(e.get_cell(Vector2i(5, 9), Vector2i(2, 1)).is_empty(), "neighbour untouched")
	var b := e.blob(Vector2i(5, 9))
	check(b.size() == TerrainEdits.BLOB_BYTES and b.decode_float(TerrainEdits.offset(0, Vector2i(1, 1))) == 777.125, "blob holds the float")
	check(b.decode_u32(TerrainEdits.offset(5, Vector2i(1, 1))) == 2 | (TerrainWindow.FLAG_EDITED << 24), "packed byte lanes")
	var b2 := e.blob(Vector2i(127, 249))
	check(b2.decode_u32(TerrainEdits.offset(5, Vector2i(127, 127))) == 7 << 8 | 9 << 16 | TerrainWindow.FLAG_EDITED << 24, "compaction and saturation lanes")
	check(e.unsaved.has(Vector2i(5, 9)) and e.unsaved.has(Vector2i(127, 249)), "unsaved")
	# Files: one per tile, zstd, small for a nearly empty blob; round trip; a corrupt file is skipped.
	check(WorldIO.save_edits(e, "test_world") == OK and e.unsaved.is_empty(), "save")
	var path := ProjectSettings.globalize_path("user://worlds/test_world/tiles/5_9.edits")
	var on_disk := FileAccess.get_file_as_bytes(path).size()
	check(on_disk > 0 and on_disk < 8192, "small on disk: %d bytes" % on_disk)
	var junk := FileAccess.open("user://worlds/test_world/tiles/3_3.edits", FileAccess.WRITE)
	junk.store_string("junk"); junk.close()
	var l := WorldIO.load_edits("test_world")
	check(l.blobs.size() == 2 and l.unsaved.is_empty(), "loaded %d tiles" % l.blobs.size())
	check(l.get_cell(Vector2i(5, 9), Vector2i(1, 1))[0] == 777.125 and l.get_cell(Vector2i(127, 249), Vector2i(127, 127))[7] == 9, "loaded content")
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://worlds/test_world/tiles/3_3.edits"))
	if failed: quit(1)
	else: print("PASS"); quit(0)
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd godot && godot --headless --path . --fixed-fps 60 --quit-after 7200 -s res://tests/test_terrain_edits.gd`
Expected: `TerrainEdits` not found.

- [ ] **Step 3: Implement `TerrainEdits` and the two `WorldIO` functions**

Encode and decode with `PackedByteArray.encode_float / decode_float / encode_u32 / decode_u32`. `load_edits` lists the directory with `DirAccess.get_files_at` and parses `<x>_<y>` from the file name.

- [ ] **Step 4: Run the suite**

Run: `cd godot && sh tests/run.sh`
Expected: all `PASS`; the `test_terrain_edits` run shows no `WARNING` other than the deliberate junk-file skip.

- [ ] **Step 5: Commit**

```bash
git add godot/terrain/terrain_edits.gd godot/terrain/world_io.gd godot/tests/test_terrain_edits.gd
git commit -m "Terrain: TerrainEdits tile blobs and per-tile edit files"
```

---

### Task 5: The detail pass writes stored edits (R1, GPU half)

**Files:**
- Modify: `godot/terrain/terrain_window.gd` (`edits`, `_edit_buffer`, `_setup_rd`, `_dispatch`, `_push_constants`, `regenerate`, `_notification`), `godot/terrain/shaders/detail.glsl:30-45` (push constants) and the end of `main`, `godot/terrain/terrain.gd:57-77` (`_ready` loads edits), `godot/terrain/debug_window.gd` (`--spike`)
- Test: windowed `debug_window.tscn -- --spike --auto`

**Interfaces:**
- Consumes: `TerrainEdits` (Task 4), `WorldIO.load_edits`.
- Produces:
  - `TerrainWindow.edits: TerrainEdits` (public var; set before `setup`; `null` for the far window). `Terrain._ready` sets `window.edits = WorldIO.load_edits(world_name)` before `window.setup(...)`.
  - `_edit_buffer: RID`, an SSBO of `slots * TerrainEdits.BLOB_BYTES` bytes created in `_setup_rd` by the window that owns the pipeline and shared by a window with a `_source` (bound read-only, never updated by it); freed with the shader's owner.
  - Set 1 of `detail.glsl` gains binding 9, `UNIFORM_TYPE_STORAGE_BUFFER`: `layout(set = 1, binding = 9, std430) readonly buffer Edits { uint words[]; } edits;`. Blob `k` starts at word `k * 6 * 16384`; plane `p` of cell `l = local.y * 128 + local.x` is word `base + p * 16384 + l`; heights via `uintBitsToFloat`.
  - Push constant: the trailing `float pad` becomes `int edit_index` (byte 60); `_push_constants(tile: Vector2i, edit_index: int) -> PackedByteArray`.
  - `detail.glsl` `main`: when `pc.edit_index >= 0` and bit 24 of the cell's packed word is set, the nine `imageStore`s take the blob's values (`material = packed & 0xff`, `compaction = packed >> 8 & 0xff`, `saturation = packed >> 16 & 0xff`, `flags = packed >> 24`) instead of the generated ones.
  - `_dispatch(tiles)`: processes `tiles` in chunks of `slots`; for chunk position `k`, a tile whose `edits.blobs` entry exists gets `_rd.buffer_update(_edit_buffer, k * BLOB_BYTES, BLOB_BYTES, blob)` before the chunk's `compute_list_begin` and `edit_index = k`; others `-1`. One compute list per chunk, the `detail_begin/end` timestamps around all chunks. Tiles write disjoint texels, so no barrier inside a list; the render graph orders a later chunk's `buffer_update` after the earlier chunk's reads.
  - `func regenerate(tile: Vector2i) -> void`: re-dispatches `detail.glsl` for a resident tile on the render thread (no-op otherwise). Valid for a CPU write only after `flush_edits()` (Task 7) so no un-snapshotted stamp is lost; Task 7 makes it mark the tile dirty.

- [ ] **Step 1: Add the `--spike` check to `debug_window.gd`**

With `--spike`, before `move_to`: `_window.edits = TerrainEdits.new()` and `_window.edits.set_cell(center, Vector2i(64, 64), PackedFloat32Array([777.125, 700.0, 700.0, 700.0, 0.0, 2, 0, 0]))`; after the first `move_to(center)`, also `move_to(center + Vector2i(0, 8))` then `move_to(center)` so the centre tile is evicted and regenerated before the dump. Without `--spike` the behaviour is unchanged (`edits` stays `null`).

- [ ] **Step 2: Run it to verify it fails**

Run: `cd godot && godot --path . res://terrain/debug_window.tscn -- --spike --auto`
Expected: a script error (`edits` is not a member of `TerrainWindow`), or, if the member is added first, a centre-cell line with a generated height rather than `777.125`.

- [ ] **Step 3: Implement the window and shader changes**

`buffer_update` must be called outside an open compute list. The far window creates its own set 1 with its nine images and `source._edit_buffer`, and passes `edit_index = -1` always (its `edits` is `null`).

- [ ] **Step 4: Run the suite and the windowed check**

Run: `cd godot && sh tests/run.sh`
Expected: all `PASS`.

Run: `cd godot && godot --path . res://terrain/debug_window.tscn -- --spike --auto`
Expected: the centre-cell line reads `surface 777.125 bedrock 700.000 water 0.000 material 2 flags 1` after the tile was evicted and regenerated; `rock faces` and the height range still print; no errors. Then `godot --path .` once: the game starts and plays as before (no edits on disk yet).

- [ ] **Step 5: Commit**

```bash
git add godot/terrain/terrain_window.gd godot/terrain/shaders/detail.glsl godot/terrain/terrain.gd godot/terrain/debug_window.gd
git commit -m "Terrain: the detail pass writes stored edits over its output; upload ring; regenerate"
```

---

### Task 6: The stamp op, `Terrain.edit`, debug digging, the edit_check driver

**Files:**
- Create: `godot/terrain/shaders/stamp.glsl`, `godot/terrain/debug_edit.gd`, `godot/terrain/edit_check.gd`, `godot/terrain/edit_check.tscn`
- Modify: `godot/terrain/terrain_window.gd` (`tiles_touched`, `stamp`, stamp RIDs), `godot/terrain/terrain.gd` (`edit`), `godot/main.tscn` (a `DebugEdit` node under `Main` with `terrain = NodePath("../Station/Terrain")`), `godot/terrain/timing_overlay.gd:12` (`"stamp"` in `_gpu`)
- Test: `godot/tests/test_terrain_window_math.gd`; windowed `edit_check.tscn`

**Interfaces:**
- Consumes: `WorldParams.cell_of` (Task 1), the `flags` field (Task 3), `TerrainWindow._resident`.
- Produces:
  - `static func TerrainWindow.tiles_touched(i: int, j: int, radius: float, tiles_around: int, tiles_along: int) -> Array[Vector2i]`: the distinct 1 m tiles of the cells `i ± ceil(radius)`, `j ± ceil(radius)`, θ wrapped with `wrap_tile`, rows outside `[0, tiles_along)` dropped, in row-major order.
  - `func stamp(i: int, j: int, radius: float, dh: float) -> Array[Vector2i]`: the resident tiles among `tiles_touched(...)`; if none, returns `[]` and dispatches nothing; else dispatches `stamp.glsl` on the render thread with `stamp_begin/end` timestamps and returns them. (Task 7 adds the dirty marking.) `radius` is in cells (θ cells are 0.64 to 1.22 m wide, so a disc is slightly elliptical at altitude; a hand tool later uses the metric).
  - `stamp.glsl`: `local_size 8 × 8 × 1`; set 0 = the nine window images, read-write (`r32f` × 5, `r8` × 4, bindings as `FIELDS`); push constants (48 bytes, std430): `ivec2 origin` (the box's first cell: `i − ceil(r)` wrapped, `j − ceil(r)`), `ivec2 first_tile`, `int n_theta`, `int tiles_around`, `int slots`, `int reach` (`ceil(r)`), `float radius`, `float dh`, `float h_max`, `float pad`; dispatch `ceil((2 · reach + 1) / 8)` groups per axis. Per invocation, cell `c = origin + gid.xy` (θ wrapped): skip when `distance(gid.xy, vec2(reach)) > radius`, when `c.y` is outside the station or when the cell's tile is not resident (the `across && along` test of `collider_bake.glsl:50-57`); window texel as there. Then, with `k = 0.5 · (1 + cos(π · d / radius))`:
    ```
    h' = clamp(h + dh · k, 0, h_max)
    bt' = min(bt, h');  cb' = min(cb, h');  ct' = min(ct, h')
    if cb' == ct': cb' = ct' = bt'            // a lens cut away collapses onto the bedrock
    material = bt' ≥ h' − 0.01 ? 2 : (ct' ≥ h' − 0.01 ? 1 : 0)
    flags = (flags | EDITED) & ~ROCK_FACE
    water_surface, compaction, saturation unchanged
    ```
  - `Terrain.edit(theta: float, z: float, radius: float, dh: float) -> bool`: `false` before `_live`; else `cell = params.cell_of(theta, z)`, `touched = window.stamp(cell.x, cell.y, radius, dh)`, returns `not touched.is_empty()`. (Task 8 adds the rebake hook.)
  - `debug_edit.gd` (`extends Node`, `@export var terrain: Terrain`): `const RADIUS := 4.0`, `const STEP := 0.5`, `const PERIOD := 0.1`; while `G` (lower) or `H` (raise) is held, every `PERIOD` seconds calls `terrain.edit(theta, z, RADIUS, ∓STEP)` at the ground under the screen centre: a `PhysicsRayQueryParameters3D` from the current camera along `-global_basis.z` for 300 m, excluding `terrain.viewer`'s RID when it is a `CollisionObject3D`, hit position converted with `station.to_local`, `Cyl.theta_of` and `.z`. A miss does nothing.
  - `edit_check.gd` (`extends Node`, scene `edit_check.tscn`), v1: instantiates `main.tscn` as `smoke_run.gd` does, swallows mouse input, waits for `collider_live`, then: `ahead` = the ground point 6 m in front of the player (station-local `(theta_P, z_P)` from `player.global_position - player.global_basis.z * 6`); **dig**: 10 calls of `terrain.edit(theta_P, z_P, 4.0, -0.3)` six frames apart, each must return `true` (prints `dig: tiles %s`); waits 30 frames; saves `user://debug/edit_1.png` from `get_viewport().get_texture().get_image()` after `await RenderingServer.frame_post_draw`; **outside**: `terrain.edit(theta_P + PI, z_P, 4.0, -1.0)` must return `false` and `terrain.edit(theta_P, params.length, 4.0, -1.0)` must return `false`; **seam** (user arg `--seam`): `terrain.teleport(0.0, z_P)`, waits until `patch.covers` the player, `terrain.edit(0.0, z_P, 4.0, -0.3)` must return tiles containing both θ-tile `0` and `tiles_around - 1`, saves `edit_seam.png`; prints `stamp: max %.3f ms` from the overlay's `timed` signal (`n/a` on Metal); any failed expectation is a `push_error` prefixed `edit_check:`; prints `edit_check: PASS` when none failed; quits.

- [ ] **Step 1: Write the failing headless test**

Append to `test_terrain_window_math.gd` before `if failed:`:

```gdscript
	# Tiles a stamp disc touches: wraps across the seam, drops rows off the station ends.
	var touched := TerrainWindow.tiles_touched(2, 130, 4.0, 128, 250)
	check(touched.size() == 4 and touched.has(Vector2i(127, 0)) and touched.has(Vector2i(0, 0)) \
			and touched.has(Vector2i(127, 1)) and touched.has(Vector2i(0, 1)), "seam corner %s" % [touched])
	touched = TerrainWindow.tiles_touched(64, 64, 4.0, 128, 250)
	check(touched.size() == 1 and touched[0] == Vector2i(0, 0), "inside one tile")
	touched = TerrainWindow.tiles_touched(64, 1, 4.0, 128, 250)
	check(touched.size() == 1 and touched[0] == Vector2i(0, 0), "rows before the first are dropped")
	touched = TerrainWindow.tiles_touched(64, 31999, 4.0, 128, 250)
	check(touched.size() == 1 and touched[0] == Vector2i(0, 249), "rows past the last are dropped")
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd godot && godot --headless --path . --fixed-fps 60 --quit-after 7200 -s res://tests/test_terrain_window_math.gd`
Expected: `tiles_touched` not found.

- [ ] **Step 3: Implement the shader, `stamp`, `edit`, the debug node and the driver v1**

The stamp pipeline, uniform set and push constants live in `TerrainWindow` beside the detail ones and are created in `_setup_rd` only when `edits != null`; freed in `_notification`. The driver's `await` helper for teleports: loop `await terrain.patch.live` until `terrain.patch.covers(station.to_local(player.global_position))`, then two `process_frame`s.

- [ ] **Step 4: Run the suite and the windowed checks**

Run: `cd godot && sh tests/run.sh`
Expected: all `PASS`.

Run: `cd godot && godot --path . --rendering-driver vulkan res://terrain/edit_check.tscn -- --seam`
Expected, within about 20 s: `dig: tiles [...]` ten times, `outside: false false`, `seam: tiles [(127, j), (0, j)]` (either order), `stamp: max` under 0.05 ms, `edit_check: PASS`, no `ERROR` lines; `user://debug/edit_1.png` shows a bowl a few metres across in front of the player and `edit_seam.png` a bowl at the seam with no step across it.

Run: `cd godot && godot --path .`, hold `G` for a second while looking at the ground, then `H`.
Expected: a bowl deepens under the crosshair at about 5 m/s, then fills back; the overlay shows a `stamp` time under Vulkan. The player does not yet drop into the hole (the collider rebakes only in Task 8).

- [ ] **Step 5: Commit**

```bash
git add godot/terrain/shaders/stamp.glsl godot/terrain/debug_edit.gd godot/terrain/edit_check.gd godot/terrain/edit_check.tscn godot/terrain/terrain_window.gd godot/terrain/terrain.gd godot/terrain/timing_overlay.gd godot/main.tscn godot/tests/test_terrain_window_math.gd
git commit -m "Terrain: GPU stamp op, Terrain.edit, G/H debug digging, edit_check driver"
```

---

### Task 7: Snapshots, eviction, flush, autosave

**Files:**
- Create: `godot/terrain/shaders/snapshot.glsl`
- Modify: `godot/terrain/terrain_window.gd` (dirty tracking, snapshot ring, `move_to`, `_dispatch`, `snapshot_dirty`, `flush_edits`, `regenerate`), `godot/terrain/terrain.gd` (`_process`, `_exit_tree`, autosave), `godot/terrain/edit_check.gd` (v2)
- Test: windowed `edit_check.tscn`, then `-- --verify`

**Interfaces:**
- Consumes: `TerrainEdits.store`, `WorldIO.save_edits`, `stamp` (Task 6).
- Produces:
  - `const SNAPSHOT_DELAY := 30` (frames), `const SNAPSHOT_RING := 4`; `_snap_buffer: RID` of `(SNAPSHOT_RING + 1) * BLOB_BYTES` bytes (slot `SNAPSHOT_RING` is the synchronous flush slot); `_dirty := {}` (tile → the frame it first became dirty since its last snapshot), `_inflight := {}` (tile → generation), `_reapply := {}` (tile → true), `_free_slots: Array[int]`.
  - `snapshot.glsl`: `local_size 8 × 8 × 1`, 16 × 16 groups per tile; set 0 = the nine window images read-only plus binding 9 `buffer Snap { uint words[]; }`; push constants 16 bytes: `ivec2 origin` (the tile's texel origin), `int blob_index`, `int pad`. Per cell: if `flags & EDITED`, writes the six words of D1; else six zeros.
  - `stamp(...)` now sets `_dirty[t] = Engine.get_process_frames()` for each returned tile not already dirty. `regenerate(tile)` does the same after dispatching.
  - `func snapshot_dirty() -> void` (called by `Terrain._process` every frame): for each dirty tile older than `SNAPSHOT_DELAY` frames while `_free_slots` is not empty: pops a slot, dispatches a snapshot into it, `buffer_get_data_async(_snap_buffer, _snapshot_landed.bind(tile, slot, gen), slot * BLOB_BYTES, BLOB_BYTES)`, moves the tile from `_dirty` to `_inflight` with a fresh generation.
  - `func _snapshot_landed(bytes: PackedByteArray, tile: Vector2i, slot: int, gen: int) -> void`: returns the slot to `_free_slots`; ignores a stale generation; `edits.store(tile, bytes)`; clears `_inflight[tile]` if it was this generation; if `_reapply.erase(tile)` and the tile is resident, `_dispatch([tile])`.
  - `move_to`: for each slot whose tile changes, if the old tile is in `_dirty`, it goes to `leaving`; for each entering tile in `_inflight`, `_reapply[tile] = true`. `_dispatch(tiles, leaving: Array[Vector2i] = [])` first snapshots `leaving` (a free ring slot with an async readback as above, or the flush slot with a synchronous `buffer_get_data` and an immediate `edits.store`), then `compute_list_add_barrier`, then the detail dispatches as in Task 5, all in one list per chunk.
  - `func flush_edits() -> void`: for every tile in `_dirty` or `_inflight`, a synchronous snapshot through the flush slot, stored at once; both sets end empty (in-flight callbacks that land later are stale by generation).
  - `Terrain`: `const SAVE_INTERVAL := 30.0`; `_process` calls `window.snapshot_dirty()` and, when `SAVE_INTERVAL` s have passed since the last save and `window.edits.unsaved` is not empty, `WorldIO.save_edits(window.edits, world_name)`; `_exit_tree()` calls `window.flush_edits()` then `WorldIO.save_edits(...)`.
  - `edit_check.gd` v2 (replaces v1's single dig with a staged one and adds the scroll and restart checks): **dig** becomes 5 ops, wait 36 frames (the snapshot lands), `s1 = window.edits.get_cell(tile_P, local_P)[0]` must be non-empty; 5 more ops, wait 36 frames, `s2` must satisfy `|s1 − s2 − 1.5| < 1e-3` (five times 0.3 at the disc centre, where the falloff is exactly 1); **away and back**: `terrain.teleport(theta_P, z_P + 700)`, settle, `terrain.teleport(theta_P, z_P)`, settle, `get_cell` still `s2`, saves `edit_2.png`; **race**: `teleport(theta_P, z_P + 700)` and on the very next frame `teleport(theta_P, z_P)`, settle, `get_cell` still `s2`; **quit**: one more `edit(... -0.3)` and `get_tree().quit()` on the same frame, after writing `user://debug/edit_check.json` = `{"theta": theta_P, "z": z_P, "surface": s2 - 0.3, "tile": [tile_P.x, tile_P.y], "local": [local_P.x, local_P.y]}`. With `--verify`: after `collider_live`, reads the json, checks `window.edits.get_cell(tile, local)[0]` is within `1e-3` of `surface` (the flush captured the last op and the file round-tripped), teleports there, settles, saves `edit_verify.png`, prints `edit_check: PASS`, quits.

- [ ] **Step 1: Extend the driver first**

Run: `cd godot && godot --path . --rendering-driver vulkan res://terrain/edit_check.tscn`
Expected: `edit_check:` error lines (`get_cell` empty: nothing snapshots yet). This is the failing test.

- [ ] **Step 2: Implement the shader, the window bookkeeping and the Terrain hooks**

`buffer_get_data_async` and `buffer_get_data` take the slot's byte offset and size. The flush slot is never used asynchronously. Keep `_snapshot_landed` free of per-cell work: `edits.store` is one array assignment.

- [ ] **Step 3: Run the suite and the two windowed runs**

Run: `cd godot && sh tests/run.sh`
Expected: all `PASS` (no headless test changes; the suite guards the GDScript parse).

Run: `cd godot && godot --path . --rendering-driver vulkan res://terrain/edit_check.tscn`
Expected: `s1 ... s2 ...` with the 1.5 m difference, `away and back: ok`, `race: ok`, `edit_check: PASS`, no `ERROR`; `user://worlds/default/tiles/` holds one to four `.edits` files; `edit_2.png` shows the bowl again after the window has been away.

Run: `cd godot && godot --path . --rendering-driver vulkan res://terrain/edit_check.tscn -- --verify`
Expected: `verify: stored %.3f expected %.3f ok`, `edit_check: PASS`; `edit_verify.png` shows the bowl on a fresh start.

Then clean up so later runs start from a known state: `rm -r ~/Library/Application\ Support/Godot/app_userdata/Artificial\ Gravity/worlds/default/tiles/*.edits`.

- [ ] **Step 4: Commit**

```bash
git add godot/terrain/shaders/snapshot.glsl godot/terrain/terrain_window.gd godot/terrain/terrain.gd godot/terrain/edit_check.gd
git commit -m "Terrain: snapshot edited tiles back to the store; evict, flush, autosave"
```

---

### Task 8: The collider follows edits (R3 and the bake occupancy)

**Files:**
- Modify: `godot/terrain/shaders/collider_bake.glsl` (whole `main`), `godot/terrain/collider_patch.gd` (`touches`, `is_pending`, `half_n`, `last_map_data_ms`, the `half_n` guard), `godot/terrain/terrain.gd` (`edit` rebake hook, `_process` throttle), `godot/terrain/timing_overlay.gd` (`@export var terrain: Terrain`, a `map_data x.xx ms` item), `godot/main.tscn` (the overlay's `terrain` path), `godot/terrain/edit_check.gd` (v3)
- Test: `godot/tests/test_terrain_window_math.gd`; windowed `edit_check.tscn`

**Interfaces:**
- Consumes: `Terrain.edit` and the stamp (Task 6), `TerrainWindow.debug_read` (Task 3), `Cyl.bake_row`, `MacroMaps.sample`.
- Produces:
  - `ColliderPatch.touches(p: Vector3, radius: float) -> bool`: framed, and the station-space point's Chebyshev distance from the centre in the patch plane is at most `_MID + radius`.
  - `ColliderPatch.is_pending() -> bool`; `var last_map_data_ms: float` set in `_landed` from `Time.get_ticks_usec()` around the `map_data` assignment.
  - `static func ColliderPatch.half_n(p: WorldParams) -> int`: the expression at `collider_patch.gd:121`, used by `_bake` and the driver; `_bake` pushes an error and leaves `_pending` set when it exceeds 255 (the shader's shared array).
  - `collider_bake.glsl`: `local_size_x = 257`; `shared vec2 mapped[512]`; dispatch `(257, 1, 1)`, one workgroup per row `j = gl_WorkGroupID.x`, thread `t = gl_LocalInvocationID.x`. Each thread maps samples `t` and `t + 257` (when under `n = 2 · half_n + 1`) with the existing `surface()` and `(x, y)` formulas into `mapped`; `barrier()`; then thread `t` is output column `i = t`, `x = i − MID`, and scans all `n − 1` segments of `mapped` with the existing rules (a segment covers `x` when `x` lies within its endpoints' x; a vertical segment yields the higher endpoint; the highest covering `y` wins; an uncovered column takes the leftmost sample's `y` when `x` is left of it, else the rightmost's), tracking the leftmost and rightmost samples in the same loop; one `imageStore`. Same inputs, push constants and output as today.
  - `Terrain`: `const EDIT_REBAKE_INTERVAL := 0.1`; `var _edit_pending := false`, `var _last_edit_rebake := 0.0`. `edit(...)`, after a successful stamp, sets `_edit_pending = true` if `patch.touches(Cyl.position(theta, z, height_at(theta, z), params.radius), radius)`. `_process`, after the positional check: if `_edit_pending and not patch.is_pending() and Time.get_ticks_msec() / 1000.0 - _last_edit_rebake >= EDIT_REBAKE_INTERVAL`: clears the flag, stamps the time, `patch.rebuild(window, patch.center.x, patch.center.y)` (same centre, so `covers` cannot change and no hold follows).
  - `edit_check.gd` v3 adds, around the steps of v2: `probe(p) = Cyl.height_of(terrain.patch.surface_point(p, 0.0), R)` at `ahead`; **before** the dig and 0.5 s **after** it: the drop must be in `[2.5, 3.5]` (ten times 0.3 at the centre, bilinear); after **away and back** and after the **race**: the drop still in `[2.5, 3.5]` (the window re-applied the blob and the bake read it); **feet**: 6 ops of `-0.5` at the player's own `(theta, z)`, wait 1 s: the player's `Cyl.height_of` is 2.5 to 3.5 m lower than before, `player.is_on_floor()` is true, `_holds` unchanged (count `body_held` as `smoke_run` does); **rate**: 50 ops at 10 Hz at `ahead` while `W` is held (the player walks through the dig), recording frame intervals and `patch.last_map_data_ms`, then prints `rate: map_data max %.2f ms, frame p99 %.2f max %.2f ms, rebakes %d`; **bake vs CPU**: for rows `j` in `[0, 64, 128, 192, 256]` of the live patch, builds `h[k]` for `k` in `[-half_n, half_n]` from `window.debug_read("surface")` where the cell's tile is resident and `maps.sample(maps.surface, theta, z, params)` otherwise, runs `Cyl.bake_row(h, params.dtheta(), params.radius, 1.0, 257)` and compares with `patch._shape.map_data` row `j`: prints `bake vs cpu: max %.4f m` and errors over `0.002`; with `--verify`: also probes at the saved point and requires the drop.

- [ ] **Step 1: Write the failing headless test**

Append to `test_terrain_window_math.gd` (after the `patch` coverage checks, before `fresh` is freed):

```gdscript
	check(patch.touches(patch.transform * Vector3(130, 0, 0), 4.0) and not patch.touches(patch.transform * Vector3(133, 0, 0), 4.0), "touches within the radius of the edge")
	check(not fresh.touches(Vector3.ZERO, 1000.0), "no frame, nothing touched")
	check(ColliderPatch.half_n(p) == 204 and not patch.is_pending(), "half_n on the default world, idle patch")
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd godot && godot --headless --path . --fixed-fps 60 --quit-after 7200 -s res://tests/test_terrain_window_math.gd`
Expected: `touches` not found.

- [ ] **Step 3: Rewrite the bake shader, add the patch functions, the rebake hook and the driver v3**

The bake rewrite keeps every formula of the current shader; only who computes what moves. The overlay reads `terrain.patch.last_map_data_ms` when `terrain` is set.

- [ ] **Step 4: Run the suite, the driver, the verify run, and the smoke run**

Run: `cd godot && sh tests/run.sh`
Expected: all `PASS`.

Run: `cd godot && godot --path . --rendering-driver vulkan res://terrain/edit_check.tscn`
Expected: `probe: before %.2f after %.2f drop %.2f` with the drop in `[2.5, 3.5]` at each of the three probes; `feet: dropped %.2f m, on floor, holds 0`; `rate: map_data max` under 4 ms, `frame p99` under 16.7 ms, `rebakes` between 4 and 6 for 5 s of digging; `bake vs cpu: max` under 0.002 m; `bake: ... max` under 0.2 ms over the run; `edit_check: PASS`; no `ERROR`. In `edit_1.png` the player's feet sit at the bowl's rim and `edit_2.png` shows the same bowl.

Run: `cd godot && godot --path . --rendering-driver vulkan res://terrain/edit_check.tscn -- --verify`, then delete the `.edits` files as in Task 7.
Expected: `verify: ... ok`, a probe drop in `[2.5, 3.5]` at the saved point, `edit_check: PASS`.

Run: `cd godot && godot --path . --rendering-driver vulkan res://terrain/smoke.tscn -- --legs=10`
Expected: no `FELL THROUGH`, bake `max` under 0.2 ms, no `ERROR` (the rewritten bake behaves as before on the unedited world).

- [ ] **Step 5: Commit**

```bash
git add godot/terrain/shaders/collider_bake.glsl godot/terrain/collider_patch.gd godot/terrain/terrain.gd godot/terrain/timing_overlay.gd godot/main.tscn godot/terrain/edit_check.gd godot/tests/test_terrain_window_math.gd
git commit -m "Terrain: collider rebakes in place after edits; bake shader at full occupancy"
```

---

### Task 9: Hold uncovered rigid bodies

**Files:**
- Modify: `godot/terrain/terrain.gd:199-206` (`_hold_body` → `_hold`), `godot/emitter.gd:103-121` (`spawn`), `godot/tests/test_hold_rule.gd`, `godot/tests/test_emitter.gd`

**Interfaces:**
- Consumes: `Terrain._hold_body`, `ColliderPatch.covers`.
- Produces:
  - `Terrain.GROUND_GROUP := "ground_bodies"`.
  - `func _hold(body: Node3D, hold: bool) -> bool`: the rule of `_hold_body` per body, state in `_held := {}` (body → true); returns whether the state changed. `_hold_body(hold)` becomes `if _hold(_body, hold): body_held.emit(hold)`.
  - `_process`: after the viewer's hold, `for b in get_tree().get_nodes_in_group(GROUND_GROUP): _hold(b, not patch.covers(station.to_local(b.global_position)))`.
  - `Emitter.spawn` adds each box to `"ground_bodies"` (`box.add_to_group("ground_bodies")`) before `station.add_child(box)`.
  - A doc comment on `GROUND_GROUP`: a member outside the live patch is removed from physics where it is, mid-air included, until a patch covers it again; per-body patches are the later design (D12).

- [ ] **Step 1: Write the failing tests**

Append to `test_hold_rule.gd` before the coverage checks:

```gdscript
	# Any ground body is held the same way; only the viewer's hold is announced.
	var box := RigidBody3D.new()
	check(t._hold(box, true) and box.process_mode == Node.PROCESS_MODE_DISABLED, "box held")
	check(not t._hold(box, true), "no change")
	check(t._hold(box, false) and box.process_mode == Node.PROCESS_MODE_INHERIT, "box released")
	check(seen.size() == 2, "box holds are not announced")
	box.free()
```

Append to `test_emitter.gd` after the `count` check: `check(boxes[0].is_in_group("ground_bodies"), "boxes are ground bodies")`.

- [ ] **Step 2: Run them to verify they fail**

Run: `cd godot && for t in test_hold_rule test_emitter; do godot --headless --path . --fixed-fps 60 --quit-after 7200 -s res://tests/$t.gd 2>&1 | tail -n 3; done`
Expected: `_hold` not found; `boxes are ground bodies` fails.

- [ ] **Step 3: Implement `_hold`, the group loop and the emitter line**

`_hold` keeps the existing guard (a body already `DISABLED` by someone else is neither taken nor released); the group loop runs after `_hold_body` so the viewer's own hold is unchanged.

- [ ] **Step 4: Run the suite and a windowed check**

Run: `cd godot && sh tests/run.sh`
Expected: all `PASS`.

Run: `cd godot && godot --path .`; press Spawn three times, press `F`, fly 300 m along the axis, turn around, fly back.
Expected: the boxes stay where they were while the camera is away (frozen, not falling), and settle onto the ground when the camera returns; no errors.

- [ ] **Step 5: Commit**

```bash
git add godot/terrain/terrain.gd godot/emitter.gd godot/tests/test_hold_rule.gd godot/tests/test_emitter.gd
git commit -m "Terrain: hold uncovered rigid bodies instead of letting them fall to the hull"
```

---

### Task 10: Measurements and notes

**Files:**
- Modify: `godot/terrain/edit_check.gd` (the timing table), `docs/terrain-research.md` (three lines under the slice 1 measurements in 6.8)

**Interfaces:**
- Consumes: everything above.
- Produces: `edit_check` ends with one table, measured over its own phases:

| measurement | how | budget |
|---|---|---|
| detail per tile | overlay `timed("detail")` per list divided by the list's tile count from `tiles_generated`, as `smoke_run._per_tile`; the away-and-back teleports generate tiles with blobs | under 2 ms |
| bake, median and max | `timed("bake")` over every bake of the run (positional and edit rebakes) | under 1 ms; expected under 0.1 ms |
| stamp, max | `timed("stamp")` | no budget; expected under 0.05 ms |
| `map_data`, max | `patch.last_map_data_ms` after each landing | under 4 ms (the spec's hitch budget) |
| GPU frame, mean and p99 during the rate phase | `viewport_get_measured_render_time_gpu` per frame | mean under 6 ms |
| frame interval, p99 and max during the rate phase | the process delta | p99 under 16.7 ms |
| rebakes during the rate phase | count of `patch.live` | 4 to 6 in 5 s |

GPU rows need `--rendering-driver vulkan`; under Metal they print `n/a` and the `map_data` and frame-interval rows still count.

- [ ] **Step 1: Add the table and run the driver on both drivers**

Run: `cd godot && godot --path . --rendering-driver vulkan res://terrain/edit_check.tscn` then the same without the driver flag; delete the `.edits` files after each.
Expected: every budget in the table met under Vulkan; under Metal the GPU rows are `n/a` and the others still hold; `edit_check: PASS` both times.

- [ ] **Step 2: Run the smoke routes and the suite one last time**

Run: `cd godot && godot --path . --rendering-driver vulkan res://terrain/smoke.tscn -- --legs=10`, then `-- --blackout`, then `sh tests/run.sh`.
Expected: no `FELL THROUGH`, no `ERROR`, the blackout assertions silent, all tests `PASS`.

- [ ] **Step 3: Record**

Under the slice 1 measurements in `docs/terrain-research.md` section 6.8, add "Edit slice measurements, 2026-xx-xx, <machine>": the table's measured values in one row per driver, and one line naming any budget missed. Do not tune in this task; report.

- [ ] **Step 4: Commit**

```bash
git add godot/terrain/edit_check.gd docs/terrain-research.md
git commit -m "Terrain: edit slice measurements"
```

---

## Self-review notes

- Scope coverage against the follow-ups doc: R1 (Tasks 4, 5, 7), R3 and the bake occupancy (Task 8), R4 (D8, no task, by design), R5 (Task 2), R6 (Task 3), R7 (Task 1), topsoil (Task 1), second patch per body (D12 and Task 9), the edit API and the debug edit (Task 6), measurements with their methods (Task 10). R2 (noise octaves) is tuning for the user's eye and stays out. The minor-defects list stays out except `cell_of`, which the stamp needed (D10).
- Names used identically across tasks: `TerrainEdits.BLOB_BYTES/offset/blob/get_cell/set_cell/store/unsaved/blobs`, `WorldIO.save_edits/load_edits`, `TerrainWindow.FLAG_EDITED/FLAG_ROCK_FACE/edits/debug_read/tiles_touched/stamp/regenerate/snapshot_dirty/flush_edits/_dispatch`, `Terrain.edit/_hold/_hold_body/GROUND_GROUP/EDIT_REBAKE_INTERVAL/SAVE_INTERVAL`, `ColliderPatch.touches/is_pending/half_n/last_map_data_ms`, `WorldParams.cell_of/soil_slope_deg`, `Cyl.theta_of`.
- Step scan: each code step names the file, signature and pinned values; bodies appear only for the stamp rule and the bake's thread mapping, which the signatures do not determine. The one windowed driver grows across Tasks 6 to 8 and 10 rather than being four drivers.
- Deviations stated: the window's memory already exceeds the spec's figures because slice 1 chose `R32_SFLOAT` (D1); `map_data` at about 3 ms is accepted under the spec's 4 ms hitch budget rather than driven down, because only Jolt can (D7); the far window and the bake's macro fallback do not see edits (D8).
