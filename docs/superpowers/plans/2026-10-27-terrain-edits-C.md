# Terrain Edits (Slice 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> Chosen over two independently written versions (A and B) by [review-terrain-edits.md](review-terrain-edits.md) and amended per its Part 4: the zone-move ordering rule (decision 8, Task 7), the topsoil test kept away from water (Task 2), the NaN-hole fallback removed (a settled engine fact), rock's colour for material 3 (Task 3); transplanted from the other versions: the render-loop blackout route in the smoke driver (Task 8), a 30 s autosave (Task 6), a headless material-set test (Task 3) and crosshair aim for the debug dig (Task 5).

**Goal:** A per-cell edit of the terrain survives the window scrolling away and back and a restart, is drawn by the detail pass and stood on by the collider, and the collider keeps up with edits at a hand tool's rate without a visible hitch.

**Architecture:** Edits are absolute per-cell overrides stored as one dense 128 × 128 blob per edited tile (all eight window fields plus a mask byte), produced and consumed only by compute passes: a stamp pass writes the live window and marks the mask, a pack pass reads the touched tiles back into CPU blobs, and an apply pass copies a tile's blob over the detail pass's output whenever that tile enters the window. The collider gets a 65 × 65 edit heightfield on the same static body that rebakes per edit, with a NaN hole punched in the 257 × 257 patch under it, so the 2.8 ms Jolt build of the big patch happens only when the edit zone moves; the bake shader is rewritten to one invocation per output sample so a bake costs well under 0.1 ms. Smaller items (bedrock face flag, `theta_of` range, topsoil on slopes, hold-rule tests, held rigid bodies) ride along as their own tasks.

**Tech Stack:** Godot 4.7.2 standard build, Forward+, Jolt, GDScript, GLSL compute on the main `RenderingDevice` (storage buffers, `buffer_update`, `buffer_get_data_async`, `texture_get_data_async`), `HeightMapShape3D` with NaN holes, zstd via `PackedByteArray.compress`.

**Spec:** None reachable for this slice. This plan argues from the follow-ups doc [docs/superpowers/plans/2026-10-27-terrain-slice-1-followups.md](2026-10-27-terrain-slice-1-followups.md) (items R1, R3, R4, R5, R6, R7, "topsoil thin on steep slopes", "`collider_bake.glsl` occupancy", "a second collider patch per rigid body"), the slice 1 spec [docs/superpowers/specs/2026-10-24-terrain-slice-1-design.md](../specs/2026-10-24-terrain-slice-1-design.md) (sections 4.2, 6.2, 7, 9, 12) and the research doc [docs/terrain-research.md](../../terrain-research.md) (6.1, 6.6, 6.8). Every call the plan makes is in the Decisions section below, each with the alternative and the reason; executors read those as the spec.

## Global Constraints

- Godot 4.7.2 only; no GDExtension.
- Grid: `Δθ = 2π / 16384`, `Δz = 1 m`, heights radial from the hull, 1 m cells, 512 window (`terrain/window_size`, 512 or 1024), tiles of 128, 4 × 4 slots at 512. Window fields as built: `surface`, `bedrock_top`, `clay_bottom`, `clay_top`, `water_surface` as `R32_SFLOAT` metres (`HEIGHT_SCALE = 1`), `material`, `compaction`, `saturation` as `R8_UNORM`; this plan adds `edit_mask` (`R8_UNORM`). Ordering invariant `0 ≤ bedrock_top ≤ clay_bottom ≤ clay_top ≤ surface` holds in every cell after every pass, edited or not.
- No per-cell GDScript loop on any per-frame path. Blobs move as whole `PackedByteArray`s; per-cell work is GLSL. Debug dumps and windowed drivers may loop (they are not the game's frame).
- Everything in the world is a child of `Station`; terrain code uses station-local `(θ, z)` only.
- Headless tests cannot create a `RenderingDevice`; GPU work is verified by short windowed drivers that print numbers, save screenshots and quit (they open a window on the user's screen, so they stay under a minute). Headless tests follow the existing pattern (`extends SceneTree`, `_initialize`, `check`, print `PASS`, `quit`) and run via `godot/tests/run.sh`.
- Budgets (slice 1 spec section 12) still apply: detail under 2 ms per tile, collider bake under 1 ms GPU, GPU frame mean under 6 ms at 1440p, hitch under 4 ms. GPU timestamps come from `capture_timestamp` pairs read by `timing_overlay.gd`; they are non-zero only under `--rendering-driver vulkan` (MoltenVK); Metal returns zeros, so every GPU number in this plan is a Vulkan number and the Metal run checks only CPU times and behaviour. Task 9 says how each is measured.
- Commit after each task with the message given. Windowed drivers that instantiate `main.tscn` set `Terrain.persist_edits = false` so they never write into `user://worlds/default/tiles/`.

## Decisions

Each entry: the call, the alternative, why.

1. **Edit storage is dense per tile: one `PackedByteArray` of 128 × 128 × 24 bytes per edited tile (393,216 B), keyed by the wrapped tile index `Vector2i(ti, tj)`, cell `(i, j)` of the world at byte `((j mod 128) · 128 + (i mod 128)) · 24`.** Per cell: five `float32` heights (`surface`, `bedrock_top`, `clay_bottom`, `clay_top`, `water_surface`) then one `uint32` packing `material | compaction << 8 | saturation << 16 | mask << 24`, mask 255 where the cell was edited, 0 elsewhere. Alternative: a sparse list of `(cell, values)` per tile. Rejected because building it for upload is a per-edited-cell GDScript loop at every tile entry (thousands of cells for a dug area, milliseconds on a window step), and an append-only log grows without bound when the same cell is edited again. The dense blob is written and read only by compute passes and `buffer_update`/`buffer_get_data_async`, never looped in GDScript; the mask keeps unedited cells following the generator, so a later tuning of `detail.glsl` (R2) does not freeze whole tiles; zstd on disk collapses the zeros (a few pits cost kilobytes).
2. **All eight fields are overridden, not a subset.** A dig cuts through clay into rock and changes four heights and the material at once; storing everything makes the apply pass a copy, not a merge, and gives the later slices' simulation outputs (compaction, saturation, water) the same path. Cost of the three bytes that stay zero in this slice: 3 of 24 per cell.
3. **The GPU reads a blob through one upload storage buffer (`_up`, 393 KB) and an apply pass dispatched in the same render-thread callback as the detail pass, right after the detail compute list.** R1 says "the same compute list"; `buffer_update` is refused while a compute list is open, so each applied tile is its own short list after the detail list, in the same `_dispatch` callback, before anything draws; the render graph serialises the detail writes, the upload and the apply. Alternative: one list with a buffer slot per entering tile (up to 16 on a teleport, 6.3 MB of buffers). Not worth it for a per-window-step cost of one 393 KB upload per edited entering tile.
4. **Edited tiles are read back at edit time, not when they leave the window.** After every stamp, a pack pass copies each touched tile (1 to 4, radius under a tile) into a slot of a 4-slot download buffer (`_down`, 1.57 MB) and `buffer_get_data_async` lands it in `blobs[tile]` a few frames later. Alternative: pack when the tile leaves. Rejected because a tile can leave and re-enter within `frame_queue_size` frames (a viewer dithering on a tile boundary, or a teleport there and back) while its readback is in flight, and the stale blob would then be applied and later clobbered; reading back at edit time makes the blob current from a few frames after the stamp. Limit, accepted for this slice: a stamped tile evicted and re-entered within those two frames is applied from its old blob and nothing re-applies when the pack lands; a hand tool edits within reach, never on a tile about to leave, and the dig slice's op kernel adds a per-slot generation. Readback cost at a hand tool's 10 Hz: about 4 MB/s, far inside the 128 MB download ring.
5. **Memory.** GPU: `edit_mask` 256 KB at 512 (1 MB at 1024) on the main window and the same, unused, on the far window (it shares `FIELDS`); `_up` 393 KB; `_down` 1.57 MB; total about 2.5 MB at 512, 4.0 MB at 1024. CPU: 393 KB per edited tile, uncompressed in RAM (ponytail: a thousand edited tiles is 400 MB; compress in RAM when a profile shows it). Note: the slice 1 window is 23 bytes per cell (6.0 MB at 512, 24 MB at 1024) because the builder chose `R32_SFLOAT` over the spec's `R16`; that budget line was already past and is not this slice's.
6. **Persistence: one file per edited tile under `user://worlds/<name>/tiles/<ti>_<tj>.edit`: `u32 version = 1`, `u32 raw_size = 393216`, then the blob zstd-compressed.** Saved when `Terrain` leaves the tree (quit included) if `persist_edits` is true, loaded in `_ready` before the first `move_to` so the spawn tiles get their edits in their first dispatch. Alternative: one `edits.res` resource with a dictionary; rejected because a corrupt or oversized single file loses every tile, and per-tile files are what the slice 1 spec reserved `tiles/` for.
7. **Edit API: `Terrain.edit(theta, z, radius, dh) -> bool`, a disc stamp in world coordinates, plus `EditLayer.stamp(window, cell, radius_cells, dh)` under it.** The stamp is a GPU op (kind 0: raise or lower with a parabolic falloff, strata cut by `min` on the way down, dirt added on the way up, mask set). Alternative: a cell list API (`edit_cells(cells, values)`). Rejected for this slice because the tools that will call it (auger, tamper) are shaped ops too and a cell list would put the shape loop in GDScript; the op struct has a `kind` for the tool slice to extend. The debug input that exercises the pipeline is `DebugEdit`: holding `[` lowers and `]` raises a 5 m disc by 0.25 m per stamp at 10 stamps per second, centred on the ground under the screen centre, found by a physics ray from the current camera against the live collider (the viewer's own body excluded), so you dig where you look; no hit, no stamp. It exists only to drive the pipeline; the real tools are a later slice. Edits whose disc is not fully inside the 1 m window are refused (`false`): a hand tool is within reach, and applying to non-resident tiles would need a CPU merge.
8. **R3: a 65 × 65 edit heightfield (`EditShape`, a second `CollisionShape3D` on the same `ColliderPatch` body) rebakes per edit; the 257 × 257 patch gets a NaN hole of 45 × 45 cells under it and rebakes only when the edit zone moves.** The zone is the cell the edit shape is centred on; an edit whose disc stays within 18 cells (`HOLE_HALF − ZONE_MARGIN`) of it needs only the edit bake (GPU well under 0.1 ms, 17 KB readback, a Jolt build of 4,225 samples at about 0.2 ms); an edit outside moves the zone and rebakes both (one 2.8 ms Jolt build, the existing cost, once per 36 m of trench). Alternatives: (a) rebake the big patch per edit, throttled to one in flight: 2.8 ms of main-thread time at every edit, fine on this machine at 10 Hz but a dropped frame per edit on a slower one, and it cannot scale to the later slices' per-frame refresh under flowing material; (b) a second `StaticBody3D` for the edit patch: Jolt's internal-edge removal does not cross bodies, so a box sliding over the rim would snag; one body, two shapes keeps it inside one contact set. The hole is punched in cell space by the bake shader (the covering cell of each output sample is known there), so it is exact whatever the two frames' rotation; the edit shape covers at least 26 cells across at the hull and 32 along, the hole 22, Jolt drops the triangles touching a NaN sample, which leaves 2 cells of overlap at the worst height. Readbacks on a zone move are requested edit shape first, then big patch, so the hole never lands before the shape under it (both callbacks run in the same frame, in order, between physics ticks). If an edit bake is already in flight when the zone moves, nothing is issued yet, and a landing never dispatches GPU work: it only sets the `_again_edit` / `_again_big` flags. The next frame's `Terrain._process` issues the pending edit bake for the new zone, when that bake lands it sets the flag for the big bake, and the following `_process` issues it, so the big bake with the new hole lands at least one frame after the edit bake for the same zone and a hole never lands before the shape under it even then. The mechanism, in one sentence: `texture_get_data_async` callbacks run in `RenderingDevice::_begin_frame` → `_stall_for_frame`, between the previous frame's submit and the new frame's graph begin, so a compute list recorded inside the callback is discarded and an async readback requested there reads an unwritten staging buffer (seen on this branch: `godot/terrain/noise_report.gd` waits one frame after `collider_live` for this reason, and Task 2's report records the zeros).
9. **NaN holes are an engine fact, not a bet.** In 4.7.2 the Jolt module maps a NaN sample to Jolt's no-collision value and drops every triangle touching it (`jolt_height_map_shape_3d.cpp`; confirmed by the review's headless probe: a ray through the hole misses, the rim triangles are gone, a second shape on the same body shows through). Task 4's windowed driver still drops a box through a hole, as a regression pin.
10. **Bake shader: one invocation per output sample (8 × 8 groups, `ceil(n / 8)²` of them), scanning only the input samples that can cover its column.** Every mapped sample has `x` between `(R − h_max) sin φ` and `R sin φ`, so the segments covering output `x` have `k` in `[floor(asin(|x| / R) / Δθ) − 1, ceil(asin(|x| / (R − h_max)) / Δθ) + 1]` (mirrored for `x < 0`, clamped to `±half_n`): up to 100 samples at the edge of the big patch, about 50 on average, 25 at the edge of the edit patch, each one image load. 66k invocations by 50 iterations is a few million loads: under 0.1 ms on this GPU, against 0.4 to 1.8 ms today from 257 threads each holding a 1 KB local array. Alternative: two passes, map every sample to `(x, y)` in a buffer then max per column; one more dispatch and buffer for no gain, since the fetch dominates and the loop is already per column. The shader is parametric in `n` (257 or 65) and takes the hole as `(hole_cell, hole_half)`; `Cyl.bake_row` stays the CPU reference and the windowed check compares a GPU row against it.
11. **Hold rule and rebakes.** `covers()` reads only the frame, which changes only when a readback lands together with its data; a bake in flight never holds the player. A hole is always backed by the edit shape (decision 8), so `covers()` stays the big patch's extent. `surface_point` (used by `teleport` and `_on_live`) falls back to the edit shape when any of its four big-patch samples is NaN, so a teleport into a pit stands the body in the pit. `_on_live` and `_on_first_live` run inside the readback callback (decision 8) and do only CPU work there (moving the body, setting the viewer, emitting `collider_live`); they must stay that way, and anything that wants a bake after them waits a frame.
12. **R4: the far window shows no edits; documented, not approximated.** The 8 m ring regenerates from macro; a 1 m pit is below its resolution and a hand tool edits within 256 m of the viewer, so the only visible effect is an edit appearing when its tile crosses from the ring into the window. Alternative: a downsampling apply of the main-window blobs into far tiles (up to 64 blobs per far tile, many not in RAM). Deferred to the slice that stores a coarse edit layer; `far_terrain.gd`'s header says so.
13. **R5: the headless test of `ColliderPatch.covers` and `Terrain._hold` is Task 8's `test_hold_rule.gd`; the windowed check that stops the render loop for 10 s is a `--blackout` route in the existing `smoke_run.gd` (Task 8), whose counters and summary already exist; it is R5's literal check and costs no new scene.** The `covers` geometry test already in `test_terrain_window_math.gd` stays.
14. **R6: material id 3 (`MaterialSet.ROCK_FACE`) marks a cell whose `bedrock_top` the detail pass lifted to the surface on a face over 60°; where rock would be at the surface anyway the id stays 2.** A consumer of `bedrock_top` treats `material == 3` as "no stratum here" (read neighbours or the macro map). Alternatives: a flag field (one more texture and binding, 256 KB, and another byte in the blob), or a documented rule with no data (a consumer cannot tell a lifted bedrock from a real outcrop). An edited cell's strata are real, so the stamp never writes 3. Tested by the window dump (Task 3) on a cliff window: every material-3 cell has `bedrock_top == surface` and the count is non-zero.
15. **R7: `Cyl.theta_of` returns strictly inside `[0, TAU)` (a result that rounds to `TAU` becomes 0) and `WorldParams.cell_of(theta, z)` is the one place that turns an angle into a column (its `posmod` guards the float division, which can still round to `n_theta`).** The four inline copies (`terrain.gd` twice, `collider_patch.gd`, `debug_window.gd`) switch to `cell_of`; `emitter.gd`, `light_bar.gd`, `smoke_run.gd` and `click_teleport.gd` use the angle in trigonometry or wrap differences and need no change. Alternative: leave `theta_of` and keep wrapping in every consumer; rejected because the edit path adds consumers and R7 asks for the guarantee before they appear.
16. **Topsoil thin on steep slopes: in `MacroGenerator._strata`, the soil depth `D` is scaled by `clamp(1 − slope / tan(soil_slope_deg), 0, 1)` with the macro central-difference slope, knob `WorldParams.soil_slope_deg = 30`.** Cliff cells stay `D = 0`. 30° makes the cell under a cliff rim (32° by central difference) bare and leaves mountain slopes (14°) with half their soil; at 45° nothing between cliffs would change. Alternative: leave it to the detail pass's face rule; rejected because the follow-ups ask for the macro half, which is what moves bedrock depth. Tested on the small world with the knob at 12°, on land cells with no water within two macro cells (`_banks` runs after `_strata` and steepens water-adjacent cells after their soil depth was chosen).
17. **A second collider patch per rigid body is deferred; this plan holds rigid bodies the live patch does not cover, the way it holds the player.** Boxes join the `terrain_ground` group when spawned, `Terrain._process` disables any member the patch does not cover (removing it from the physics space, so it hangs where it is) and re-enables it when the patch returns; so boxes near the frozen player no longer fall to the hull while the fly camera is away. Design for the next slice: `ColliderPatch` is parametric after Task 4 (any sample count, any centre, baked from the window or the macro map), so a per-body patch is one `ColliderPatch(65)` per body or cluster that the big patch does not cover, rebaked when its body moves more than 16 m from its centre, freed when the big patch covers it again; the bodies come from the `terrain_ground` group; each costs a 17 KB readback and a 0.2 ms Jolt build. Deferred because the symptom is a debug-camera artefact and the hold is ten lines against a body registry and patch lifecycle.
18. **Measurement.** GPU: `capture_timestamp` pairs `detail`, `bake`, `bake_edit`, `edit` (stamp plus pack) and `apply`, read by `timing_overlay.gd` and recorded by the driver, under Vulkan; frame GPU time from `viewport_get_measured_render_time_gpu`. CPU: `Time.get_ticks_usec` around each `map_data` assignment, reported through `ColliderPatch.baked`; frame intervals from the process delta. The driver asserts behaviour (survived, never held, never fell) and prints the timings against the budgets; the user judges the timings.

## File Structure

- `godot/terrain/cyl.gd`: `theta_of` range fix (Task 1).
- `godot/terrain/world_params.gd`: `cell_of`, `soil_slope_deg` (Tasks 1, 2).
- `godot/terrain/macro_generator.gd`: slope-scaled soil depth in `_strata` (Task 2).
- `godot/terrain/material_set.gd`, `materials.tres`, `shaders/detail.glsl`, `shaders/tile.gdshader`, `shaders/far.gdshader`, `debug_window_dump.gd`, `debug_window.gd`: rock face id (Task 3).
- `godot/terrain/shaders/collider_bake.glsl`: rewritten, parametric, with a hole (Task 4).
- `godot/terrain/collider_patch.gd`: generic bake, edit shape, zone, NaN-aware `surface_point` (Tasks 4, 7).
- `godot/terrain/edit_layer.gd`, `godot/terrain/shaders/edit.glsl`: the edit layer, new (Task 5).
- `godot/terrain/terrain_window.gd`: `edit_mask` field, `edits`, `is_resident`, apply after detail (Task 5).
- `godot/terrain/terrain.gd`: `edit`, `persist_edits`, `_hold` for the ground group, `cell_of` (Tasks 1, 5, 6, 7, 8).
- `godot/terrain/debug_edit.gd`: debug stamp keys, new; `godot/main.tscn` gains the node (Task 5).
- `godot/terrain/world_io.gd`: `save_edits`, `load_edits` (Task 6).
- `godot/terrain/far_terrain.gd`: one doc line (Task 5). `godot/terrain/timing_overlay.gd`: new pass names (Task 5, 7). `godot/emitter.gd`: group membership (Task 8).
- Drivers: `godot/terrain/bake_check.gd/.tscn` (Task 4), `godot/terrain/edit_run.gd/.tscn` (Tasks 5, 7, 9), `godot/terrain/smoke_run.gd` (the `--blackout` route, Task 8).
- Tests: `godot/tests/test_cylinder_math.gd`, `test_macro_maps.gd`, `test_macro_generator.gd`, `test_terrain_window_math.gd` (additions); `test_material_set.gd`, `test_edit_layer.gd`, `test_hold_rule.gd` (new).
- Notes: `docs/terrain-research.md` measurements, `docs/superpowers/plans/2026-10-27-terrain-edits-followups.md` (Task 9).

## Review Focus

1. An edit straddling the θ = 2π seam (a disc around column 1 touches tiles 127 and 0): the stamp's bounding box, the pack and the apply must wrap. Pinned by `test_edit_layer.gd` (`stamp_tiles` across the seam) in Task 5 and by `edit_run.gd`, which digs at θ = 0 exactly and checks the texels in both tiles survive the scroll.
2. A world whose spawn tiles carry persisted edits: the blobs must be applied in the very first dispatch or the player spawns on unedited ground and the edit pops in later. Pinned by Task 6's windowed restart (dig at spawn, quit, start: "Loaded N edited tiles", the pit is there and stood on).
3. An edit that moves the zone while a big-patch bake is in flight (digging while walking): the pending bake carries the old hole, so a second bake with the new zone must follow, and no physics tick may see a hole without the edit shape under it. Pinned by `zone_holds` in `test_edit_layer.gd` and by `edit_run.gd`'s trench phase (zero holds, never under the collider) in Task 7.
4. Raising the ground under a resting body or the player: the heightfield rises into it; Jolt must push it out, not trap it. Pinned by `edit_run.gd`'s raise phase in Task 7 (the player's and the box's clearance to the edit shape end in `[0, 1.5]` m).
5. An edit at the station's end rows: rows below 0 or past `n_z` must be skipped by the stamp and never make a tile outside `[0, tiles_along)` wanted. Pinned by `stamp_tiles` at `j = 1` and `j = n_z − 2` in `test_edit_layer.gd` (Task 5).

---

### Task 1: `theta_of` strictly inside `[0, TAU)` and `WorldParams.cell_of`

**Files:**
- Modify: `godot/terrain/cyl.gd:12-14`, `godot/terrain/world_params.gd`, `godot/terrain/terrain.gd:74,301`, `godot/terrain/collider_patch.gd:101`, `godot/terrain/debug_window.gd:287`
- Test: `godot/tests/test_cylinder_math.gd`, `godot/tests/test_macro_maps.gd`

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `static func Cyl.theta_of(p: Vector3) -> float`: as today, but a result of `TAU` (a tiny negative angle whose `fposmod` rounds up) is returned as `0.0`; the contract `0.0 <= result < TAU` is in the doc comment.
  - `func WorldParams.cell_of(theta: float, z: float) -> Vector2i`: `Vector2i(posmod(floori(theta / dtheta()), n_theta()), floori(z + length / 2.0))`. θ wraps (the `posmod` also guards `theta / dtheta()` rounding up to `n_theta`); z is not clamped, matching the four sites it replaces (`tile_of_cell` and the bake clamp rows themselves).

- [ ] **Step 1: Write the failing tests**

Append to `test_cylinder_math.gd` after the round-trip loop:

```gdscript
	# theta_of is strictly inside [0, TAU): a hair antispinward of theta = 0 is never TAU.
	for e in [1e-20, 1e-12, 1e-7]:
		var t := Cyl.theta_of(Vector3(-e, -1, 0))
		check(t >= 0.0 and t < TAU, "theta_of(-%g) = %.17f" % [e, t])
	check(Cyl.theta_of(Vector3(0, -1, 0)) == 0.0, "theta_of at theta 0")
```

Append to `test_macro_maps.gd` before `if failed:`:

```gdscript
	# cell_of: the 1 m cell of (theta, z); theta wraps (TAU and a hair under it both land in a real column), z counts from -L/2.
	var d := WorldParams.new()
	check(d.cell_of(0.0, -d.length / 2.0) == Vector2i(0, 0), "cell 0")
	check(d.cell_of(TAU, 0.0) == Vector2i(0, 16000), "theta = TAU wraps to column 0")
	check(d.cell_of(TAU - 1e-12, 0.0).x == 16383, "a hair under TAU is the last column")
	check(d.cell_of(-0.5 * d.dtheta(), 0.0).x == 16383, "negative theta wraps")
	check(d.cell_of(1.0, 123.7) == Vector2i(2607, 16123), "an ordinary cell %s" % d.cell_of(1.0, 123.7))
```

- [ ] **Step 2: Run them to verify they fail**

Run: `cd godot && godot --headless --path . --fixed-fps 60 --quit-after 7200 -s res://tests/test_cylinder_math.gd; godot --headless --path . --fixed-fps 60 --quit-after 7200 -s res://tests/test_macro_maps.gd`
Expected: `theta_of(-1e-20)` fails (returns `TAU`); `cell_of` is not found.

- [ ] **Step 3: Implement `theta_of` and `cell_of`, replace the four inline cell computations**

`cyl.gd`: compute `fposmod` into a local and return `0.0` when it is `>= TAU`. `world_params.gd`: `cell_of` as above with a doc comment naming the wrap guard. Replace `terrain.gd:74` (`cell` from `spawn`), `terrain.gd:301` (`viewer_cell`), `collider_patch.gd:101` (`cell` in `rebuild`) and `debug_window.gd:287` (`--spawn`) with `params.cell_of(...)` (the `WorldParams` instance each already has); `viewer_cell`'s comment about `posmod` moves to `cell_of`.

- [ ] **Step 4: Run the suite**

Run: `cd godot && sh tests/run.sh`
Expected: every test prints `PASS`.

- [ ] **Step 5: Commit**

```bash
git add godot/terrain/cyl.gd godot/terrain/world_params.gd godot/terrain/terrain.gd godot/terrain/collider_patch.gd godot/terrain/debug_window.gd godot/tests/test_cylinder_math.gd godot/tests/test_macro_maps.gd
git commit -m "Terrain: theta_of strictly inside [0, TAU); WorldParams.cell_of holds the column wrap"
```

---

### Task 2: Topsoil thin on steep slopes

**Files:**
- Modify: `godot/terrain/world_params.gd`, `godot/terrain/macro_generator.gd:475-537` (`_strata`)
- Test: `godot/tests/test_macro_generator.gd`

**Interfaces:**
- Consumes: `WorldParams.bedrock_depth`, `_strata`'s `surface` array and `d`.
- Produces: `@export var WorldParams.soil_slope_deg: float = 30` with the doc "Macro slope, in degrees, at and above which the soil depth is zero; below it the depth scales by 1 − slope / tan(soil_slope_deg)". In `_strata`, `d *= clampf(1.0 - slope / tan(deg_to_rad(p.soil_slope_deg)), 0.0, 1.0)` applied right after `d` is chosen from the region range (before the island taper; cliff cells keep `d = 0`), where `slope` is the central difference of `surface`: across, `(surface[y·w + posmod(x + 1, w)] − surface[y·w + posmod(x − 1, w)]) / (2 · (p.radius − s) · 32 · p.dtheta())`; along, `(surface[clampi(y + 1, 0, h − 1)·w + x] − surface[clampi(y − 1, 0, h − 1)·w + x]) / (2 · p.macro_cell)`; `slope = Vector2(across, along).length()`. A helper `func _slope(surface: PackedFloat32Array, x: int, y: int, s: float, w: int, h: int, p: WorldParams) -> float` holds it.

- [ ] **Step 1: Write the failing test**

In `test_macro_generator.gd`, set `p.soil_slope_deg = 12.0` in `small_params` (so slopes between cliffs count as steep on the small world) and append after the clay lens check:

```gdscript
	# Topsoil thins with slope: a land cell whose macro slope reaches soil_slope_deg is bare rock, gentle land keeps soil.
	# Cells within two of water are left out: _banks runs after _strata and steepens them after their soil depth was chosen.
	var soil_tan := tan(deg_to_rad(p.soil_slope_deg))
	var steep := 0; var steep_bare := 0; var gentle_soil := 0
	for y in range(1, h - 1): for x in w:
		if m.region.get_pixel(x, y).r8 == 0: continue
		var wet := false
		for dy in range(-2, 3): for dx in range(-2, 3):
			if m.water_surface.get_pixel(posmod(x + dx, w), clampi(y + dy, 0, h - 1)).r > 0.0: wet = true
		if wet: continue
		var s := m.surface.get_pixel(x, y).r
		var sx := (m.surface.get_pixel(posmod(x + 1, w), y).r - m.surface.get_pixel(posmod(x - 1, w), y).r) / (2.0 * (p.radius - s) * 32.0 * p.dtheta())
		var sz := (m.surface.get_pixel(x, y + 1).r - m.surface.get_pixel(x, y - 1).r) / (2.0 * p.macro_cell)
		var depth := s - m.bedrock_top.get_pixel(x, y).r
		if Vector2(sx, sz).length() >= soil_tan:
			steep += 1
			if depth < 1e-3: steep_bare += 1
		elif Vector2(sx, sz).length() < 0.25 * soil_tan and depth > 1.0:
			gentle_soil += 1
	check(steep > 0, "no steep land on the small world")
	check(steep_bare == steep, "steep land is bare rock: %d of %d" % [steep_bare, steep])
	check(gentle_soil > 0, "gentle land keeps soil")
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd godot && godot --headless --path . --fixed-fps 60 --quit-after 7200 -s res://tests/test_macro_generator.gd`
Expected: `soil_slope_deg` not found, or "steep land is bare rock" fails (the cell below a cliff rim keeps its soil today).

- [ ] **Step 3: Implement the knob and the scaling**

As in Interfaces. The determinism and ordering checks already in the test must still pass (the term is deterministic and only lowers `b`). While adding the field, fix the header comment of `world_params.gd`: in 4.7.2 `ResourceSaver` omits exported fields that equal their defaults (the default world's file holds only `script`), so a world file does not reproduce itself against later default changes; a world takes the current defaults for every field its file omits.

- [ ] **Step 4: Run the suite**

Run: `cd godot && sh tests/run.sh`
Expected: all `PASS`. Note for the user: the stored default world predates the knob; it changes only on regeneration (delete `user://worlds/default`, about 2 minutes on first run), and the knob is not pinned by the world file (Step 3). The later windowed drivers run on whichever world is present.

- [ ] **Step 5: Commit**

```bash
git add godot/terrain/world_params.gd godot/terrain/macro_generator.gd godot/tests/test_macro_generator.gd
git commit -m "Terrain: soil depth thins with macro slope, soil_slope_deg knob"
```

---

### Task 3: Rock face material id (R6)

**Files:**
- Modify: `godot/terrain/material_set.gd`, `godot/terrain/materials.tres`, `godot/terrain/shaders/detail.glsl:321-332`, `godot/terrain/shaders/tile.gdshader:10,49`, `godot/terrain/shaders/far.gdshader:14`, `godot/terrain/debug_window_dump.gd`, `godot/terrain/debug_window.gd`
- Test: `godot/tests/test_material_set.gd` (new)

**Interfaces:**
- Consumes: `detail.glsl`'s `face` and `b + nb`.
- Produces:
  - `const MaterialSet.ROCK_FACE := 3` with the doc: "3 marks a cell whose bedrock_top the detail pass lifted to the surface because the face is steeper than 60°; its bedrock_top is not a stratum (read a neighbour or the macro map). Never written by an edit." `names` gains `"rock_face"`; every per-material array gains a fourth entry equal to rock's; `color` gains a fourth entry equal to rock's (the id is data; cliffs look as they do today). `materials.tres` carries the same four entries.
  - `detail.glsl`: `material = (face && b + nb < h - 0.01) ? 3.0 : (bt >= h - 0.01 ? 2.0 : (ctt >= h - 0.01 ? 1.0 : 0.0))`, with the rule in the comment above it.
  - `tile.gdshader`: `uniform vec4 material_color[4]`, id clamped to `0..3`. `far.gdshader`: `material_color[4]` (it still indexes 0 and 2).
  - `debug_window_dump.gd`: four colours, four counts, prints `face N`, and checks every material-3 cell has `bedrock_top` within 1e-3 of `surface` and every material-2 cell has `bedrock_top >= surface − 0.01`, printing `material rule: ok` or the first offending cell. It reads `bedrock_top` back like `surface`.
  - `debug_window.gd`: `-- --cliff` centres the window on the first macro cell with `cliff` 255 (scan `maps.cliff`), so a face is guaranteed in view.

- [ ] **Step 1: Write the failing test**

`godot/tests/test_material_set.gd` (from version B):

```gdscript
extends SceneTree

var failed := false

func check(ok: bool, msg: String) -> void:
	if not ok:
		push_error(msg)
		failed = true

func _initialize() -> void:
	var m: MaterialSet = load("res://terrain/materials.tres")
	check(MaterialSet.ROCK_FACE == 3, "rock face id")
	check(m.names.size() == 4 and m.names[3] == "rock_face", "names %s" % [m.names])
	for prop in ["color", "porosity", "wetting_distance", "swell_factor", "repose_dry", "repose_damp", "repose_saturated",
			"roof_span_dry", "roof_span_saturated", "stable_slope_dry", "stable_slope_saturated", "compression_index"]:
		var a = m.get(prop)
		check(a.size() == 4, "%s has 4 rows" % prop)
		check(a[3] == a[2], "%s: rock face equals rock" % prop)
	if failed: quit(1)
	else: print("PASS"); quit(0)
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd godot && godot --headless --path . --fixed-fps 60 --quit-after 7200 -s res://tests/test_material_set.gd`
Expected: parse error, `ROCK_FACE` not found.

- [ ] **Step 3: Make the changes**

No headless test reaches the GPU; the dump is the windowed check. Implement the items above.

- [ ] **Step 4: Windowed check**

Run: `cd godot && godot --path . res://terrain/debug_window.tscn -- --cliff --auto`
Expected output: `window surface min .. max ..; dirt N clay N rock N face N cells; ..` with `face` greater than 0, then `material rule: ok`. `user://debug/window_material.png` shows the face colour on the cliff band. No `ERROR` lines.

Run: `cd godot && godot --path .` for ten seconds: the terrain draws exactly as before. Quit.

- [ ] **Step 5: Run the suite**

Run: `cd godot && sh tests/run.sh`
Expected: all `PASS`, `test_material_set.gd` among them.

- [ ] **Step 6: Commit**

```bash
git add godot/terrain/material_set.gd godot/terrain/materials.tres godot/terrain/shaders/detail.glsl godot/terrain/shaders/tile.gdshader godot/terrain/shaders/far.gdshader godot/terrain/debug_window_dump.gd godot/terrain/debug_window.gd godot/tests/test_material_set.gd
git commit -m "Terrain: material 3 marks a rock face whose bedrock_top is not a stratum"
```

---

### Task 4: Bake shader at one invocation per output sample, parametric patch with a hole

**Files:**
- Modify: `godot/terrain/shaders/collider_bake.glsl` (rewrite), `godot/terrain/collider_patch.gd`
- Create: `godot/terrain/bake_check.gd`, `godot/terrain/bake_check.tscn`
- Test: `godot/tests/test_terrain_window_math.gd`

**Interfaces:**
- Consumes: `Cyl.bake_row` (the reference), `TerrainWindow` textures and `wanted_origin`, `WorldParams.cell_of`.
- Produces:
  - `collider_bake.glsl`: `local_size 8 × 8 × 1`; push constants (std430, 64 bytes): `ivec2 center` (cell), `ivec2 first_tile`, `int n_theta`, `int tiles_around`, `int slots`, `int half_n`, `float dtheta`, `float radius`, `float macro_cell`, `int n` (samples per side), `ivec2 hole_cell`, `int hole_half` (−1 for none), `float h_max`. Output texel `(i, j)`, `i, j < n`, `mid = (n − 1) / 2`, is the height at `x = i − mid`, `z = j − mid` in the patch frame. `surface(i, j)` is unchanged (window texel when resident, bilinear macro otherwise). The per-sample algorithm, which the signature does not determine:

    ```
    x = i - mid; row = center.y + j - mid
    if x >= 0: k_lo = floor(asin(min(x / R, 1)) / dtheta) - 1; k_hi = ceil(asin(min(x / (R - h_max), 1)) / dtheta) + 1
    else:      k_lo = -(ceil(asin(min(-x / (R - h_max), 1)) / dtheta) + 1); k_hi = -(floor(asin(min(-x / R, 1)) / dtheta) - 1)
    clamp both to [-half_n, half_n]
    best = NONE; best_k = k_lo
    prev = mapped(k_lo)                       // (r sin phi, h + 2 r sin^2(phi / 2)), phi = k dtheta, r = R - h, as today
    for k in k_lo .. k_hi - 1: p = mapped(k + 1)
        if x within [min(prev.x, p.x), max(prev.x, p.x)]:
            y = prev.x == p.x ? max(prev.y, p.y) : mix(prev.y, p.y, (x - prev.x) / (p.x - prev.x))
            if y > best: best = y; best_k = k
        prev = p
    if best == NONE: best = (x >= 0 ? mapped(k_hi) : mapped(k_lo)).y   // only past the ends
    if hole_half >= 0 and |wrap(center.x + best_k - hole_cell.x + n_theta / 2, n_theta) - n_theta / 2| <= hole_half and |row - hole_cell.y| <= hole_half:
        best = uintBitsToFloat(0x7fc00000u)   // NaN: a hole
    imageStore(o_patch, (i, j), best)
    ```
    Dispatch `ceil(n / 8)` groups per axis. The comment block at the top explains the `k` bound (decision 10).
  - `ColliderPatch` additions: `const EDIT_SAMPLES := 65`, `const _EDIT_MID := 32`, `const HOLE_HALF := 22`, `const ZONE_MARGIN := 4`; `var zone: Vector2i`, `var has_zone := false` (set by Task 7's `on_edit`; a hole is baked into the big patch whenever `has_zone`); a second child `CollisionShape3D` named `EditShape` with a `65 × 65` `HeightMapShape3D`, `disabled = true` until its first bake lands; `var edit_frame: Transform3D` and `func set_edit_frame(theta: float, z: float, R: float) -> void` (the tangent frame at `(theta, z)`, same basis rule as `set_frame`; sets `EditShape.transform = transform.affine_inverse() * edit_frame`); `set_frame` re-places `EditShape` the same way so the edit shape stays put when the body moves. `func _bake(window: TerrainWindow, cell: Vector2i, n: int, staging: RID, set: RID, stamp: String, hole: bool, landed: Callable) -> void` is the generic dispatch (push constants above with `hole_cell = zone` and `hole_half = HOLE_HALF` when `hole`, else `-1`; `half_n = half_n((n − 1) / 2, window.params)`; timestamps `<stamp>_begin/_end`; `texture_get_data_async(staging, 0, landed.bind(theta, z, R))`), and `static func half_n(mid: int, p: WorldParams) -> int` is `ceili(asin(minf((mid + 1.0) / (p.radius − p.h_sea − p.h_mtn()), 1.0)) / p.dtheta())` (the existing expression, generalised); `rebuild` calls `_bake` with `n = SAMPLES`, `stamp = "bake"`, `hole = has_zone`. `_setup_rd` creates both staging textures (`257²` and `65²`) and both uniform sets. `signal baked(kind: String, cpu_ms: float)` is emitted by each landing with the time the `map_data` assignment took (`"big"` here; `"edit"` in Task 7). `surface_point` uses `static func _bilinear(d: PackedFloat32Array, n: int, x: float, z: float) -> float` (sample coordinates, clamped as today) and, when any of the four big samples is NaN, reads the edit shape in `edit_frame` instead. `center_height` is unchanged.

- [ ] **Step 1: Write the failing test**

Append to `test_terrain_window_math.gd` before `patch.free()`:

```gdscript
	# The edit shape sits in the body's frame so that its own frame is the tangent frame at its centre, and stays
	# put when the body's frame moves.
	var a := 0.5 * PI + 0.01
	patch.set_edit_frame(a, 320.0, 3200.0)
	var edit_node: CollisionShape3D = patch.get_node("EditShape")
	var g := patch.transform * edit_node.transform
	check(g.origin.is_equal_approx(Cyl.position(a, 320.0, 0.0, 3200.0)), "edit frame origin %s" % g.origin)
	check(g.basis.y.is_equal_approx(Vector3(-sin(a), cos(a), 0)), "edit frame up toward the axis")
	check(edit_node.shape.map_width == 65 and edit_node.shape.map_depth == 65 and edit_node.disabled, "edit shape 65 x 65, off until baked")
	patch.set_frame(0.5 * PI + 0.02, 290.0, 3200.0)
	check((patch.transform * edit_node.transform).is_equal_approx(g), "edit frame kept across a big-patch move")
	# surface_point falls back to the edit shape where the big patch has a NaN hole.
	var big := PackedFloat32Array(); big.resize(257 * 257); big.fill(10.0)
	for j in range(120, 137): for i in range(120, 137): big[j * 257 + i] = NAN
	shape.map_data = big
	patch.set_edit_frame(0.5 * PI + 0.02, 290.0, 3200.0)
	var small := PackedFloat32Array(); small.resize(65 * 65); small.fill(7.0)
	edit_node.shape.map_data = small
	var inside := patch.transform.affine_inverse() * patch.surface_point(patch.transform * Vector3(0.5, 0, -1.5), 1.0)
	check(inside.is_equal_approx(Vector3(0.5, 8.0, -1.5)), "hole reads the edit shape: %s" % inside)
	var outside := patch.transform.affine_inverse() * patch.surface_point(patch.transform * Vector3(40.0, 0, 0), 1.0)
	check(is_equal_approx(outside.y, 11.0), "outside the hole reads the big patch: %s" % outside)
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd godot && godot --headless --path . --fixed-fps 60 --quit-after 7200 -s res://tests/test_terrain_window_math.gd`
Expected: `set_edit_frame` not found. Jolt builds the NaN map without an error (decision 9).

- [ ] **Step 3: Rewrite the shader and extend `ColliderPatch`**

As in Interfaces. Keep `_landed` for the big patch (now timing the assignment and emitting `baked("big", ms)`).

- [ ] **Step 4: Write the windowed check `bake_check.gd`**

`terrain/bake_check.tscn` is a `Node` with the script. It instantiates `main.tscn` (as `smoke_run.gd` does), waits for `collider_live`, then one frame, then on the render thread (sync reads are fine in a driver):

1. Reads the big staging texture (`texture_get_data(patch._staging, 0)`) and the window's `surface` texture; for rows `j = 128` and `j = 8` builds `h[k]` for `k in [-half_n, half_n]` (`ColliderPatch.half_n(128, params)`) from the window texels of cells `(center.x + k, row)` (texel `texel_origin(tile_of_cell(i, j)) + (i % 128, j % 128)`; all resident around the spawn) and compares `Cyl.bake_row(h, dtheta, R, 1.0, 257)` with the GPU row. Prints `bake vs reference: row 128 max err X m, row 8 max err Y m`. Expected: both under 2e-3. Then `terrain.teleport` to the centre of the first macro cell with `cliff` 255 (scan `maps.cliff` as `debug_window.gd --cliff` does), await `patch.live`, and compare row 128 there the same way, so the shader's fold-back path is sampled: `cliff row 128 max err Z m`, under 2e-3 as well.
2. Prints the `bake` GPU time from the overlay's `timed` signal (Vulkan). Expected: under 0.2 ms (budget 1 ms).
3. Sets `patch.zone = patch's centre cell + Vector2i(60, 0)`, `patch.has_zone = true`, calls `patch.rebuild(...)` at the same centre, waits for `live`, counts NaN in `map_data`. Prints `hole samples N, expected E` with `E = 45 × 45 × (R − h_c) × dtheta` (`h_c` the surface height at the zone: the hole is 45 cells square in cell space and a cell is `(R − h) · dtheta` m wide in `x`, so about 2160 at the spawn's 420 m). Expected: `N` within 10 % of `E`.
4. Places a `box.tscn` instance (as `Emitter.spawn` does: `station`, `setup(1.0, 8.0, 0.0)`, child of the station) 5 m over the surface at the zone's `(theta, z)`, waits 4 s, prints its height above the macro surface. Expected: under −20 m: `NaN is a hole: ok`; if the box rests, print `NaN is NOT a hole` and exit 1.
5. Quits 0 on all expected, else 1.

Run: `cd godot && godot --rendering-driver vulkan --path . res://terrain/bake_check.tscn`
Expected: the four lines above, `PASS`, exit 0.

Then `cd godot && godot --path .`: walk and run 200 m in two directions, drop boxes on a slope and against a cliff: no fall-through, boxes rest on the drawn surface within a few cm, as in slice 1.

- [ ] **Step 5: Run the suite**

Run: `cd godot && sh tests/run.sh`
Expected: all `PASS`.

- [ ] **Step 6: Commit**

```bash
git add godot/terrain/shaders/collider_bake.glsl godot/terrain/collider_patch.gd godot/terrain/bake_check.gd godot/terrain/bake_check.tscn godot/tests/test_terrain_window_math.gd
git commit -m "Terrain: collider bake at one invocation per sample, parametric size, NaN hole; edit shape frame"
```

---

### Task 5: Edit layer (R1): stamp, pack, apply, mask, `Terrain.edit`, debug keys

**Files:**
- Create: `godot/terrain/edit_layer.gd`, `godot/terrain/shaders/edit.glsl`, `godot/terrain/debug_edit.gd`, `godot/terrain/edit_run.gd`, `godot/terrain/edit_run.tscn`
- Modify: `godot/terrain/terrain_window.gd` (`FIELDS`, `edits`, `is_resident`, `_dispatch`), `godot/terrain/shaders/detail.glsl` (binding 8), `godot/terrain/terrain.gd` (`edit`, create the layer), `godot/main.tscn` (DebugEdit node), `godot/terrain/far_terrain.gd` (header line), `godot/terrain/timing_overlay.gd` (`_gpu` keys)
- Test: `godot/tests/test_edit_layer.gd`

**Interfaces:**
- Consumes: `TerrainWindow.texture_rid`, `texel_origin`, `slot_of`, `wanted_origin`, `tiles_around`, `slots`, `tiles_along`, `params.n_theta()`, `n_z()`, `cell_of`.
- Produces:
  - `TerrainWindow.FIELDS` gains `"edit_mask"` (index 8, `R8_UNORM`, created by the existing `i < 5` rule); `detail.glsl` binds it as `layout(set = 1, binding = 8, r8) uniform restrict writeonly image2D o_mask;` and stores 0 for every cell it writes. `var edits: EditLayer` (null on the far window). `func is_resident(tile: Vector2i) -> bool` (`_resident.get(slot_of(tile)) == tile`). `_dispatch` ends with `if edits != null: edits.apply_entering(self, tiles)`.
  - `class_name EditLayer extends RefCounted`:
    - `const CELL_BYTES := 24`, `const BLOB_SIZE := TerrainWindow.TILE * TerrainWindow.TILE * CELL_BYTES`, `const DOWN_SLOTS := 4`.
    - `var blobs := {}`: wrapped tile `Vector2i` → `PackedByteArray` of `BLOB_SIZE` (decision 1 layout).
    - `func setup(window: TerrainWindow) -> void`: on the render thread compiles `edit.glsl`, creates `_up` (`storage_buffer_create(BLOB_SIZE)`) and `_down` (`BLOB_SIZE * DOWN_SLOTS`) and one uniform set: binding 0 `_up`, binding 1 `_down` (`UNIFORM_TYPE_STORAGE_BUFFER`), bindings 2..10 the nine window images in `FIELDS` order. Returns after `push_error` if the window has no textures.
    - `func stamp(window: TerrainWindow, cell: Vector2i, radius: int, dh: float) -> void`: on the render thread, timestamps `edit_begin/_end` around one compute list: the stamp dispatch (`mode 0`, `ceil((2·radius + 1) / 8)` groups per axis), a barrier, then one pack dispatch (`mode 1`, 16 × 16 groups) per tile of `stamp_tiles(window, cell, radius)` into slot `k`; after the list, `buffer_get_data_async(_down, _packed.bind(tile), k * BLOB_SIZE, BLOB_SIZE)` per tile; `_packed(data, tile)` stores `blobs[tile] = data` when `data.size() == BLOB_SIZE`.
    - `func apply_entering(window: TerrainWindow, tiles: Array[Vector2i]) -> void` (render thread): timestamps `apply_begin/_end` around, for each tile with a blob, `buffer_update(_up, 0, BLOB_SIZE, blobs[tile])` then its own compute list with one apply dispatch (`mode 2`, 16 × 16 groups).
    - `static func stamp_tiles(window: TerrainWindow, cell: Vector2i, radius: int) -> Array[Vector2i]`: the distinct tiles of the box `[cell.x − radius, cell.x + radius] × [max(cell.y − radius, 0), min(cell.y + radius, n_z − 1)]`, θ wrapped with `wrap_tile`; 1 to 4 tiles for `radius < 128`.
    - `static func cell_offset(i: int, j: int) -> int` (`(j * 128 + i) * CELL_BYTES`) and `static func decode(blob: PackedByteArray, i: int, j: int) -> Dictionary` with keys `surface, bedrock_top, clay_bottom, clay_top, water_surface, material, compaction, saturation, mask` (test helper, uses `decode_float` / `decode_u32`).
  - `edit.glsl`: `local_size 8 × 8 × 1`; set 0 as above (`buffer Up { uint up[]; }` readonly, `buffer Down { uint down[]; }` writeonly, nine `image2D`s read-write with their formats); push constants (std430, 64 bytes): `ivec2 cell`, `ivec2 first_tile`, `ivec2 tile`, `int n_theta`, `int tiles_around`, `int slots`, `int mode`, `int radius`, `int slot`, `float dh`, `float h_max`. Texel of world cell `c` (θ wrapped) is `((c / 128) % slots) * 128 + c % 128` after the residency test `collider_bake.glsl` uses. Modes:
    - 0 stamp: `c = cell + gid − radius`; skip outside the box, outside the disc (`length(vec2(c − cell)) > radius`), or not resident; `lift = dh · (1 − (d / radius)²)`; `s' = clamp(s + lift, 0, h_max)`; if `dh < 0`: `bt = min(bt, s')`, `cb = min(cb, s')`, `ct = min(ct, s')`; `material = bt ≥ s' − 0.01 ? 2 : (ct ≥ s' − 0.01 ? 1 : 0)` (never 3); water, compaction, saturation unchanged; mask 1.
    - 1 pack: local `(i, j) = gid`; read the nine texels of `tile`; write six uints at `slot · 128 · 128 · 6 + (j · 128 + i) · 6`: `floatBitsToUint` of the five heights, then `material | compaction << 8 | saturation << 16 | mask << 24` with each byte `uint(round(unorm · 255))`.
    - 2 apply: read the six uints at `(j · 128 + i) · 6` of `up`; return if `(w5 >> 24) == 0`; else store the five heights, the three bytes `/ 255`, and mask 1 into `tile`'s texels.
  - `Terrain`: creates `window.edits = EditLayer.new()` and calls `window.edits.setup(window)` right after `window.setup`. `func edit(theta: float, z: float, radius: float, dh: float) -> bool`: false before `_live`; `cell = params.cell_of(theta, z)`, `r = ceili(radius)`; false unless every tile of `EditLayer.stamp_tiles(window, cell, r)` `is_resident`; else `window.edits.stamp(window, cell, r, dh)` and true. Doc comment per decision 7 (radius in cells, a cell is 0.77 to 1.22 m across).
  - `class_name DebugEdit extends Node` (`debug_edit.gd`), `@export var terrain: Terrain`, `const RADIUS := 5.0`, `const STEP := 0.25`, `const RATE := 10.0`: in `_process`, while `KEY_BRACKETLEFT` or `KEY_BRACKETRIGHT` is physically pressed, at most `RATE` times per second, casts a `PhysicsRayQueryParameters3D` ray from the current camera through the screen centre (`project_ray_origin` / `project_ray_normal`, 2 km long, `exclude` the viewer's RID) and, on a hit, calls `terrain.edit(theta, z, RADIUS, -STEP or +STEP)` at the hit point's station-local `(Cyl.theta_of(p), p.z)`; no hit, no call. Added to `main.tscn` as `DebugEdit` next to `ClickTeleport` with `terrain = ../Station/Terrain`. Header: exists to exercise the edit pipeline; the real tools are a later slice.
  - `far_terrain.gd` header gains decision 12's sentence. `timing_overlay.gd` `_gpu` gains `"edit"` and `"apply"`.

- [ ] **Step 1: Write the failing test**

`godot/tests/test_edit_layer.gd`:

```gdscript
extends SceneTree

var failed := false

func check(ok: bool, msg: String) -> void:
	if not ok:
		push_error(msg)
		failed = true

func _initialize() -> void:
	var p := WorldParams.new()
	var w := TerrainWindow.new()
	w.configure(p, 512, 1.0)
	check(EditLayer.BLOB_SIZE == 128 * 128 * 24 and EditLayer.cell_offset(3, 2) == (2 * 128 + 3) * 24, "blob layout")
	# A disc inside one tile; one straddling the seam at theta = 0; one at the station's first rows; one over four tiles.
	var one := EditLayer.stamp_tiles(w, Vector2i(200, 300), 5)
	check(one.size() == 1 and one[0] == Vector2i(1, 2), "one tile %s" % [one])
	var seam := EditLayer.stamp_tiles(w, Vector2i(2, 500), 5)
	check(seam.size() == 2 and seam.has(Vector2i(127, 3)) and seam.has(Vector2i(0, 3)), "seam %s" % [seam])
	var end := EditLayer.stamp_tiles(w, Vector2i(16380, 1), 5)
	check(end.size() == 2 and end.has(Vector2i(127, 0)) and end.has(Vector2i(0, 0)), "first rows clamp, theta wraps %s" % [end])
	for t in EditLayer.stamp_tiles(w, Vector2i(10, p.n_z() - 2), 5): check(t.y == w.tiles_along - 1, "last rows clamp")
	var four := EditLayer.stamp_tiles(w, Vector2i(127, 127), 3)
	check(four.size() == 4 and four.has(Vector2i(0, 0)) and four.has(Vector2i(1, 1)), "four tiles %s" % [four])
	# decode reads back what encode_* wrote in the blob layout.
	var blob := PackedByteArray(); blob.resize(EditLayer.BLOB_SIZE)
	var o := EditLayer.cell_offset(5, 7)
	blob.encode_float(o, 412.5); blob.encode_float(o + 4, 400.0); blob.encode_float(o + 16, 0.0)
	blob.encode_u32(o + 20, 2 | (255 << 24))
	var d := EditLayer.decode(blob, 5, 7)
	check(d.surface == 412.5 and d.bedrock_top == 400.0 and d.material == 2 and d.mask == 255, "decode %s" % d)
	check(EditLayer.decode(blob, 6, 7).mask == 0, "untouched cell")
	if failed: quit(1)
	else: print("PASS"); quit(0)
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd godot && godot --headless --path . --fixed-fps 60 --quit-after 7200 -s res://tests/test_edit_layer.gd`
Expected: `EditLayer` not found.

- [ ] **Step 3: Implement the layer, the shader, the window and terrain changes, the debug keys**

As in Interfaces. Pack push constants with `encode_*` into a 64-byte `PackedByteArray` as `terrain_window.gd` does. The stamp and the pack share one list with `compute_list_add_barrier` between them; apply lists are separate (decision 3).

- [ ] **Step 4: Run the headless test, then write and run the windowed driver**

Run: `cd godot && sh tests/run.sh`
Expected: all `PASS`.

`terrain/edit_run.tscn`: a `Node` with `edit_run.gd`, which instantiates `main.tscn`, sets `persist_edits = false` on its `Terrain` (the export exists from Task 6; until then skip the line), feeds keys through `Input.parse_input_event` like `smoke_run.gd`, and in this task does:

1. Waits for `collider_live`, then `terrain.teleport(0.0, maps.spawn.y)` so the dig straddles the seam, waits for `patch.live` and 1 s.
2. Phase `dig`: calls `terrain.edit(0.0, spawn.y, 5.0, -0.25)` 30 times at 10 per second (3 s); phase `raise`: 20 calls with `+0.25` (2 s): net 2.5 m down at the centre. The driver calls `edit` directly rather than pressing `[` and `]`, because `DebugEdit` aims where the camera looks; the keys are checked by hand below. Waits 3 frames.
3. Reads the `surface` and `edit_mask` textures (sync `texture_get_data`) and records `h_dug` at the centre cell `c = params.cell_of(0.0, spawn.y)` and `h_west` at `c − (3, 0)` (column 16380, tile 127), and their mask texels. Expected printed: `h_dug` about 2.5 m under the original (`height_at` is only macro; print both), mask 1 at both.
4. `terrain.teleport(600 / R, spawn.y)`, waits for `live` and 1 s; checks `not window.is_resident(Vector2i(0, c.y / 128))` and the same for tile 127: `left the window: ok`, else fails.
5. `terrain.teleport(0.0, spawn.y)`, waits for `live` and 1 s; reads the two texels again: `survived the scroll: ok` when both heights are bitwise equal to the recorded ones and both masks are 1, else fails with the values.
6. Saves `get_viewport().get_texture().get_image()` to `user://debug/edit_pit.png`, prints the `edit` and `apply` GPU times seen (median, max), `PASS` or `FAIL`, exits 0 or 1.

Run: `cd godot && godot --rendering-driver vulkan --path . res://terrain/edit_run.tscn`
Expected: `left the window: ok`, `survived the scroll: ok`, `PASS`; `edit` under 0.3 ms, `apply` under 0.3 ms per tile; no `ERROR` lines. At this task the player floats over the pit (the collider follows in Task 7): expected.

Manual: `godot --path .`, look at the ground a few metres ahead and hold `[` for two seconds, walk around the pit: it is drawn where you looked, its walls are rock where the dig cut below bedrock (face colour never appears inside it); hold `]` to raise a mound of dirt. Quit.

- [ ] **Step 5: Commit**

```bash
git add godot/terrain/edit_layer.gd godot/terrain/shaders/edit.glsl godot/terrain/debug_edit.gd godot/terrain/edit_run.gd godot/terrain/edit_run.tscn godot/terrain/terrain_window.gd godot/terrain/shaders/detail.glsl godot/terrain/terrain.gd godot/main.tscn godot/terrain/far_terrain.gd godot/terrain/timing_overlay.gd godot/tests/test_edit_layer.gd
git commit -m "Terrain: edit layer, absolute per-cell overrides stamped, packed and re-applied on the GPU; debug dig keys"
```

---

### Task 6: Persist edits in the world files

**Files:**
- Modify: `godot/terrain/world_io.gd`, `godot/terrain/terrain.gd`
- Test: `godot/tests/test_edit_layer.gd`

**Interfaces:**
- Consumes: `EditLayer.BLOB_SIZE`, `blobs`.
- Produces:
  - `static func WorldIO.save_edits(name: String, blobs: Dictionary) -> Error`: writes `tiles/<ti>_<tj>.edit` per tile (decision 6 format, `FileAccess.COMPRESSION_ZSTD`), creating the directory.
  - `static func WorldIO.load_edits(name: String) -> Dictionary`: every `*.edit` under `tiles/` whose header is version 1 with `raw_size == EditLayer.BLOB_SIZE` and whose decompressed size matches; others are skipped with `push_warning` naming the file.
  - `Terrain`: `@export var persist_edits := true`, `const SAVE_INTERVAL := 30.0`; `_ready` sets `window.edits.blobs = WorldIO.load_edits(world_name)` before the first `_move_window` and prints `Loaded N edited tiles` when `N > 0`. `EditLayer._packed` adds its tile to `unsaved` (a Dictionary used as a set); every `SAVE_INTERVAL` s of `_process`, and in `_exit_tree`, `Terrain` saves the unsaved blobs when `persist_edits` (`WorldIO.save_edits(world_name, that subset)`: landed blobs only, so no stall) and clears the set, reporting a non-OK error with `push_error`. A crash loses at most 30 s of digging.

- [ ] **Step 1: Write the failing test**

Append to `test_edit_layer.gd` before `if failed:` (reuses `blob` from the decode check):

```gdscript
	# Edits round-trip through the world files, one zstd file per tile; a corrupt file is skipped.
	check(WorldIO.save_edits("test_world", {Vector2i(5, 7): blob, Vector2i(127, 3): blob}) == OK, "save edits")
	var loaded := WorldIO.load_edits("test_world")
	check(loaded.size() == 2 and loaded[Vector2i(127, 3)] == blob and loaded[Vector2i(5, 7)].size() == EditLayer.BLOB_SIZE, "load edits")
	var bad := FileAccess.open("user://worlds/test_world/tiles/9_9.edit", FileAccess.WRITE)
	bad.store_32(1); bad.store_32(12); bad.store_buffer(PackedByteArray([1, 2, 3])); bad.close()
	check(WorldIO.load_edits("test_world").size() == 2, "corrupt tile skipped")
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://worlds/test_world/tiles/9_9.edit"))
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd godot && godot --headless --path . --fixed-fps 60 --quit-after 7200 -s res://tests/test_edit_layer.gd`
Expected: `save_edits` not found.

- [ ] **Step 3: Implement `save_edits`, `load_edits`, the load and save in `Terrain`**

As in Interfaces. Add `_terrain.persist_edits = false` to `edit_run.gd` right after instantiating `main.tscn`.

- [ ] **Step 4: Run the suite, then the windowed restart check**

Run: `cd godot && sh tests/run.sh`
Expected: all `PASS` (the suite's `test_world` directory now also holds two `.edit` files; harmless).

Windowed: `cd godot && godot --path .`; look at the ground ahead and hold `[` for 2 s at the spawn; wait 31 s: the file `tiles/<ti>_<tj>.edit` exists under the world (the autosave); quit with the window's close button. Run `godot --path .` again.
Expected: the console prints `Loaded 1 edited tiles` (up to 4 if the spawn disc straddles tiles) before the first frame; the pit is at the spawn, the player stands in it (on the collider, since the big bake reads the applied window). Then remove the test pit: `rm ~/Library/Application\ Support/Godot/app_userdata/Artificial\ Gravity/worlds/default/tiles/*.edit`.

- [ ] **Step 5: Commit**

```bash
git add godot/terrain/world_io.gd godot/terrain/terrain.gd godot/terrain/edit_run.gd godot/tests/test_edit_layer.gd
git commit -m "Terrain: edited tiles saved as zstd blobs in the world's tiles/ and applied at startup"
```

---

### Task 7: Collider follows edits (R3): edit shape, hole, zone

**Files:**
- Modify: `godot/terrain/collider_patch.gd`, `godot/terrain/terrain.gd` (`edit`, `_process`), `godot/terrain/timing_overlay.gd` (`"bake_edit"`), `godot/terrain/edit_run.gd`
- Test: `godot/tests/test_edit_layer.gd`

**Interfaces:**
- Consumes: Task 4's `_bake`, `EditShape`, `set_edit_frame`, `zone`, `has_zone`, `HOLE_HALF`, `ZONE_MARGIN`; Task 5's `Terrain.edit`.
- Produces:
  - `static func ColliderPatch.zone_holds(zone: Vector2i, cell: Vector2i, radius: int, n_theta: int) -> bool`: true when `|Δθ| + radius <= HOLE_HALF − ZONE_MARGIN` and `|Δz| + radius <= HOLE_HALF − ZONE_MARGIN`, `Δθ` the shorter way round (`wrapi(cell.x − zone.x, −n_theta / 2, n_theta / 2)`).
  - `func on_edit(window: TerrainWindow, cell: Vector2i, radius: int) -> void`: if `has_zone and zone_holds(zone, cell, radius, n_theta)`: `_bake_edit(window)`; else `zone = cell`, `has_zone = true`, `_bake_edit(window)` then `_rebuild_here(window)` (the big patch at its current `center` cell, with the hole), in that order of readback requests (decision 8). Bakes in flight coalesce: `_pending_edit`/`_again_edit` and `_pending`/`_again_big`. Ordering rule (decision 8): a landing (`_landed`, `_landed_edit`) never dispatches GPU work, because it runs inside the RenderingDevice readback flush (`_begin_frame` → `_stall_for_frame`), where a compute list is discarded and an async readback reads zeros (precedent: `noise_report.gd` waits a frame after `collider_live`); a landing only sets flags. A zone move while `_pending_edit` issues nothing now and sets `_again_edit`. `func issue_again(window: TerrainWindow) -> void`, called by `Terrain._process` every frame, issues one edit bake with the current zone when `_again_edit` is set and `_pending_edit` is clear (clearing the flag), and one big bake (`_rebuild_here`) when `_again_big` is set, `_pending` is clear, and no edit bake is pending or wanted (clearing the flag); an edit bake issued this way has its landing set `_again_big` when the zone moved, so the big bake with the new hole is issued by the following `_process`, at least one frame after the edit bake for the same zone, and a hole never lands before the shape under it. A landing with the plain `_again_*` flags set (edits arriving while a bake was in flight) is re-baked once, the same way, by the next `_process`. `_bake_edit` uses`_bake_edit` uses `n = EDIT_SAMPLES`, the 65² staging, stamp `"bake_edit"`, centred on `zone`; `_landed_edit` assigns `EditShape.shape.map_data` (timed, `baked("edit", ms)`), sets `EditShape.disabled = false`, calls `set_edit_frame(theta, z, R)`.
  - `Terrain.edit` calls `patch.on_edit(window, cell, r)` after the stamp's compute list has ended (the render graph then orders the bake's reads after the stamp's writes; a bake issued inside the stamp's list would read stale texels).
  - `timing_overlay.gd` `_gpu` gains `"bake_edit"`. `center_height` is used only by `_on_first_live`, before any zone exists; its comment says so, since sample `_MID` is NaN once the zone is within `HOLE_HALF` cells of the centre.

- [ ] **Step 1: Write the failing test**

Append to `test_edit_layer.gd` before `if failed:`:

```gdscript
	# The edit zone holds a disc that stays HOLE_HALF - ZONE_MARGIN cells from its centre, theta the short way round.
	check(ColliderPatch.zone_holds(Vector2i(10, 10), Vector2i(10, 10), 5, 16384), "centre")
	check(ColliderPatch.zone_holds(Vector2i(10, 10), Vector2i(23, 10), 5, 16384), "13 + 5 = 18 holds")
	check(not ColliderPatch.zone_holds(Vector2i(10, 10), Vector2i(24, 10), 5, 16384), "14 + 5 = 19 moves")
	check(not ColliderPatch.zone_holds(Vector2i(10, 10), Vector2i(10, 29), 5, 16384), "along z too")
	check(ColliderPatch.zone_holds(Vector2i(2, 10), Vector2i(16382, 10), 5, 16384), "across the seam the delta is 4")
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd godot && godot --headless --path . --fixed-fps 60 --quit-after 7200 -s res://tests/test_edit_layer.gd`
Expected: `zone_holds` not found.

- [ ] **Step 3: Implement the zone, the edit bake and the hook**

As in Interfaces. `rebuild` (viewer moved 64 m) keeps passing the hole while `has_zone`; it never touches the edit shape.

- [ ] **Step 4: Run the suite, extend and run the windowed driver**

Run: `cd godot && sh tests/run.sh`
Expected: all `PASS`.

`edit_run.gd` additions (between its steps 2 and 3, and after step 5):

- Before the dig, places a `box.tscn` (1 m, as in `bake_check`) 3 m over the surface 2 m spinward of the player; connects `terrain.body_held` (count) and `patch.baked` (CPU ms per kind).
- Every frame of `dig` and `raise`, records the player's and the box's clearance to the collider: `(patch.surface_point(p, 0) − p)` along the patch's up, negative when under it. The player's position is sampled from its origin (1 m over its feet).
- After `raise`: asserts `holds == 0`; the player descended at least 2 m between the start and the end of `dig` and ended within `[0.5, 2.5]` m over the edit shape; the box ended within `[0, 1.5]` m over it; neither was ever more than 1 m under the collider: prints `collider followed the edit: ok` or the numbers.
- After step 5 (back at the pit): asserts `patch.surface_point` at the pit centre is within 0.3 m of `h_dug` (the hole plus the edit shape reproduce the pit after the teleport): `collider has the pit: ok`.
- After that: pushes the box from the big patch into the pit (places it 10 m from the pit centre on the big patch and gives it 3 m/s toward the centre, waits 4 s): it ends inside the edit shape's extent within 5 cm of the surface and was never more than 5 cm under the collider on the way: `rim crossed: ok` (pins decision 8's one-body, two-shape contact).
- New phase `trench`, after that: holds `W` for 6 s while calling `terrain.edit` at the player's own cell 10 times per second (the ground it walks on; the zone moves about every 1.2 s), then releases `W` and waits 1 s. Asserts `holds == 0` still and the player never under the collider by more than 1 m: `zone moves while walking: ok`. Records the zone with every `baked` landing and asserts each `baked("big", ..)` of the trench came after a `baked("edit", ..)` for the same zone, at least one frame later (the frame counter is recorded with each landing): `hole never unbacked: ok` (pins the ordering rule and that no landing dispatches). Prints the count of `baked("big", ..)` during the trench (expected about 5) and the frame intervals over 16 ms in that phase (expected 0 on this machine).

Run: `cd godot && godot --rendering-driver vulkan --path . res://terrain/edit_run.tscn`
Expected: all `ok` lines, `PASS`, exit 0, no `ERROR`; `bake_edit` under 0.1 ms, `bake` under 0.2 ms; `baked edit` CPU under 0.5 ms, `baked big` about 2.8 ms.

Manual: `godot --path .`; look down at your feet and hold `[` standing still: the player sinks with the ground, a box beside it sinks too; hold `]`: both rise; walk while holding `[` with the camera tilted down: a trench forms where you look, no freeze, no fall. Drop a box into the pit: it rests on the pit floor.

- [ ] **Step 5: Commit**

```bash
git add godot/terrain/collider_patch.gd godot/terrain/terrain.gd godot/terrain/timing_overlay.gd godot/terrain/edit_run.gd godot/tests/test_edit_layer.gd
git commit -m "Terrain: a 65 x 65 edit heightfield rebakes per edit under a NaN hole in the big patch"
```

---

### Task 8: Hold-rule tests (R5) and held rigid bodies

**Files:**
- Modify: `godot/terrain/terrain.gd` (`_hold`, the ground group), `godot/emitter.gd` (group membership), `godot/terrain/smoke_run.gd` (the `--blackout` route)
- Create: `godot/tests/test_hold_rule.gd`

**Interfaces:**
- Consumes: `ColliderPatch.covers`, `Terrain._hold_body`, `body_held`.
- Produces:
  - `const Terrain.GROUND_GROUP := "terrain_ground"`. `func _hold(body: Node3D, hold: bool) -> bool`: the hold state lives in the body's meta `terrain_held` (default false); returns false and does nothing when the state already matches, or when asked to hold a body something else already disabled (`process_mode == PROCESS_MODE_DISABLED`); otherwise sets the meta, sets `process_mode` to `DISABLED` or `INHERIT`, returns true. `_hold_body(hold)` becomes `if _hold(_body, hold): body_held.emit(hold)`. `_process` also runs `_hold(b, not patch.covers(station.to_local(b.global_position)))` for every `b` in `get_tree().get_nodes_in_group(GROUND_GROUP)`.
  - `Emitter.spawn` adds each box to `Terrain.GROUND_GROUP`.

- [ ] **Step 1: Write the failing test**

`godot/tests/test_hold_rule.gd`:

```gdscript
extends SceneTree

var failed := false
var held_log: Array[bool] = []

func check(ok: bool, msg: String) -> void:
	if not ok:
		push_error(msg)
		failed = true

func _initialize() -> void:
	# A Terrain outside the tree: _ready never runs, so no world, window or RenderingDevice is needed.
	var terrain := Terrain.new()
	var body := Node3D.new()
	terrain._body = body
	terrain.body_held.connect(func(h: bool) -> void: held_log.append(h))
	terrain._hold_body(true)
	check(body.process_mode == Node.PROCESS_MODE_DISABLED and held_log == [true], "held once")
	terrain._hold_body(true)
	check(held_log == [true], "holding again is silent")
	terrain._hold_body(false)
	check(body.process_mode == Node.PROCESS_MODE_INHERIT and held_log == [true, false], "released")
	# A body something else disabled (the fly camera's freeze) is neither taken nor released by Terrain.
	body.process_mode = Node.PROCESS_MODE_DISABLED
	terrain._hold_body(true)
	terrain._hold_body(false)
	check(body.process_mode == Node.PROCESS_MODE_DISABLED and held_log == [true, false], "another holder's hold is respected")
	# Any body: the same rule, state kept on the body.
	var box := RigidBody3D.new()
	check(terrain._hold(box, true) and box.process_mode == Node.PROCESS_MODE_DISABLED and box.get_meta("terrain_held"), "box held")
	check(not terrain._hold(box, true), "box held once")
	check(terrain._hold(box, false) and box.process_mode == Node.PROCESS_MODE_INHERIT, "box released")
	# covers() is a pure function of the frame: a pending bake changes nothing until it lands.
	var patch := ColliderPatch.new()
	patch.set_frame(1.0, 0.0, 3200.0)
	patch._pending = true
	check(patch.covers(patch.transform * Vector3(100, 0, 100)) and not patch.covers(patch.transform * Vector3(130, 0, 0)), "covers ignores a pending bake")
	patch.free(); box.free(); body.free(); terrain.free()
	if failed: quit(1)
	else: print("PASS"); quit(0)
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd godot && godot --headless --path . --fixed-fps 60 --quit-after 7200 -s res://tests/test_hold_rule.gd`
Expected: `_hold` not found (the first checks pass against today's `_hold_body`).

- [ ] **Step 3: Implement `_hold`, the group loop and the emitter line**

As in Interfaces.

- [ ] **Step 4: Run the suite, then the windowed check**

Run: `cd godot && sh tests/run.sh`
Expected: all `PASS`.

`smoke_run.gd` gains a `-- --blackout` route that replaces its legs: after `collider_live` and the 2 s hold it records the player's global position, sets `RenderingServer.render_loop_enabled = false` and holds `W` for 10 s of process time (frames keep running; no bake can land, so the patch cannot follow); records every `body_held` with its time and the player's global position at the first `true`; then `render_loop_enabled = true`, releases `W`, waits up to 3 s for `body_held(false)`. Asserts: `body_held(true)` fired (the player ran past the patch's 124 m cover at about 8.5 s); between that moment and the release the player's global position did not change (distance under 1e-3: frozen, not falling); `body_held(false)` arrived within 3 s of the render loop resuming; the player's height above the macro surface at the end is over −2 m (standing). Prints the times, its usual summary (`held: 1 times`) and `BLACKOUT PASS`/`FAIL`, exits 0/1. The driver already sets `persist_edits = false` (Task 6).

Run: `cd godot && godot --path . res://terrain/smoke.tscn -- --blackout`
Expected: `held at t=8.x s`, `frozen: ok`, `released at t=1x.x s`, `BLACKOUT PASS`. The window stays black for 10 s by design.

Manual: `godot --path .`; Spawn three boxes; press F; fly 300 m away and look back: the boxes hang where they were (no longer fall to the hull); fly back: they resume and rest.

- [ ] **Step 5: Commit**

```bash
git add godot/terrain/terrain.gd godot/emitter.gd godot/tests/test_hold_rule.gd godot/terrain/smoke_run.gd
git commit -m "Terrain: hold-rule tests headless and with the render loop stopped; rigid bodies held off the patch"
```

---

### Task 9: Measurement run, budgets and notes

**Files:**
- Modify: `godot/terrain/edit_run.gd`, `docs/terrain-research.md` (after the slice 1 measurements), `docs/superpowers/plans/2026-10-27-terrain-slice-1-followups.md` (mark the items this plan closed)
- Create: `docs/superpowers/plans/2026-10-27-terrain-edits-followups.md`

**Interfaces:**
- Consumes: the overlay's `timed` signal, `ColliderPatch.baked`, `viewport_get_measured_render_time_gpu`, `TerrainWindow.tiles_generated`.
- Produces: `edit_run.gd` prints a summary after its checks: machine and driver; per pass (`edit`, `apply`, `bake_edit`, `bake`, `detail` per tile) count, median, p90, max in ms and the count over budget (`edit` 0.5, `apply` 0.5, `bake_edit` 1, `bake` 1, `detail` 2 per tile); `map_data` CPU ms per kind (median, max); per phase (`dig`, `raise`, `trench`) frame interval mean, p99, max and the count over 16 ms, and GPU frame mean and p99 (budget 6); holds, falls, survived. Timing is reported, not asserted; behaviour is asserted as before.

- [ ] **Step 1: Add the summary to `edit_run.gd`**

Reuse `smoke_run.gd`'s `_stat`, `_pct`, `_mean` shapes (copy; the drivers are independent). Record `detail` lists with the tile counts from `tiles_generated` for the per-tile figure.

- [ ] **Step 2: Run under both drivers**

Run: `cd godot && godot --rendering-driver vulkan --path . res://terrain/edit_run.tscn` then `godot --path . res://terrain/edit_run.tscn`.
Expected: `PASS` on both; on Vulkan every pass within budget with `bake_edit` under 0.1 ms and `bake` under 0.2 ms, GPU frame mean under 6 ms; on Metal GPU figures `n/a`, CPU figures and behaviour the same. Also run `bake_check` and `smoke.tscn -- --blackout` once more and `sh tests/run.sh`.

- [ ] **Step 3: Record the numbers and the follow-ups**

In `docs/terrain-research.md`, after the slice 1 measurement table, add "Edit slice measurements, <date>" with the Vulkan table (passes, map_data CPU, frames per phase) and one line on the Metal run. In the slice 1 follow-ups doc, add one line under each item this plan closed (R1, R3, R4 documented, R5, R6, R7, topsoil, occupancy) pointing to this plan; keep the list itself as the record of what slice 1 left open. New `2026-10-27-terrain-edits-followups.md`: edits in the far window (decision 12); per-body collider patches (decision 17's design); R2 (noise octaves) untouched; Jolt's per-block 8-bit height quantisation as a suspect for the 18 cm mismatch at altitude; window memory at 23 bytes per cell against the spec's `R16` budget; blobs uncompressed in RAM; a stamped tile evicted and re-entered within the 2-frame readback (decision 4's limit); the stamp radius in cells, not metres, across; any measured budget miss.

- [ ] **Step 4: Commit**

```bash
git add godot/terrain/edit_run.gd docs/terrain-research.md docs/superpowers/plans/2026-10-27-terrain-slice-1-followups.md docs/superpowers/plans/2026-10-27-terrain-edits-followups.md
git commit -m "Terrain: edit run measurements, budgets and follow-ups for the next slice"
```
