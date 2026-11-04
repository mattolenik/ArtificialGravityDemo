# Terrain Tunnels Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Dig down, then sideways, with the shovel, and walk into a tunnel whose roof holds, on a voxel box around the player that owns all the dirt, drawn smooth and collided, saved as columns with gaps.

**Architecture:** Columns in the window and the blobs gain up to four gaps (bottom, top, loose on the floor, material). A `VoxelBox` of 1 m voxels in 16³ bricks, sparse, follows the player's feet (256 × 256 m, 24 m up to 40 m down), unpacks columns into voxels on entry and packs dirty columns back every step, so the window's `surface` and `loose` stay current for the tile meshes, the heightfield collider, the water simulation and the saves. Inside the box every dirt operation is a voxel operation (`box_edit.glsl`: scoop, dump, push, tamp, bore cut, spoil), and loose dirt falls and slumps by a 3D sand rule on active bricks (`box_sand.glsl`) that also carries the surface cave-in with the new free height; the loose half of `sim.glsl` retires. Chunks (32 m squares) holding a gap are meshed by surface nets on the GPU (`box_mesh.glsl`), read back, drawn as `ArrayMesh` and collided as trimeshes, while the tile mesh and the heightfield patch step back from them. The shovel aims at any surface and shows a ring decal. Window-side stamps that still exist (the debug raise, a driver's deposit or spill, the auger's wet pump) reload the box's columns they touch.

**Tech Stack:** Godot 4.7.2, GDScript, GLSL compute on the main RenderingDevice (storage buffers, buffer atomics, async readbacks), Jolt (`HeightMapShape3D` with NaN holes, `ConcavePolygonShape3D`), `Decal`, `SpotLight3D`.

**Spec:** `docs/superpowers/specs/2026-11-03-terrain-tunnels-design.md` (read it first; its "What the next projects need" and "The builder check's questions" sections are binding).

## Global Constraints

- Conservation to the tenth of a percent in every driver check: a volume leaves one place and arrives in one other; voxel fractions are 16-bit; a voxel at height index k has volume `Δθ ((R − k)² − (R − k − 1)²) / 2` times its fraction (the annulus), never a fraction times a fixed area.
- One owner of the dirt: inside the box, voxels; the window's `surface`, `loose`, gap fields, `edit_mask`, `material`, `compaction` are written by the box's pack and read by everything else. A window-side stamp inside the box is followed by `VoxelBox.reload(cells)` before anything reads the box again.
- No per-voxel or per-vertex loop in GDScript on the hot path: packed arrays move whole; GDScript loops only over bricks, chunks, tiles or cells of a driver's box.
- The RenderingDevice rules of slices 2 and 3: nothing dispatched or filed inside a readback callback; `buffer_update` and `buffer_clear` outside open compute lists; async readbacks after `compute_list_end`.
- Four gaps per column; a fifth is refused at the dig (the scoop takes nothing there, printed).
- Headless tests cannot create a RenderingDevice: every shader is proven by a driver through `sh tests/offscreen.sh <scene> </abs/log>` on the tool run's world copy. After editing a `.glsl`, `godot --headless --path . --import` first, never chained before a run.
- Never touch `user://worlds/default`; drivers run with `persist_edits = false` or on the copy.

## Review Focus

1. A column the box never changed must keep its float heights bit for bit after the box has passed over it (the dirty-column pack): Task 3's driver compares the whole window before and after a box move over untouched ground.
2. A scoop into a wall whose ball crosses an existing gap merges with it rather than making a second gap (Task 4's driver scoops twice into one tunnel and reads one gap).
3. The sand rule at the box's edge and at a brick that is not resident parks loose rather than losing it (Task 5's driver dumps at the box's edge and sums).
4. The player standing in a tunnel when its chunk remeshes keeps a collider under them: the old trimesh stays until the new one is set (Task 7's driver reads the clearance every frame through a remesh).
5. A restart draws the same chunks smooth: touched follows from the saved gap fields alone (Task 9's driver restarts with a tunnel and checks the chunk node exists and the collider holds the player inside).

---

### Task 1: Gap fields in the window, the blob and the files

**Files:**
- Modify: `godot/terrain/terrain_window.gd` (FIELDS, FLOAT_FIELDS, a `COLUMN_FIELDS` constant)
- Modify: `godot/terrain/shaders/detail.glsl` (set 1 bindings 11..26 written zero)
- Modify: `godot/terrain/shaders/edit.glsl` (bindings shift; pack and apply carry the gap fields)
- Modify: `godot/terrain/edit_layer.gd` (CELL_BYTES 84, V2 upgrade, decode, bindings)
- Modify: `godot/terrain/terrain_sim.gd` (binds `COLUMN_FIELDS` only)
- Modify: `godot/terrain/world_io.gd` (EDIT_VERSION 3, version 2 files load upgraded)
- Test: `godot/tests/test_edit_layer.gd`

**Interfaces:**
- Produces: `TerrainWindow.GAP_FIELDS := ["gap_bottom0".."gap_bottom3", "gap_top0".."gap_top3", "gap_loose0".."gap_loose3", "gap_material0".."gap_material3"]` appended to `FIELDS` (27 fields; the first twelve of GAP_FIELDS float, the last four bytes); `TerrainWindow.COLUMN_FIELDS := FIELDS.slice(0, 11)` (what `sim.glsl` and `collider_bake.glsl` bind). `TerrainWindow.GAPS := 4`.
- Produces: `EditLayer.CELL_BYTES := 84` (words 0..7 as today, words 8..11 gap bottoms, 12..15 gap tops, 16..19 gap loose, word 20 = `material0 | material1 << 8 | material2 << 16 | material3 << 24`), `V2_CELL_BYTES := 32`, `static func upgrade_v2(blob) -> PackedByteArray`, `decode` returning also `"gap_bottom": PackedFloat32Array(4)`, `"gap_top"`, `"gap_loose"`, `"gap_material": PackedInt32Array(4)`.
- Produces: `WorldIO.EDIT_VERSION := 3`; a version 2 file of `V2_BLOB_SIZE` loads through `upgrade_v2`; version 1 through `upgrade_v1` then `upgrade_v2`.

- [ ] **Step 1: the failing tests** in `test_edit_layer.gd`: `TerrainWindow.FIELDS.size() == 27`, `FIELDS[11] == "gap_bottom0"`, `FIELDS[26] == "gap_material3"`, `field_format("gap_loose2")` float and `field_format("gap_material0")` byte, `COLUMN_FIELDS.size() == 11`; `EditLayer.BLOB_SIZE == 128 * 128 * 84`; `decode` of a blob with `encode_float(o + 32, 405.0)`, `encode_float(o + 48, 407.5)`, `encode_float(o + 64, 0.25)`, `encode_u32(o + 80, 1 << 8)` reads `gap_bottom[0] == 405.0`, `gap_top[0] == 407.5`, `gap_loose[0] == 0.25`, `gap_material[1] == 1`; a version 2 blob upgraded has the gap words zero and the first 32 bytes unchanged; a version 2 file loads upgraded; the saved file is version 3 of `BLOB_SIZE`.
- [ ] **Step 2:** run `sh tests/run.sh` → `test_edit_layer` FAILS on the field count.
- [ ] **Step 3: implement.** `detail.glsl`: sixteen more `writeonly image2D` outputs in set 1 at bindings 11..26, each stored 0 at the end of `main`. `edit.glsl`: bindings 2..28 the fields, 29 the counter, 30 the stats; a blob cell is 21 uints; `pack` writes words 8..20 from the gap images (floats as bits, materials packed), `apply` stores them back. `EditLayer._setup_rd` binds `2 + FIELDS.size() + 2` uniforms with the buffers at 0, 1, 29, 30. `TerrainSim._setup_rd` iterates `COLUMN_FIELDS`. `WorldIO.load_edits` accepts raw sizes `V1`, `V2` and `BLOB_SIZE` by version and upgrades.
- [ ] **Step 4:** `godot --headless --path . --import`; `sh tests/run.sh` → 18 PASS. Then `sh tests/offscreen.sh res://terrain/tool_run.tscn /abs/log` → PASS unchanged (the new fields are zero everywhere and ride through pack and apply).
- [ ] **Step 5: Commit** `Terrain tunnels: columns carry up to four gaps (16 window fields, blob version 3)`.

### Task 2: The column rule on the CPU

**Files:**
- Create: `godot/terrain/voxel_column.gd` (`class_name VoxelColumn`, static, headless-safe: the reference for the shaders and the tests)
- Test: `godot/tests/test_voxel_column.gd`

**Interfaces:**
- Produces: `VoxelColumn.FRACTION_ONE := 65535`; `static func unpack(col: Dictionary, k0: int, n: int) -> Dictionary` where `col` has `surface, bedrock_top, clay_bottom, clay_top, loose, material, compaction, saturation` and arrays `gap_bottom[4], gap_top[4], gap_loose[4], gap_material[4]` (as `decode` returns them), `k0` the height index of the first voxel and `n` the count; returns `{"solid": PackedInt32Array(n), "loose": PackedInt32Array(n), "material": PackedByteArray(n), "compaction": PackedByteArray(n)}` with fractions in `0..FRACTION_ONE`; `static func pack(vox: Dictionary, k0: int, col: Dictionary) -> Dictionary` the inverse, merging the box's range with the column's stored remainder outside it; `static func material_at(h: float, col: Dictionary) -> int` (rock under `bedrock_top`, clay inside the lens, else dirt; a gap's material byte for a pillar later); `static func voxel_volume(k: int, R: float, dtheta: float) -> float` the annulus.

The rule (the spec's): a run is a maximal vertical sequence of voxels with solid > 0; its top boundary is its top full voxel's top plus the partial above it (`k + 1 + f/FRACTION_ONE` at a full voxel k with a partial f above, or `k + f/FRACTION_ONE` for a lone or topmost partial at k), its bottom boundary its bottom full voxel's bottom less the partial below it; the gaps are the air between runs below the top run; the loose on a run's top is the loose fractions above it summed (in m, the annulus-weighted sum divided by the floor's area); a run continuing past `k0` or `k0 + n` keeps the stored boundary beyond it.

- [ ] **Step 1: the failing tests.** `test_unpack_plain`: a column `surface 410.37, loose 0.5` over 40 voxels from `k0 = 380` has voxels 380..409 full solid, voxel 410 solid `round(0.37 * 65535)` = 24248 and loose `round(0.5 * 65535)` = 32768 (the loose fills the voxel above the solid top first, and 0.37 + 0.5 fits in it), voxel 411 all zero; `test_unpack_gap`: a gap `[405.0, 407.5]` with loose 0.25 gives voxels 405 and 406 air, voxel 405 loose `round(0.25 * 65535)`, voxel 407 solid `round(0.5 * 65535)` (a roof partial), voxel 404 full; `test_pack_round_trip`: `pack(unpack(col)) == col` for the two above and for a lone partial (a 0.3 m sliver between two gaps), bit for bit on the floats; `test_pack_partial_cases`: voxels built by hand with a partial at a run's top, one at its bottom and one alone pack to the stated boundaries; `test_pack_clips_to_range`: a column unpacked over 380..420 with a surface at 450 packs back with the surface still 450; `test_cap`: five gaps in the voxels pack to four with an error flag `"overflow": true`; `test_material_at`: rock, clay, dirt by the strata; `test_voxel_volume`: the annulus at k = 400 against `Δθ ((R − 400)² − (R − 401)²) / 2`.
- [ ] **Step 2:** run `godot --headless --path . --fixed-fps 60 --quit-after 7200 -s res://tests/test_voxel_column.gd` → FAIL (no class).
- [ ] **Step 3: implement `voxel_column.gd`.** Pure GDScript over `PackedInt32Array`s; this file may loop per voxel (tests and the shader's reference only, never the hot path).
- [ ] **Step 4:** the test PASSES; `sh tests/run.sh` → 19 PASS.
- [ ] **Step 5: Commit** `Terrain tunnels: the column rule (unpack, pack, the partial voxel cases, the cap) on the CPU`.

### Task 3: The box: bricks, unpack, pack, follow

**Files:**
- Create: `godot/terrain/voxel_box.gd` (`class_name VoxelBox extends RefCounted`)
- Create: `godot/terrain/shaders/box_unpack.glsl`, `godot/terrain/shaders/box_pack.glsl`
- Create: `godot/terrain/box_run.gd`, `godot/terrain/box_run.tscn` (a driver on the tool run's world copy, grown through Tasks 4 to 9)
- Modify: `godot/terrain/terrain.gd` (`var box: VoxelBox`, setup after `sim.setup`, `box.follow` in `_process` before `sim.step`)
- Test: `godot/tests/test_voxel_box.gd` (the arithmetic: brick slots, the box's origin from the feet, the index of a voxel)

**Interfaces:**
- Produces: `VoxelBox.BRICK := 16`, `BRICKS_ACROSS := 16`, `BRICKS_UP := 4`, `UP_ABOVE := 24`, `BRICK_BYTES := 16 * 16 * 16 * 8`, `POOL_BRICKS := 1536` (48 MB); voxel words: `w0 = solid16 | loose16 << 16`, `w1 = material | compaction << 8 | saturation << 16 | flags << 24` (flag bit 0: dirty column, set on any change).
- `func setup(window: TerrainWindow, edits: EditLayer, materials: MaterialSet) -> void` (render thread: pool, index table of `16 * 16 * 4` ints, the free stack, the dirty-column buffer, the activity words per brick appended to a `box_stats` buffer, shaders and sets).
- `func follow(feet: Vector3) -> void`: station-local feet; computes the box origin in bricks `(bi0, bj0, bk0)` with `bk0 = floori((h_feet − 40) / 16)` and the horizontal origin so the feet's brick is the middle; when it changes, packs the dirty columns of leaving bricks, frees them, invalidates their slots, and unpacks the entering bricks' columns from the window (`unpack` runs three dispatches: mark needed bricks, allocate, fill). Only resident window tiles are unpacked; a column whose tile is not resident is skipped and tried at the next move.
- `func reload(cells: Array[Vector2i]) -> void`: re-unpacks those columns (after a window-side stamp).
- `func pack_dirty() -> void`: packs every dirty column of every resident brick into the window fields, sets `edit_mask` and flags the tile's stats slot (bit 0), clears the dirty flags. Called from `Terrain._process` after the sand step (Task 5) and before `sim.step`.
- `func pack_all_sync() -> void`: every resident column, synchronous (for `_exit_tree` and the drivers).
- `func origin() -> Vector3i`, `func slot_of(brick: Vector3i) -> Vector3i`, `func brick_of_cell(cell: Vector2i, k: int) -> Vector3i`, `static func box_origin_for(feet_cell: Vector2i, h_feet: float) -> Vector3i` (headless).
- `func read_brick(slot: Vector3i) -> PackedByteArray` (synchronous, drivers only) and `static func voxel(brick: PackedByteArray, x: int, y: int, z: int) -> Dictionary` (solid, loose, material, compaction, saturation, dirty).

- [ ] **Step 1: the failing tests** in `test_voxel_box.gd`: `box_origin_for(Vector2i(100, 200), 410.0)` → `Vector3i(100 / 16 − 8, 200 / 16 − 8, floori((410 − 40) / 16))` = `(−2, 4, 23)` wrapped around for theta; `slot_of` wraps modulo 16, 16, 4; `brick_of_cell`; `voxel()` decodes a hand-built brick.
- [ ] **Step 2:** FAIL (no class). **Step 3: implement** the GDScript and the two shaders. `box_unpack.glsl`: mode 0 one invocation per column of the entering bricks' footprint marks the needed brick layers in an `needed` word array (atomicOr); mode 1 one invocation per index entry allocates from the free stack (atomicAdd on its top) where needed and unallocated; mode 2 one invocation per column fills its voxels in the bricks of its slots by `VoxelColumn.unpack`'s rule. `box_pack.glsl`: one invocation per dirty column (or every column for the sync pack) builds the runs by one upward scan of the box's range, writes `surface`, `loose`, the four gaps, `material` (of the top run's top), `compaction` (of the top loose), `edit_mask = 1`, flags the stats slot, clears the dirty flag; a run past the range keeps the stored boundary; five gaps → the fourth gap's top is raised to the fifth's top (merged, the sliver lost: refused earlier by the dig, so never reached) and `overflow` counted in a word of `box_stats`.
- [ ] **Step 4: the driver** `box_run.tscn`: opens `main.tscn` on the world copy as `tool_run.gd` does (reuse its `_fresh_world`, `_open_main`, `_read`, `_vol` helpers by extending or copying them into a shared `driver_base.gd`; the builder's call); phase `unpack`: with the box live around the spawn, read every window field over the box's footprint, `pack_all_sync`, read again: bit for bit equal (no column changed); phase `move`: teleport 100 m along z (the box moves four bricks), back; the fields of the columns passed over bit for bit equal; phase `reload`: a 2 m³ deposit stamp (window-side) then `reload` of its disc, `read_brick` shows loose fractions whose annulus sum is 2 m³ within 0.1 %; the GPU time of unpack and pack per brick printed against 0.5 ms.
- [ ] **Step 5:** `sh tests/offscreen.sh res://terrain/box_run.tscn /abs/log` → PASS; `sh tests/run.sh` → 20 PASS; the tool run still PASS (the box exists but no dirt op uses it yet).
- [ ] **Step 6: Commit** `Terrain tunnels: the voxel box (sparse bricks, unpack, pack, follow, reload) proven by box_run`.

### Task 4: Scoop and dump in the box, the aimable shovel and its patch

**Files:**
- Create: `godot/terrain/shaders/box_edit.glsl` (modes: 0 scoop, 1 dump, 2 push, 3 tamp, 4 bore, 5 spoil; this task does 0 and 1)
- Create: `godot/terrain/shovel_patch.gd` + `godot/terrain/shovel_patch.tscn` (a `Decal` with a ring texture made at runtime from an `Image`, 2 m square)
- Modify: `godot/terrain/voxel_box.gd` (`scoop`, `dump`, the counter)
- Modify: `godot/terrain/tools.gd` (`shovel_hit()`, T and Y through the box, the patch)
- Modify: `godot/terrain/tool_params.gd` (`shovel_reach := 4.0`, `scoop_ball := 1.0`)
- Modify: `godot/main.tscn` (the patch under `Tools`)
- Test: `godot/tests/test_tools.gd` (reach 4.0, ball 1.0, the hand's accounting helper)

**Interfaces:**
- `VoxelBox.scoop(p: Vector3, radius: float, swell: PackedFloat32Array, counted: Callable) -> bool`: `p` station-local; false (nothing dispatched) when the ball's columns are not all resident in the box or a column would get a fifth gap; `counted(volume_m3, false)` lands with the loose-equivalent m³ taken (loose fractions at 1, solid fractions times the material's swell, by the annulus), as `EditLayer`'s counter does; the ball's coverage per voxel from 8 sub-samples (the fraction removed is `coverage` of what is there, never rock).
- `VoxelBox.dump(p: Vector3, volume: float) -> bool`: fills loose into the air voxels of the ball nearest `p` first (by distance, a fixed order: the shader's invocation decides its own voxel's share from the ball's air volume and `volume`, so no two write one voxel; a remainder that does not fit the ball is kept in the hand: `counted` not needed, the dump returns the placed m³ through a counter landing `placed(volume_m3)`), the rest left to the sand rule.
- `Tools.shovel_hit() -> Dictionary` (`position`, `normal` station-local, or empty): the crosshair ray against the terrain colliders within `shovel_reach`; `Tools.scoop(aim := Vector3.INF)` and `dump(aim := Vector3.INF)` take a station-local point for the drivers.
- `ShovelPatch.show_at(p: Vector3, n: Vector3)` / `hide()`.

- [ ] **Step 1: the failing test** in `test_tools.gd`: `ToolParams.new().shovel_reach == 4.0 and scoop_ball == 1.0`; `Tools.ball_volume(1.0, 410.0, R, dtheta)` (a static helper: the ball's volume by the annulus over its voxels, used by the drivers' expectations) within 1 % of `4/3 π`.
- [ ] **Step 2:** FAIL. **Step 3: implement.** The shader's ball op: one invocation per voxel of the ball's bounding box (3³ bricks at most... the ball of 1 m spans 3 voxels per axis: one workgroup); the counter as `EditLayer`'s (`atomicAdd` of `1e-6` units). `Tools._process` scoops through `terrain.box.scoop(hit.position, t.scoop_ball, materials.swell_factor, _scooped)`, the patch shown every frame at the hit while in reach. `_clear_of` becomes three-dimensional: the player within `pile_radius(v) + PILE_MARGIN` of the dump point along the hull is moved out as today, and a player whose feet are under the chunk trimesh or the patch (Task 7) is stood up as today.
- [ ] **Step 4: the driver** `box_run` phase `shovel`: a scoop on flat dry ground at a point: `counted` within 1 % of `ball_volume / 2 × swell` (a half ball) and the window's `surface` over the box of 3 dropped by the same solid volume (`_removed`) within 0.1 %; a dump of it 4 m away: the loose over its box within 0.1 % once the sand rule (Task 5) settles it, until then the fractions' annulus sum; two scoops into one spot then one sideways into the pit's wall: `decode` of the wall column shows one gap; a third stacked... skip; the patch node visible while aiming at ground and hidden at the sky.
- [ ] **Step 5:** box_run PASS; `sh tests/run.sh` PASS. The tool run's shovel phase still passes through `Tools.scoop(cell)` → route it to the box with the cell's centre on the surface (`Tools.scoop_cell(c)` for the drivers).
- [ ] **Step 6: Commit** `Terrain tunnels: the shovel scoops a ball and dumps at the patch in the box; aim at any surface; the ring decal`.

### Task 5: Sand, the cave-in's free height, and the loose simulation retires

**Files:**
- Create: `godot/terrain/shaders/box_sand.glsl`
- Modify: `godot/terrain/voxel_box.gd` (`step(delta)`, active bricks, the stats readback shared with `TerrainSim` or its own)
- Modify: `godot/terrain/shaders/sim.glsl` (the loose half removed: `flux_loose`, `flux_loose_d`, `flux_fail`, `out_l`, `out_d`, transport, the failure; water only)
- Modify: `godot/terrain/terrain_sim.gd` (bindings; the Materials block stays for the box's use or moves to the box)
- Modify: `godot/terrain/material_set.gd` (`roof_span_dry` / `roof_span_saturated` named as the free height in the comment)
- Modify: `godot/terrain/terrain.gd` (`_process`: `box.follow`, `box.step`, `box.pack_dirty`, then `sim.step`)
- Modify: `godot/terrain/tool_run.gd` (the slump, seam, ends, scroll, evict, pickup, restart phases' deposits through `box.dump` at the cell's surface point, or window-side deposits followed by `reload`; the checks unchanged)
- Test: `godot/tests/test_terrain_sim.gd` (the push constants shrink; the material table moves to the box: `VoxelBox.material_table()`), `godot/tests/test_voxel_box.gd` (the free-height rule's arithmetic: `VoxelBox.wall_fails(step: float, w: float, stand_tan: float, free: float) -> bool`)

**Interfaces:**
- `VoxelBox.step(delta: float) -> void`: the fixed 1/60 s accumulator as `TerrainSim.step`; each step one list of a sand dispatch per active brick, a barrier, an apply dispatch per active brick (the flux pattern: each voxel column decides what leaves it downward and sideways from old state; the apply adds what arrives); then the stats readback (its own buffer: one word per brick slot, bit 0 moved, bit 1 a neighbour moved across the brick's face). The sand rule per voxel column of a brick (one invocation per (x, z) column of the brick, scanning its 16 voxels): loose with air below it falls one voxel a step (the whole fraction, into the voxel below, capped by its room); the top loose of each stack (loose with no loose above it in the brick or the brick above) slumps to the eight neighbouring stacks' tops by slice 3's excess-over-repose rule with the annulus volumes and the column's saturation (read from the window); and the surface cave-in: a stack's top solid voxel, where it is the column's top run (no air above in the box's range), standing over a disturbed neighbour's stack top (the neighbour's window `edit_mask` set) by more than `max(stand_tan × w, free)` fails by `slump_rate` of the excess over `max(stand_tan × w, free)`, converted to loose with the swell, with `free = mix(roof_span_dry, roof_span_saturated, saturation)` of the material. A brick's slot word gets bit 0 when any voxel in it changed over `move_eps` (in m of fraction), bit 1 on its face neighbours when an edge voxel did; `VoxelBox.settle(delta, flags)` keeps the active set as `TerrainSim.settle` does (`settle_time`, at most `MAX_ACTIVE_BRICKS := 64`), and a brick leaving the active set has its dirty columns packed.
- `sim.glsl` keeps: the water flux and apply, soak, wetting, the lake join, the reservoir rules; `transport_share` is unused and removed from the push constants with `slump_rate`, `repose_tan`; the Materials block binding goes.

- [ ] **Step 1: the failing tests:** `test_voxel_box.gd`: `wall_fails(3.0, 1.0, 1.0, 4.0) == false` (under the free height), `wall_fails(5.0, 1.0, 1.0, 4.0) == true`, `wall_fails(0.9, 1.0, 1.0, 0.0) == false`; `test_terrain_sim.gd`: the push constants are 96 bytes with `flow_rate` at 60 and `capacity[0]` at 64 (the exact offsets the builder lays out, pinned here).
- [ ] **Step 2:** FAIL. **Step 3: implement** the sand shader and the box's step, strip `sim.glsl`, move the material table to the box (`VoxelBox.material_table()` with stand and free heights and swell).
- [ ] **Step 4: port the tool run.** The deposit stamps the phases make (`_op(..., MODE_DEPOSIT, ...)`) stay window-side and are followed by `_terrain.box.reload(disc)`; a phase's `_settled(site)` waits for no active brick as well as no active tile (`_terrain.box.has_active()`); the slump phase's steepness check reads the window fields as before (packed each step). The pickup phase's cave-in now carries the free height: the 10 m shaft still caves (its expectation unchanged); the restart phase's 2.7 m shaft no longer caves: its `caved` term is dropped and the old loose expectation returns. The lake phase's bore stamp is window-side plus `reload`.
- [ ] **Step 5: the driver** `box_run` phase `sand`: a 30 m³ dump on flat ground settles within 10 s with its volume within 0.1 % and the steepest ground slope over the window fields at repose × 1.02 (the slump phase's check); phase `edge`: a 5 m³ dump 2 m inside the box's edge settles with its volume within 0.1 % (parked at the edge, none lost); phase `cave`: eight scoops at one spot (a pit about 3 m deep: stands, free height 4 m) then eight more (over 4 m: caves), the surface's steepest wall at most `max(tan 45° × w, 4 m)` per cell pair and the volume conserved as the pickup phase's; the sand's GPU time per active brick printed against 0.25 ms.
- [ ] **Step 6:** box_run PASS; tool_run PASS with the ports; `sh tests/run.sh` PASS; `edit_run.tscn` PASS (its dig is window-side: `Terrain.edit` reloads the box).
- [ ] **Step 7: Commit** `Terrain tunnels: loose dirt falls and slumps in the box; the cave-in with the free height; the window's loose simulation retires`.

### Task 6: The feet and the auger in the box

**Files:**
- Modify: `godot/terrain/shaders/box_edit.glsl` (modes 2 push, 3 tamp, 4 bore, 5 spoil)
- Modify: `godot/terrain/voxel_box.gd` (`push(p, dir, share, cap)`, `tamp(p, step, swell)`, `bore(p, radius, step, counted)`, `spoil(p, radius, volume)`)
- Modify: `godot/terrain/tools.gd` (`_on_stepped`, `_on_landed` through the box at the feet's point), `godot/terrain/auger.gd` (dry ticks through `box.bore`, deposits through `box.spoil`; wet ticks stay `MODE_BORE` on the window with `reload`), `godot/terrain/terrain.gd` (`set_obstacle` also tells the box; `stamp_tool` keeps the water modes)
- Modify: `godot/terrain/tool_run.gd` (the stamps phase's push and tamp checks through the box; walk, jumps and bore phases' expectations unchanged)

**Interfaces:**
- `VoxelBox.push(p: Vector3, dir: Vector2i, share: float, cap: float) -> bool`: the footprint's top loose fractions move `share` (at most `cap` m) to the stack ahead along `dir`, never into the obstacle; `tamp(p: Vector3, step: float, swell: float) -> bool`: the top loose voxels under the footprint gain `step` of compaction and fold into solid at 1 with the swell (the window's `compaction` byte follows at the pack); `bore(p, radius, step, counted)`: the disc's columns under `p` lose `step` m of solid from their top run (stopping at rock), counted by the annulus; `spoil(p, radius, volume)`: a dump spread over the disc.
- `Terrain.set_obstacle` passes the obstacle to the box (`box.obstacle`, `box.obstacle_radius`): the sand rule and the dump never move loose into it.

- [ ] **Step 1: the failing test:** `test_tools.gd`: `Tools.foot_point(player_pos, up)` (a static: the feet's station-local point 1 m under the origin) and the push direction unchanged.
- [ ] **Step 2: implement.** **Step 3: the drivers:** the tool run's stamps phase (`push moves forward, conserves`, `tamp folds with the swell`), walk, jumps, bore, box, pickup, pause, restart phases PASS through the box; `box_run` gains nothing new.
- [ ] **Step 4:** tool_run PASS; box_run PASS; `sh tests/run.sh` PASS.
- [ ] **Step 5: Commit** `Terrain tunnels: the feet push and tamp, the auger bores and spoils, in the box`.

### Task 7: Chunks: surface-nets meshes, trimesh colliders, the tile and patch stepping back, the headlamp

**Files:**
- Create: `godot/terrain/shaders/box_mesh.glsl`
- Create: `godot/terrain/chunk_mesh.gd` (`class_name ChunkMesh extends StaticBody3D`: a `MeshInstance3D` child and a `CollisionShape3D` with a `ConcavePolygonShape3D`)
- Create: `godot/terrain/shaders/chunk.gdshader` (the tile shader's material, speckle and light bar rules on a pre-bent mesh with per-vertex material in `COLOR.r`; the headlamp as an ordinary light in `light()`)
- Modify: `godot/terrain/voxel_box.gd` (touched chunks, `remesh(chunk)`, the readback into `ChunkMesh.set_arrays`)
- Modify: `godot/terrain/shaders/tile.gdshader`, `cylinder_tile.gdshaderinc` (a `chunk_mask` sampler over the window at 32 m; `in_hole` also true inside a touched chunk shrunk by the margin; the quarter-cell sink)
- Modify: `godot/terrain/shaders/collider_bake.glsl`, `collider_patch.gd` (the same mask: NaN over touched chunks; `covers` counts a chunk under the point as cover through `Terrain`)
- Modify: `godot/terrain/terrain.gd` (chunk nodes under Terrain; `_hold` counts chunks; the mask texture updated when touched changes)
- Modify: `godot/player.tscn` (a `SpotLight3D` headlamp under the camera, the terrain render layer)
- Test: `godot/tests/test_voxel_box.gd` (`chunk_of_cell`, the touched set from gap fields on a stub)

**Interfaces:**
- `VoxelBox.CHUNK := 32`; `touched: Dictionary` (chunk → true) rebuilt from the pack's per-column "has a gap" flags (a word per chunk in `box_stats`, read back with the activity); `func remesh_dirty() -> void` (at most one chunk per frame, the dirtiest first, throttled like the collider's edit bakes): a `box_mesh.glsl` dispatch over the chunk's bricks writing vertices (position bent to station space, normal, material) and global indices into the chunk's buffers with an atomic count, read back asynchronously, landed into `ChunkMesh.set_arrays(vertices, normals, colors, indices)` which rebuilds the `ArrayMesh` surface and the trimesh shape in one go (the old shape stays until the new one is assigned).
- `chunk_mask`: an `R8` texture, `window.size / 32` square, 1 where a chunk is touched, updated by `buffer_update`/`texture_update` from the CPU set (16 × 16 bytes).
- `Terrain.covered(p: Vector3) -> bool`: the patch covers `p` or a touched chunk holds the column under it (its mesh landed).

- [ ] **Step 1: the failing test:** `test_voxel_box.gd`: `VoxelBox.chunk_of_cell(Vector2i(100, 200)) == Vector2i(3, 6)`; `touched_from(gap_has: PackedByteArray over a 512 window)` returns the chunk set.
- [ ] **Step 2: implement.** Surface nets per brick: one invocation per voxel; a vertex where the density (solid + loose fractions) crosses `FRACTION_ONE / 2` along any of the voxel's three positive edges, placed at the mean of the crossings in the voxel; quads across each crossing edge between the four voxels around it; normals from the density gradient; the material from the solid voxel's material or loose dirt.
- [ ] **Step 3: the driver** `box_run` phase `tunnel`: with the player stood on flat ground, eight scoops down at one spot 2 m ahead (a pit to about 3 m, standing by the free height), the player teleported into the pit, then eight scoops sideways into its wall at the player's height (a tunnel 2 m across and about 4 m long); the chunk is touched, its mesh landed within 1 s (`ChunkMesh` node exists, its shape has triangles); the player walked 3 m into the tunnel by `W` for 1 s: never held, the clearance to the ground (through `Terrain.covered` and a ray down from the player) between 0 and 0.3 m every frame, through at least one remesh; the window's `surface` under the tunnel unchanged (the roof top); a shot `user://debug/box_tunnel.png` from inside looking out; the remesh GPU time per chunk printed against 0.5 ms and the trimesh build CPU ms against 2 ms.
- [ ] **Step 4:** box_run PASS; tool_run PASS; edit_run PASS; bake_check as before; `sh tests/run.sh` PASS.
- [ ] **Step 5: Commit** `Terrain tunnels: touched chunks drawn by surface nets and collided as trimeshes; the tiles and the patch step back; a headlamp`.

### Task 8: Dumping into a tunnel and the player's clearance there

**Files:**
- Modify: `godot/terrain/tools.gd` (`_clear_of` and `_physics_process` against `Terrain.covered` and the chunk's ground: a ray down from the feet against the terrain colliders in place of `patch.surface_point` where a chunk holds the column)
- Modify: `godot/terrain/box_run.gd`

- [ ] **Step 1: the driver** phase `inside`: in the tunnel of Task 7, a dump of 2 m³ at the tunnel's floor 2 m ahead: the loose lands on the floor (the gap's loose over the tunnel's columns sums to 2 m³ within 0.1 %, from `decode` of the packed columns), the player is not under the ground after it (the unbury rule fires at most once), a dump aimed at the tunnel's roof ends up on the floor too.
- [ ] **Step 2: implement; Step 3:** PASS. **Step 4: Commit** `Terrain tunnels: dumping inside a tunnel; the player kept out of the pile there`.

### Task 9: Persistence: scroll, teleport, restart, exit

**Files:**
- Modify: `godot/terrain/terrain.gd` (`_move_window` packs the box's dirty columns of evicted tiles first; `_exit_tree` calls `box.pack_all_sync` before the tiles' pack; `teleport` re-centres the box after the window)
- Modify: `godot/terrain/voxel_box.gd` (`evict_tiles(tiles)`: pack and drop the bricks over tiles leaving the window)
- Modify: `godot/terrain/box_run.gd`

- [ ] **Step 1: the driver** phase `scroll`: with the tunnel and its pile, 600 m away and back: the tunnel's columns bit for bit as before (the gap fields), the chunk touched and meshed again, the collider holds the player inside; phase `restart`: `_restart` as the tool run's: the tunnel, the pile and the chunk mesh are back, the player stands inside; phase `exit`: the exit pack line reports the box packed.
- [ ] **Step 2: implement; Step 3:** box_run PASS, tool_run PASS (its scroll, evict and restart phases through the box). **Step 4: Commit** `Terrain tunnels: tunnels survive scrolls, teleports, restarts and the exit`.

### Task 10: The tunnel run as the user plays it, notes, and the research doc

**Files:**
- Modify: `godot/terrain/box_run.gd` (a final `play` phase: the shovel through `Tools` with the real aim: the player looks down and holds T, then looks at the pit wall and holds T, walks in)
- Modify: `docs/terrain-research.md` 6.8 (a "Tunnels, 2026-11-xx" paragraph with the run's figures: GPU per pass, memory, the conservation residuals), `docs/superpowers/plans/2026-10-28-terrain-slice-3-followups.md` (what retired, what the box changed, what is left: water in tunnels, collapse, pillars, the fill-in-clay limit, the far ring), the memory note.

- [ ] **Step 1:** the play phase PASS. **Step 2:** the notes. **Step 3: Commit** `Terrain tunnels: the play phase; notes and figures`.
- [ ] **Step 4: Finish**: superpowers:finishing-a-development-branch against `terrain`.
