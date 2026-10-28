# Terrain Slice 3 (Auger, Loose Dirt, Tamping, Spilled Water) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A placed auger bores a 2 m hole to 10 m and piles its spoil beside itself as loose dirt that slumps to repose, is pushed by walking and tamped back into solid ground by jumping; an auger set in water pumps a sheet that flows, pools, wets dirt within 3 m and carries loose dirt; all of it survives scrolling, teleports and a restart, and the frame cost stays flat.

**Architecture:** Two new window fields, `loose` and `water_depth`, ride the slice 2 edit layer (blob version 2, 32 bytes per cell). The edit shader gains five stamp modes (bore, deposit, push, tamp, spill) that conserve volume on the cylinder's true cell areas, and a bore counter read back asynchronously drives the deposits. A new simulation pass (`terrain_sim.gd`, `sim.glsl`: a flux dispatch then an apply dispatch, one list per fixed 60 Hz step) runs only over active tiles, which the GPU flags per slot into a small stats buffer the CPU reads back every frame; a tile quiet for a second is packed into its blob and dropped. The auger is a scene with a cylinder and a static body driven by a `Tools` node that also turns the player's new `stepped` and `landed` signals into push and tamp stamps; the collider follows through the existing `on_edit`, throttled in `Terrain`.

**Tech Stack:** Godot 4.7.2 standard build, Forward+, Jolt, GDScript, GLSL compute on the main `RenderingDevice` (storage buffers, storage-buffer atomics, `buffer_clear`, `buffer_get_data_async`), `HeightMapShape3D`, zstd via `PackedByteArray.compress`.

**Spec:** [docs/superpowers/specs/2026-10-28-terrain-slice-3-design.md](../specs/2026-10-28-terrain-slice-3-design.md), approved. Its "parts the user decided" and "my calls" sections are binding; every "left to the builder" item is decided in the Decisions section below, each with the alternative and the reason. It builds on [2026-10-27-terrain-edits-C.md](2026-10-27-terrain-edits-C.md) (decisions 1 to 8, 11) and its [follow-ups](2026-10-27-terrain-edits-followups.md); the research is [docs/terrain-research.md](../../terrain-research.md) 6.1 to 6.4 and 6.8.

## Global Constraints

From the spec's Constraints section, verbatim:

- Godot 4.7.2 standard build, GDScript + GLSL compute on the main RenderingDevice, Jolt; no GDExtension.
- The slice 1 conventions and datum: 1 m cells, `Δθ = 2π / 16384`, heights radial from the hull, the 512 window of 128-cell tiles, station-local (θ, z) in all terrain code, everything under `Station`.
- The slice 2 contracts: window fields are `R32_SFLOAT` metres or `R8_UNORM` bytes; edits are absolute per-cell overrides packed into per-tile blobs by the GPU and re-applied when a tile enters; nothing dispatches GPU work or does file I/O from inside a readback callback; `buffer_update` outside open compute lists; async readbacks after `compute_list_end`; the collider's issue order (a hole never lands before the shape under it) stays as it is.
- Budgets, from the slice 1 design: detail under 2 ms per tile, collider bakes under 1 ms GPU, GPU frame mean under 6 ms at 1440p, hitch under 4 ms. New: the simulation under 0.25 ms per active tile per frame, at most 16 active tiles, the collider's edit-shape rebake while a pile is active no more than 5 times per second.
- Headless tests cannot create a RenderingDevice; GPU behaviour is proven by short windowed drivers that print numbers and quit (they open a window on the user's screen). The default world under `user://worlds/default` is never regenerated or deleted by a driver.
- Materials and their numbers come from `godot/terrain/materials.tres` (`MaterialSet`): dirt's repose angles dry 35°, damp 40°, saturated 20°; swell 1.25; wetting distance 3 m; rock's wetting distance 0. The design uses them; it does not invent new ones.

Engine facts settled on earlier branches, binding:

- `buffer_update` is refused inside an open compute list; a barrier (`compute_list_add_barrier`) is needed between dispatches in one list for a read-after-write; an async readback must be issued after `compute_list_end`.
- A `texture_get_data_async` / `buffer_get_data_async` callback runs inside the RenderingDevice readback flush between frames, where a compute list recorded is discarded and an async readback requested reads zeros: landings only set flags and store data; nothing dispatches or does file I/O from inside one.
- NaN heightfield samples are holes under Jolt. `ResourceSaver` omits default-valued exported fields. The thread model is the default single-safe one, so `call_on_render_thread` runs synchronously. GPU timestamps exist only under `--rendering-driver vulkan` (MoltenVK) on this Mac; Metal returns zeros.
- After editing a `.glsl` a windowed run needs `godot --headless --path . --import` first (the suite does it).
- The collider's issue order (`on_edit`, `issue_again`, `_issued_zone`, landings set flags only) stays as it is; new stamps call `patch.on_edit` after their list has ended, through `Terrain`. `Terrain.edit` (the debug dig) keeps its direct `on_edit` call and its own pack, so `edit_run.tscn` stays green.
- No per-cell GDScript loop on any per-frame path; blobs move whole; per-cell work is GLSL. Load-time upgrades, debug dumps and windowed drivers may loop.
- Commit after each task with the message given. Windowed drivers that instantiate `main.tscn` set `Terrain.persist_edits = false`, or point `world_name` at a copy of the default world (Task 8's `tool_run` world), never at `default`.

## Decisions

Each entry: the call, the alternative, why. The numbered "left to the builder" items of the spec are decisions 2 to 11.

1. **Fields and blob.** `TerrainWindow.FIELDS` gains `"loose"` (index 9) and `"water_depth"` (index 10), both `R32_SFLOAT`; the format rule becomes a name test (`FLOAT_FIELDS`), not `i < 5`. The blob cell grows from 24 to 32 bytes: the slice 2 layout unchanged in its first 24 bytes (five heights, then `material | compaction << 8 | saturation << 16 | mask << 24`), then `loose` at +24 and `water_depth` at +28; `BLOB_SIZE = 524,288`. `.edit` files are version 2; a version 1 file (raw 393,216) loads through `EditLayer.upgrade_v1`, which pads each cell with eight zero bytes (a load-time loop over 16,384 cells, a few ms per tile). Alternative: a second blob per tile for the new fields; rejected because the apply and pack passes would double their lists and readbacks for two numbers per cell.
2. **Flux formulas, one shader in two modes, fixed 60 Hz steps.** `sim.glsl` mode 0 (flux) writes each cell's outflows to its four edge neighbours as *volumes* (thickness × the source cell's area `(R − surface)·Δθ` m², 1 m along) into two `RGBA32F` flux textures (loose, water) and pore-water quanta into an `RGBA8` one; mode 1 (apply) adds each cell's inflows (the neighbours' flux toward it) and subtracts its own outflows, dividing by its own area, so no cell is written by two threads and the window's loose and water volumes are conserved to float rounding. Loose: toward a lower neighbour the excess `e = (H_c − H_n) − tan(repose) · w` (w the edge distance: the mean of the two cells' widths across, 1 m along; `H = surface + loose`; repose interpolated dry→damp on `saturation` 0..0.5, damp→saturated on 0.5..1) moves `slump_rate · e = e / 8` per step, the four outflows scaled down so their sum never exceeds the cell's loose. Water: toward a lower water surface (`W = H + water_depth`, or the static `water_surface` for a reservoir cell) `flow_rate · (W_c − W_n) = diff / 8`, capped by the depth held; a reservoir never sends. Loose transport: the flux pass adds `transport_share · min(out_water / transport_depth, 1) · loose` to the loose outflow in that direction (computed from the source's own state, so the apply pass needs no neighbour state). Stability: each of a cell's four outflows is at most `slump_rate` of that edge's excess and their sum is capped at the cell's loose, so a cell loses at most `4 · slump_rate = 1/2` of the largest excess around it per step and never goes negative; a tall column beside a gentle slope can overshoot one pair's difference by that bound, and the scheme settles as a damped diffusion of the excess over repose, geometrically at no less than 1/8 per step, so a pile reaches repose within a few seconds at 60 steps per second. The apply pass stores every change, however small (the `move_eps` gate is on the activity flag only), so the window's volumes are conserved to float rounding rather than leaking at the settling tail. Steps are fixed at `1/60` s with an accumulator and at most 2 per frame (the research's fixed-step rule), so the settle time does not depend on the frame rate. Alternative: separate slump and water shaders; rejected because the apply pass would then need two barriers and the transport term would need the water flux from another pass. Alternative to volumes: moving thickness; rejected because across-neighbours differ in area by `Δh / (R − h)` and the driver's sums would drift by that.
3. **Activity is flagged by the GPU per slot and bookkept on the CPU.** `EditLayer` owns a stats buffer of `slots² + 1` uints bound to both `edit.glsl` and `sim.glsl`: every stamp that changes a cell, the edit layer's apply pass for every entering cell that holds loose or water (so a pile whose tile re-enters the window mid-slump resumes, and a plain edited tile is not stepped), and every simulation apply that moves a cell by more than `move_eps = 1e-4` m (or changes its saturation) does `atomicOr(stats[slot], 1)`; a simulation apply on a tile-edge cell also sets bit 2 on the slot across that edge when that cell is resident, so material is never sent toward a tile that cannot apply it (the flux pass refuses outflow to a cell in an inactive tile; the neighbour becomes active two frames later and the flow resumes). `TerrainSim.step` reads the buffer back every frame (`buffer_get_data_async`, 68 bytes at 512) and clears it (`buffer_clear` after the request); the landing stores the flags only, and it carries the window's move generation: a landing requested before a `_move_window` is dropped, so a slot's stale flag never activates the tile that replaced an evicted one. One case needs the CPU: cells must move when an obstacle is lifted or moved although nothing touched them, so `Terrain.set_obstacle` activates the tiles the old obstacle covered (`TerrainSim.activate`). `settle` then keeps a `tile → quiet seconds` set: a flagged tile's quiet resets, others accrue, and a tile quiet for `settle_time = 1 s` is returned for packing and dropped. At most `MAX_ACTIVE = 16` tiles: beyond it the quietest is packed and dropped (frozen mid-motion until touched again; irrelevant at 512, where 16 is the window). Alternative: `touch` from every stamp on the CPU; rejected because the feet stamp 60 times a second over ground that usually holds nothing, which would keep the player's tile active and pack it every time they stop.
4. **Settle-and-pack, pack-before-evict, pack-at-exit.** A settled tile is packed once through `EditLayer.pack_tiles` (lists of up to `DOWN_SLOTS = 4` pack dispatches, readbacks after each list; the readback copies `_down` at request time, so the next list may reuse the slots). `Terrain._move_window` packs the active tiles the move will evict before calling `window.move_to`, so a teleport away mid-slump loses nothing; `Terrain._exit_tree` packs the active tiles synchronously (`pack_tiles_sync`: the same sync `buffer_get_data` the drivers use) before the save, so a quit loses only the bore tick whose counter readback is in flight. Tool stamps do not pack (`Op.pack = false`); the settle pack covers them. `Terrain.edit` keeps its immediate pack.
5. **Bore counter and deposits.** `edit.glsl` mode 3 (bore) adds each cell's cut volume, the exact annular `0.5 · Δθ · cut · (2 · (R − s) + cut)` (`s` the surface before the cut; the product form stays exact in float32 where the difference of two squares near 2800² loses 0.3 % per term), to a 2-uint counter buffer by `atomicAdd` in fixed point (1 unit = 1e-6 m³: a full bore is about 5.4e7 units, a tick's cell about 36,000); `stamp_op` clears the counter (`buffer_clear`) before the list and reads it back after, and `_counted` hands `(volume_m3, wet)` to the op's callback inside the readback flush, where the auger only adds to `_pending`. The next `Auger._process` deposits `_pending × swell` as loose into the spoil disc (or `_pending` as water when the tick was wet) and clears it; a refused deposit (tiles not resident) stays pending. Bore or pump is decided per tick on the GPU from the centre cell (`water_surface > ground + 1e-3` or `water_depth > 0.01`), reported as `counter[1]`; a dry tick that cut no volume means every cell is at `bedrock_top`: the auger stops with "rock". The wet decision is per tick, not per placement: an auger over a puddle pumps it dry in a tick or two and then bores; on a lake it pumps for as long as it stands; `Auger.mode` follows the last landed tick and `depth` counts only the ticks issued while it read bore. A landing for an auger that has been picked up is dropped (`_counted` checks the callable is still valid), since a readback can land two frames after the free. Alternative: reading the hole's cells back; rejected, the counter is 8 bytes and answers both questions.
6. **Spoil disc, side, no priming ring.** The bore disc is `bore_radius = 1` cell (5 cells, about 2 m across); the spoil disc `spoil_radius = 2` cells (13 cells) centred `spoil_offset = 7` cells from the axis along the axis-quantised direction from the player to the placement point (`Tools.push_dir`, the same quantiser the feet use), so the pile is beyond the auger from where the player stands. The offset is 7, not the spec's estimated 4, because the bore's true volume with 1 m cells is larger than the π m² circle the estimate assumed: five cells of about 1.07 m² at the spawn's height cut about 53 m³ over 10 m, 67 m³ loose, which at 35° is a cone of base radius `(67 / 0.733)^(1/3) ≈ 4.5 m` (`V = (π/3) r² · r tan 35°`); centred 7 m along the axis or 7.5 m across, its near edge lies 2.5 m from the axis, a metre clear of the shaft's rim at 1.5 cells, so a full bore's spoil does not reach the rim on its own, as the spec requires (the spec's sentence is amended with this reason). While the auger stands the obstacle mask would hold it off the shaft anyway; after pickup only dirt pushed to the rim slumps into the hole. No priming ring: the first deposit lands three frames after the first tick. Alternatives: 4 or 5 cells (the cone reaches the rim and the mask, not the geometry, keeps it out); a smaller shaft (a plus of five cells is the smallest symmetric disc).
7. **Tunables live in `ToolParams`** (`godot/terrain/tool_params.gd`, a `Resource` with exported defaults; `Terrain.tool_params` holds one, created in `_ready` when unset, no `.tres` needed; the property is not called `tools` because the scene node that uses it is `Tools`). The values: `bore_radius 1`, `bore_step 1/30 m` (10 m in 30 s at `bore_rate 10` Hz), `bore_depth 10`, `spoil_radius 2`, `spoil_offset 7` (decision 6), `pump_rate 1.0 m³/s`, `place_reach 10 m`, `pickup_distance 3 m`, `foot_radius 1` (a five-cell plus about 1.1 to 1.5 m across, one cell wider than the spec's 0.5 m, because a radius-0 push has a single source cell and the capsule itself is 1 m across), `push_share 0.05`, `push_max 0.03 m`, `push_min_speed 0.5 m/s`, `tamp_step 0.25`, `tamp_land_speed 2 m/s`, `slump_rate 0.125`, `flow_rate 0.125`, `transport_share 0.1`, `transport_depth 0.05 m`, `soak_every 6` steps, `soak_column 0.5 m`, `settle_time 1 s`, `move_eps 1e-4 m`, `collider_edit_interval 0.2 s`, `collider_zone_interval 1 s`. Material numbers (swell, repose, porosity, wetting distance) stay in `materials.tres`. Tamping ignores wetness in this slice (the spec's refinement for later).
8. **Loose look and sheet water.** `tile.gdshader` draws the ground at `surface + loose` and, where `loose > 0.02`, uses dirt's colour at 0.75 brightness with a 0.3-amplitude speckle (0.08 on ground) and roughness 1; `saturation` darkens any cell by up to 40 %. `water.gdshader` draws `max(water_surface, ground + water_depth)` where either is above the ground by more than 5 mm (the old 5 cm cut hid puddles). The P dump prints loose and sheet counts, maxima and volumes and tints loose cells.
9. **Pump, soak, wetting, transport.** The pump spills `pump_rate / bore_rate = 0.1 m³` per tick onto the spoil disc as `water_depth`, drawn from the footprint: a reservoir cell (static `water_surface` above the ground) gives `V / N` freely (the lake's level never changes; the conservation sums count it as a source), a sheet cell gives what it holds. Soak: every `soak_every = 6` steps (10 Hz) a cell with water on a column that holds water moves exactly one saturation quantum, `capacity / 255` m of depth (`capacity = porosity × soak_column`: 0.2 m for dirt, 0.25 m clay, 0 rock), from its depth into `saturation`, so the byte never stalls and the water sum is exact in quanta; a saturated cell takes no more. Lateral wetting moves pore water quantum by quantum between dirt-topped cells (dirt, or loose > 0.01) with the taper `w / wetting_distance` per cell edge: a neighbour takes a quantum when its saturation is more than the taper plus one quantum below the giver's, at most as many quanta per tick as the giver holds, decided in the flux pass from old state so both sides agree. With dirt's 3 m the halo stops three cells along and two across, and rock (capacity 0, no quanta) never wets. Water flowing into a reservoir cell is absorbed and added to `stats[slots²]` (fixed point), which `TerrainSim.absorbed` sums. There is no sink. Alternative: a jump-flood distance to water for the halo bound; rejected as a third pass for a taper that falls out of the quantum rule.
10. **Collider throttle in `Terrain`.** Bore, deposit, spill and tamp stamps (which always change cells) and the simulation call `Terrain._collider_touch(cell, radius)`, which only records one pending touch (last touch wins; no queue); `_flush_collider(now)` in `_process` calls `patch.on_edit` at most every `collider_edit_interval` while the zone holds the touch and at most every `collider_zone_interval` when it would move the zone (the first touch goes at once). Push stamps do not touch the collider: the CPU cannot tell a push over a pile from one over bare ground, and sixty touches a second while walking would drive an edit bake five times a second and a zone move (a 2.7 ms Jolt build and a new hole under the player) every second on plain ground; instead, while tiles are active the simulation re-touches the last tool stamp's cell (pushes included) every frame, so a push that moved loose is followed three frames later and a slumping pile's shape follows at 5 Hz. The debug dig keeps slice 2's direct path. Alternative: throttling inside `ColliderPatch.on_edit`; rejected since `edit_run`'s forced in-flight zone moves rely on two zone moves in consecutive frames.
11. **The auger prop and controls.** `auger.tscn`: a `Node3D` (`auger.gd`) with a `CylinderMesh` (radius 1, height 12, centred 4 m below the node) and a `StaticBody3D` with the same cylinder, placed in the tangent frame at its cell centre with the origin at the ground height the collider gives, under `Station`. `Tools` (`tools.gd`, a node in `main.tscn` beside `DebugEdit`) handles `E`: with no auger, the crosshair ray's hit within `place_reach` places one (the ray helper moves from `DebugEdit` to a static `DebugEdit.look_hit`); within `pickup_distance` of a placed auger it picks it up; otherwise it prints "Pick up the auger first". `E` is ignored while the fly camera is the viewer (it uses `E` to climb). The auger stops with `print("Auger stopped: depth")` or `"rock"` and a `stopped(reason)` signal; it pauses by refusal (`Terrain.can_stamp` false while its bore or spoil tiles are out of the window) and resumes when they return; it is never saved.
12. **Feet.** `Player` emits `stepped(floor_velocity)` every physics tick on the floor and `landed(speed)` on the airborne-to-floor transition, with the downward speed before the slide, only after at least `AIRBORNE_TICKS = 9` ticks (0.15 s) off the floor: pushing from under the feet lowers the ground up to 36 cm between two throttled bakes, and the capsule's catch-up when a bake lands would otherwise read as a landing above 2 m/s and tamp the pile the player is merely crossing; a jump is airborne four times longer. `Tools` pushes while `floor_velocity ≥ push_min_speed` (a `MODE_PUSH` stamp of `foot_radius` at the player's cell toward `push_dir`, moving `min(push_share · loose, push_max)` per footprint cell as volume into the cell ahead, computed as a gather so no two threads write one cell) and tamps on `landed(speed ≥ tamp_land_speed)` (`MODE_TAMP`: `compaction += tamp_step` on loose cells; at 1 the cell folds: `surface += loose / swell`, material dirt, `loose = 0`, `compaction = 0`). Sixty tiny push lists a second while walking are accepted (each a 5 × 5 box); a push into a masked cell or off the window is refused per cell, volume kept.
13. **Measurement driver** `tool_run.gd` / `tool_run.tscn`, built across the tasks the way `edit_run` was, runs on a copy of the default world (`user://worlds/tool_run`, params and maps copied by the driver, its `tiles/` wiped at the start) with `persist_edits` on, so it can restart the terrain in-process (free `main.tscn`, instantiate it again) and prove the restart. It reads fields synchronously (`texture_get_data`, whole textures) at phase boundaries, sums volumes in float64 as `Σ field · (R − surface) · Δθ` and removed volumes as the exact annulus, and asserts the spec's "Measurement and proof" bullets; piles are summed over a box around their site (they stay at repose), water over the whole window as deltas from a read before the spill (a thin sheet runs a cell a step until it soaks in). Timings are reported against the budgets, not asserted; the driver's own synchronous reads during a phase (the `walk` clearance samples, the `_wet_ever` samples) are hitches of its own making, and the summary names the phases that carry them. It takes about two minutes, the bore being 30 s of it.
14. **Memory.** GPU at 512: `loose` and `water_depth` 2 × 1 MB on each window (the far window's are zero and unused, like `edit_mask`), flux textures 4 + 4 + 1 MB, stats 68 B, counter 8 B, `_up` and `_down` grow to 0.5 and 2.1 MB; about 13 MB in all, 47 MB at 1024. CPU: 524 KB per edited tile.
15. **The simulation and `regenerate()`.** `TerrainWindow.regenerate` rewrites every tile from the generator and the blobs; active tiles are reset to their last pack. It is a debug path (noise tuning); documented in its comment, not handled.

## File Structure

- `godot/terrain/terrain_window.gd`: `FIELDS`, `FLOAT_FIELDS`, `field_format`, `tile_at`, `evicted_by` (Task 1).
- `godot/terrain/shaders/detail.glsl`: zero `o_loose`, `o_depth` (Task 1). `godot/terrain/shaders/collider_bake.glsl`, `godot/terrain/collider_patch.gd`: bake `surface + loose` (Task 1).
- `godot/terrain/edit_layer.gd`, `godot/terrain/shaders/edit.glsl`: 32-byte cells, 11 fields (Task 1); `Op`, stamp modes 3 to 7, counter, stats, `pack_tiles`, `pack_tiles_sync` (Task 2).
- `godot/terrain/world_io.gd`: version 2, version 1 upgrade (Task 1).
- `godot/terrain/shaders/cylinder_tile.gdshaderinc`, `tile.gdshader`, `water.gdshader`: `ground_of` (Task 1); the loose look and sheet water (Task 6). `godot/terrain/debug_window_dump.gd`: loose and sheet in the P dump (Task 6).
- `godot/terrain/tool_params.gd`: new (Task 2).
- `godot/terrain/terrain_sim.gd`, `godot/terrain/shaders/sim.glsl`: new (Task 3).
- `godot/terrain/terrain.gd`: `tools`, `sim`, `can_stamp`, `stamp_tool`, `set_obstacle`, the throttle, `_process` order, pack-before-evict, exit pack (Tasks 2, 3).
- `godot/player.gd`: `stepped`, `landed` (Task 4). `godot/terrain/tools.gd`: new (Task 4: feet; Task 5: the auger key). `godot/terrain/auger.gd`, `auger.tscn`: new (Task 5). `godot/terrain/debug_edit.gd`: `look_hit` (Task 5). `godot/main.tscn`: the `Tools` node (Task 4).
- `godot/terrain/timing_overlay.gd`: `"pack"`, `"sim"` (Tasks 2, 3).
- Drivers: `godot/terrain/tool_run.gd`, `tool_run.tscn` (Tasks 2 to 9); `godot/terrain/bake_check.gd` (Task 1, the reference adds loose).
- Tests: `godot/tests/test_edit_layer.gd` (Tasks 1, 2), `test_tools.gd` (new, Tasks 2 to 5), `test_terrain_sim.gd` (new, Task 3), `test_hold_rule.gd` (Task 3, the throttle), `test_player.gd` (Task 4).
- Notes: `docs/terrain-research.md` 6.8, `docs/superpowers/plans/2026-10-28-terrain-slice-3-followups.md` (Task 9).

## Review Focus

1. A pile at the θ = 2π seam: the flux must wrap between columns 16383 and 0, tiles 127 and 0 must both go active (the neighbour bit across the seam) and the sum over both must hold. Pinned by `tool_run`'s `seam` phase (Task 3): a 20 m³ deposit centred on cell (0, row) settles with its volume within 0.5 % and both tiles were active.
2. A deposit or bore at the station's end rows: a tool disc that would leave the station is refused (`can_stamp`), the flux refuses rows below 0 and from `n_z` on, and nothing is lost or errors. Pinned by the `ends` phase (Task 3): a deposit at row `n_z − 2` is refused, one at `n_z − 3` conserves its volume while slumping against the end, and the run has no `ERROR` line; `stamp_tiles` at `j = 1` and `n_z − 2` stays in `test_edit_layer.gd`.
3. A pile under the player while the window scrolls: a tile evicted mid-slump must be packed first, come back with the same loose and resume slumping (the apply pass flags cells that hold loose or water), and the player walking onto a pile must stand on it, not in it, while the throttled bake catches up, without the catch-up counting as a landing that tamps. Pinned by the `scroll` phase (Task 8): the loose sum after the teleport away and back equals the sum before within 0.1 % and the pile then settles at repose; and by the `walk` phase (Task 4): the player's minimum clearance to the drawn ground over the crossing is at least −0.3 m and no tamp is counted. Whether Jolt flickers `is_on_floor` under a heightfield updated five times a second beyond that case is unverified; the walk's tamp count is the observation.
4. Water flowing into a static lake cell: the lake's `water_surface` texels never change, the inflow is absorbed and counted, and the water sum (sheet + pore + absorbed) matches what was pumped. Pinned by the `pump` phase (Task 7), which depends on the default world having a lake with dirt beyond its shore; the phase prints what it finds.
5. Quitting mid-bore: the active tiles are packed at exit, the hole and the pile come back within one tick, and the auger prop does not. Pinned by the `restart` phase (Task 8), which frees and re-instantiates `main.tscn` while the auger is boring; the engine-quit path (a compute list and a synchronous readback inside `_exit_tree` at application exit) is exercised only by Task 3's manual quit, which must show no `ERROR` line. The reuse of `_down`'s slots by a second pack list in the same callback is pinned by Task 2's `pack slots reused` check.

---

### Task 1: `loose` and `water_depth` fields, blob version 2, the collider and the drawn ground on `surface + loose`

**Files:**
- Modify: `godot/terrain/terrain_window.gd`, `godot/terrain/shaders/detail.glsl` (set 1 bindings), `godot/terrain/shaders/edit.glsl` (bindings, pack, apply), `godot/terrain/edit_layer.gd`, `godot/terrain/world_io.gd`, `godot/terrain/shaders/collider_bake.glsl`, `godot/terrain/collider_patch.gd` (`_uniform_set`), `godot/terrain/shaders/cylinder_tile.gdshaderinc`, `godot/terrain/shaders/tile.gdshader`, `godot/terrain/shaders/water.gdshader`, `godot/terrain/terrain.gd` (`_material`), `godot/terrain/bake_check.gd`
- Test: `godot/tests/test_edit_layer.gd`

**Interfaces:**
- Consumes: slice 2's `EditLayer`, `WorldIO`, `TerrainWindow`, `ColliderPatch._uniform_set`, `collider_bake.glsl`'s `surface(k, j)`.
- Produces:
  - `TerrainWindow.FIELDS := [.., "edit_mask", "loose", "water_depth"]` (11 entries; `loose` at 9, `water_depth` at 10, both in m); `const FLOAT_FIELDS := ["surface", "bedrock_top", "clay_bottom", "clay_top", "water_surface", "loose", "water_depth"]`; `static func field_format(field: String) -> RenderingDevice.DataFormat` (`R32_SFLOAT` for `FLOAT_FIELDS`, else `R8_UNORM`), used by `_setup_rd`. `func tile_at(slot: Vector2i) -> Vector2i` (the resident tile of a slot, `Vector2i(-1, -1)` when none). `func evicted_by(center: Vector2i) -> Array[Vector2i]` (resident tiles not in `wanted_tiles(center)`).
  - `detail.glsl`: `layout(set = 1, binding = 9, r32f) o_loose`, `binding = 10, r32f o_depth`, both stored 0 for every cell.
  - `EditLayer`: `CELL_BYTES := 32`; `BLOB_SIZE` follows; the blob cell is eight uints: the five heights' bits, the packed bytes, `loose` bits, `water_depth` bits. `decode` gains `loose` (+24) and `water_depth` (+28). `static func upgrade_v1(blob: PackedByteArray) -> PackedByteArray` (393,216 in, `BLOB_SIZE` out, each cell's 24 bytes copied and 8 zero bytes appended). `_setup_rd` binds bindings 2..12 in `FIELDS` order. `edit.glsl`: `w_loose` at binding 11, `w_depth` at 12; pack writes eight uints per cell at `(j · 128 + i) · 8` (zeros for an unmasked cell); apply reads eight and stores `loose` and `water_depth` too. Mode 0 leaves both unchanged.
  - `WorldIO.EDIT_VERSION := 2`; `load_edits` accepts version 1 with raw size 393,216 (decompressed to that, then `EditLayer.upgrade_v1`) and version 2 with raw size `BLOB_SIZE`; anything else is skipped with the existing warning. The header comment says so.
  - `collider_bake.glsl`: `layout(set = 0, binding = 3, r32f) readonly image2D w_loose`; `surface()` returns `w_surface + w_loose` for a resident cell. `ColliderPatch._uniform_set` adds the window's `loose` at binding 3.
  - `cylinder_tile.gdshaderinc`: `uniform sampler2D loose_tex : filter_nearest;` and `float ground_of(ivec2 k)` = `height_of(surface_tex, k) + height_of(loose_tex, k)`. `tile.gdshader` uses `ground_of` for `h` and the normal differences; `water.gdshader` uses `ground_of` for `s`. `Terrain._material` sets `loose_tex` from `w.texture_rd("loose")`.
  - `bake_check.gd`: the reference row `h[k]` adds the `loose` texel to the `surface` texel.
  - No change to `ColliderPatch.surface_point` (it reads the baked shapes, which now carry loose, so `teleport` and `_on_live` stand a body on a pile) nor to `Terrain.height_at` (the macro surface, used only to lift a held body 2 m over the ground before a patch lands); say so in a line of each comment.

- [ ] **Step 1: Write the failing tests**

In `test_edit_layer.gd` change the first check to `EditLayer.BLOB_SIZE == 128 * 128 * 32 and EditLayer.cell_offset(3, 2) == (2 * 128 + 3) * 32` and, after the decode checks, add `blob.encode_float(o + 24, 0.75); blob.encode_float(o + 28, 0.02)` before `var d := EditLayer.decode(blob, 5, 7)` and extend that check with `and d.loose == 0.75 and d.water_depth == 0.02`. Append after the "corrupt tile skipped" block (before the zone checks):

```gdscript
	# Slice 3: FIELDS name the two new float fields; a version 1 blob pads to the 32-byte cell and a version 1
	# file loads that way; saves are version 2.
	check(TerrainWindow.FIELDS.size() == 11 and TerrainWindow.FIELDS[9] == "loose" and TerrainWindow.FIELDS[10] == "water_depth", "fields %s" % [TerrainWindow.FIELDS])
	check(TerrainWindow.field_format("loose") == RenderingDevice.DATA_FORMAT_R32_SFLOAT and TerrainWindow.field_format("edit_mask") == RenderingDevice.DATA_FORMAT_R8_UNORM, "field formats")
	var v1 := PackedByteArray(); v1.resize(128 * 128 * 24)
	v1.encode_float((7 * 128 + 5) * 24, 412.5); v1.encode_u32((7 * 128 + 5) * 24 + 20, 2 | (255 << 24))
	var up := EditLayer.upgrade_v1(v1)
	var u := EditLayer.decode(up, 5, 7)
	check(up.size() == EditLayer.BLOB_SIZE and u.surface == 412.5 and u.material == 2 and u.mask == 255 and u.loose == 0.0 and u.water_depth == 0.0, "v1 upgrade %s" % u)
	check(EditLayer.decode(up, 6, 7).mask == 0 and EditLayer.decode(up, 5, 8).surface == 0.0, "v1 untouched cells")
	var old := FileAccess.open("user://worlds/test_world/tiles/8_8.edit", FileAccess.WRITE)
	old.store_32(1); old.store_32(v1.size()); old.store_buffer(v1.compress(FileAccess.COMPRESSION_ZSTD)); old.close()
	var mixed := WorldIO.load_edits("test_world")
	check(mixed.size() == 3 and mixed[Vector2i(8, 8)] == up, "a version 1 tile loads padded")
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://worlds/test_world/tiles/8_8.edit"))
	var saved := FileAccess.open("user://worlds/test_world/tiles/5_7.edit", FileAccess.READ)
	check(saved.get_32() == 2 and saved.get_32() == EditLayer.BLOB_SIZE, "saved as version 2")
	saved.close()
	var w2 := TerrainWindow.new(); w2.configure(p, 512, 1.0)
	w2.center_tile = Vector2i(10, 20)
	for t in w2.wanted_tiles(w2.center_tile): w2._resident[w2.slot_of(t)] = t
	check(w2.tile_at(w2.slot_of(Vector2i(10, 20))) == Vector2i(10, 20) and w2.tile_at(Vector2i(0, 0)) != Vector2i(-1, -1), "tile_at")
	# The wanted set from tile (8, 18); a centre one tile spinward evicts the column at 8.
	var ev := w2.evicted_by(Vector2i(11, 20))
	check(ev.size() == 4 and ev.has(Vector2i(8, 18)) and ev.has(Vector2i(8, 21)) and not ev.has(Vector2i(9, 18)), "evicted tiles %s" % [ev])
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd godot && godot --headless --path . --fixed-fps 60 --quit-after 7200 -s res://tests/test_edit_layer.gd`
Expected: the blob layout check fails (24-byte cells), then `field_format` not found.

- [ ] **Step 3: Implement the fields, the blob, the version, the bake and the drawn ground**

As in Interfaces. In `edit.glsl` and `detail.glsl` keep the existing bindings and append the new ones. `upgrade_v1` may loop (load-time only; say so in its comment).

- [ ] **Step 4: Run the suite, then the slice 2 drivers**

Run: `cd godot && sh tests/run.sh`
Expected: all `PASS`.

Run: `cd godot && godot --rendering-driver vulkan --path . res://terrain/edit_run.tscn` and `godot --rendering-driver vulkan --path . res://terrain/bake_check.tscn`
Expected: both `PASS`, no `ERROR` lines: the pit still survives the scroll bitwise with 32-byte blobs, the bake matches the reference with loose at zero.

- [ ] **Step 5: Commit**

```bash
git add godot/terrain/terrain_window.gd godot/terrain/shaders/detail.glsl godot/terrain/shaders/edit.glsl godot/terrain/edit_layer.gd godot/terrain/world_io.gd godot/terrain/shaders/collider_bake.glsl godot/terrain/collider_patch.gd godot/terrain/shaders/cylinder_tile.gdshaderinc godot/terrain/shaders/tile.gdshader godot/terrain/shaders/water.gdshader godot/terrain/terrain.gd godot/terrain/bake_check.gd godot/tests/test_edit_layer.gd
git commit -m "Terrain: loose and water_depth window fields, edit blob version 2 (version 1 loads padded), ground is surface + loose"
```

---

### Task 2: Stamp modes (bore, deposit, push, tamp, spill), the bore counter, `ToolParams`, `Terrain.stamp_tool`

**Files:**
- Modify: `godot/terrain/edit_layer.gd`, `godot/terrain/shaders/edit.glsl`, `godot/terrain/terrain.gd`, `godot/terrain/timing_overlay.gd`
- Create: `godot/terrain/tool_params.gd`, `godot/terrain/tool_run.gd`, `godot/terrain/tool_run.tscn`
- Test: `godot/tests/test_edit_layer.gd`, `godot/tests/test_tools.gd` (new)

**Interfaces:**
- Consumes: Task 1's `EditLayer`, `FIELDS`; `MaterialSet` (`swell_factor[0]`); `ColliderPatch.on_edit`.
- Produces:
  - `class_name ToolParams extends Resource` with the exported fields and defaults of decision 7, each with a one-line doc.
  - `EditLayer` constants `MODE_RAISE := 0, MODE_PACK := 1, MODE_APPLY := 2, MODE_BORE := 3, MODE_DEPOSIT := 4, MODE_PUSH := 5, MODE_TAMP := 6, MODE_SPILL := 7`. Inner `class Op extends RefCounted`: `var cell: Vector2i`, `radius: int`, `mode: int`, `amount := 0.0`, `dir := Vector2i.ZERO`, `limit := 0.0`, `obstacle := Vector2i(-1, -1)`, `obstacle_radius := -1`, `pack := true`, `counted := Callable()`; `func reach() -> int` (`radius + 1` for `MODE_PUSH`, else `radius`). `amount` is: raise, m at the centre; bore, the step in m; deposit and spill, m³; push, the share; tamp, the compaction step. `limit` is: bore, the pump's m³ per tick; push, the cap in m per cell; tamp, the swell.
  - `func stamp_op(window: TerrainWindow, op: Op) -> void`: on the render thread, one list between `edit_begin/_end`: when `op.counted.is_valid()`, `buffer_clear(_counter, 0, 8)` before the list; the stamp dispatch over `box_groups(op.reach())` groups per axis; when `op.pack`, a barrier then a pack dispatch per tile of `stamp_tiles(window, op.cell, op.reach())` into slot `k`; after the list the pack readbacks as today and, when counted, `buffer_get_data_async(_counter, _counted.bind(op.counted), 0, 8)`. `_counted(data, cb)` returns when `not cb.is_valid()` (the auger was freed while the readback was in flight) and otherwise calls `cb.call(data.decode_u32(0) * 1e-6, data.decode_u32(4) != 0)` (inside the readback flush: the callee sets flags only). `stamp(window, cell, radius, dh)` becomes `stamp_op` with `MODE_RAISE`, `amount = dh`, `pack = true`.
  - `func pack_tiles(window: TerrainWindow, tiles: Array[Vector2i]) -> void`: lists of at most `DOWN_SLOTS` pack dispatches between `pack_begin/_end`, each list's readbacks after it. `func pack_tiles_sync(window, tiles) -> void`: the same lists with `buffer_get_data(_down, k * BLOB_SIZE, BLOB_SIZE)` after each, stored through `_packed`.
  - `func stats_rid() -> RID` and `func stats_size() -> int` (`(slots² + 1) · 4` bytes): the stats buffer `_setup_rd` creates (zeroed) and binds at 14; `_counter` (8 bytes) at 13. `static func disc_cells(radius: int) -> int` (integer offsets with `length <= radius`: 1, 5, 13 for 0, 1, 2). `static func box_groups(reach: int) -> int` = `ceili((2 * reach + 1) / 8.0)`. `func _params(window: TerrainWindow, op: Op, tile: Vector2i, slot: int) -> PackedByteArray`, 96 bytes at these std430 offsets: 0 `cell`, 8 `first_tile`, 16 `tile`, 24 `n_theta`, 28 `slots`, 32 `mode`, 36 `radius`, 40 `slot` (pack: the slot; bore, deposit, spill: `disc_cells(radius)`), 44 `obstacle_radius`, 48 `dir`, 56 `obstacle`, 64 `amount` (as `dh`), 68 `limit`, 72 `h_max`, 76 `R`, 80 `dtheta`, 84..96 padding.
  - `edit.glsl`: the push block above (`tiles_around` dropped); bindings 13 `buffer Counter { uint counter[2]; }`, 14 `buffer Stats { uint stats[]; }`; helpers `blocked(c)` (within `obstacle_radius` cells of `obstacle`, θ the short way round; false when the radius is negative), `flag(t)` (`atomicOr(stats[(t.y / 128) * slots + t.x / 128], 1u)`, called by every mode that changes a cell, mode 0 included, and by mode 2 (apply) for a cell whose blob holds `loose > 0` or `water_depth > 0`, so a pile re-entering the window resumes while a plain edited tile does not wake the simulation), `area(s)` = `(R − s) · dtheta`. The new modes, each over the box of `reach` around `cell`, skipping cells outside the disc or not resident (mode 0 and pack as before):
    - 3 bore: `wet` from the centre cell's texel: `w_water > s_c + loose_c + 1e-3 || depth_c > 0.01`. Dry: `cut = min(dh, s − bt)`; `s' = s − cut`; `cb = min(cb, s')`, `ct = min(ct, s')`; material by the slice 2 rule; `atomicAdd(counter[0], uint(round(0.5 · dtheta · cut · (2.0 · (R − s) + cut) · 1e6)))` (the product form of the annulus, decision 5); mask 1; flag. Wet: `share = limit / float(slot)` m³; a reservoir cell (`w_water > s + loose + 1e-3`) adds `share`; else `take = min(depth · area(s), share)`, `depth −= take / area(s)`, adds `take`; `atomicMax(counter[1], 1u)`; mask 1; flag.
    - 4 deposit: `t = (dh / float(slot)) / area(s)`; `loose += t`; `compaction = 0`; mask 1; flag. 7 spill: the same into `water_depth` (compaction untouched).
    - 5 push: for the invocation's cell `c` (box of `radius + 1`): `out(x)` for a cell `x` is `min(dh · loose_x, limit)` when `x` is inside the disc of `radius` around `cell`, resident, `x + dir` resident and not blocked; else 0. `loose_c' = loose_c − out(c) + out(c − dir) · area(s_{c−dir}) / area(s_c)`; only when it changed: store it, mask 1, flag (a push over bare ground stores, masks and flags nothing).
    - 6 tamp: cells with `loose > 1e-3`: `compaction += dh`; if `compaction >= 1 − 1e-3`: `s += loose / limit` (clamped to `h_max`), `material = 0`, `loose = 0`, `compaction = 0`; else store the compaction; mask 1; flag.
  - `Terrain`: `@export var tool_params: ToolParams` (a `ToolParams.new()` in `_ready` when null); `var materials: MaterialSet` (`preload("res://terrain/materials.tres")`); `func can_stamp(cell: Vector2i, reach: int) -> bool` (the residency rule of `edit`: live, `reach < TILE`, the tiles of `stamp_tiles(window, cell, reach)` neither empty, nor more than `DOWN_SLOTS`, all resident; and, unlike `edit`, false when the box leaves the station, `cell.y - reach < 0` or `cell.y + reach >= n_z()`, so a tool never places part of a disc off the world); `func stamp_tool(op: EditLayer.Op) -> bool`: false unless `can_stamp(op.cell, op.reach())`; sets `op.obstacle`, `op.obstacle_radius` from `_obstacle`, `_obstacle_radius` (`func set_obstacle(cell: Vector2i, radius: int) -> void` stores them; Task 3 hands them to the simulation too), calls `window.edits.stamp_op(window, op)`, records `_last_tool = op.cell`, `_last_reach = op.reach()`, then, unless `op.mode == MODE_PUSH` (decision 10), `patch.on_edit(op.cell, op.reach())` (Task 3 replaces this call with the throttle), returns true. `edit` is unchanged.
  - `timing_overlay.gd` `_gpu` gains `"pack"`.

- [ ] **Step 1: Write the failing tests**

Append to `test_edit_layer.gd` before `if failed:`:

```gdscript
	# Slice 3 stamps: disc cell counts, the push's reach, and the push-constant layout of edit.glsl.
	check(EditLayer.disc_cells(0) == 1 and EditLayer.disc_cells(1) == 5 and EditLayer.disc_cells(2) == 13, "disc cells")
	check(EditLayer.box_groups(1) == 1 and EditLayer.box_groups(4) == 2, "box groups")
	var op := EditLayer.Op.new()
	op.cell = Vector2i(16383, 40); op.radius = 1; op.mode = EditLayer.MODE_PUSH; op.dir = Vector2i(1, 0)
	check(op.reach() == 2, "a push reaches one cell past its disc")
	op.mode = EditLayer.MODE_TAMP
	check(op.reach() == 1, "other modes reach their radius")
	op.amount = 0.05; op.limit = 0.03; op.obstacle = Vector2i(5, 6); op.obstacle_radius = 1
	var pc := EditLayer.new()._params(w, op, Vector2i(127, 0), 3)
	check(pc.size() == 96 and pc.decode_s32(0) == 16383 and pc.decode_s32(4) == 40 and pc.decode_s32(16) == 127 and pc.decode_s32(28) == 4 \
			and pc.decode_s32(32) == EditLayer.MODE_TAMP and pc.decode_s32(36) == 1 and pc.decode_s32(40) == 3 and pc.decode_s32(44) == 1 \
			and pc.decode_s32(48) == 1 and pc.decode_s32(52) == 0 and pc.decode_s32(56) == 5 and pc.decode_s32(60) == 6 \
			and absf(pc.decode_float(64) - 0.05) < 1e-7 and absf(pc.decode_float(68) - 0.03) < 1e-7 and pc.decode_float(76) == p.radius \
			and absf(pc.decode_float(80) - p.dtheta()) < 1e-12, "edit push constants")
```

`godot/tests/test_tools.gd`:

```gdscript
extends SceneTree

var failed := false

func check(ok: bool, msg: String) -> void:
	if not ok:
		push_error(msg)
		failed = true

func _initialize() -> void:
	# The tunables carry the spec's numbers: 10 m in 30 s at 10 ticks a second, four landings tamp a patch, a
	# cubic metre a second of pumped water, relaxation at an eighth per step.
	var t := ToolParams.new()
	check(is_equal_approx(t.bore_step * t.bore_rate * 30.0, 10.0) and t.bore_depth == 10.0 and t.bore_radius == 1, "bore numbers")
	check(t.spoil_radius == 2 and t.spoil_offset == 7 and t.pump_rate == 1.0, "spoil and pump")
	check(t.tamp_step == 0.25 and t.tamp_land_speed == 2.0 and t.push_share == 0.05 and t.push_max == 0.03 and t.foot_radius == 1, "feet")
	check(t.slump_rate == 0.125 and t.flow_rate == 0.125 and t.soak_every == 6 and t.settle_time == 1.0 and t.move_eps == 1e-4, "simulation")
	check(t.collider_edit_interval == 0.2 and t.collider_zone_interval == 1.0, "collider throttle")
	var m: MaterialSet = load("res://terrain/materials.tres")
	check(m.swell_factor[0] == 1.25 and m.repose_dry[0] == 35.0 and m.repose_damp[0] == 40.0 and m.repose_saturated[0] == 20.0 \
			and m.porosity[0] == 0.4 and m.wetting_distance[0] == 3.0 and m.wetting_distance[2] == 0.0, "dirt and rock from materials.tres")
	if failed: quit(1)
	else: print("PASS"); quit(0)
```

- [ ] **Step 2: Run them to verify they fail**

Run: `cd godot && godot --headless --path . --fixed-fps 60 --quit-after 7200 -s res://tests/test_edit_layer.gd; godot --headless --path . --fixed-fps 60 --quit-after 7200 -s res://tests/test_tools.gd`
Expected: `disc_cells` not found; `ToolParams` not found.

- [ ] **Step 3: Implement the modes, the counter and stats buffers, `Op`, `stamp_op`, `pack_tiles`, `ToolParams`, `stamp_tool`**

As in Interfaces. The push mode's gather reads `c − dir`'s state with the same expression the `c − dir` invocation uses for its own `out`, so the two agree bit for bit.

- [ ] **Step 4: Run the suite, then write and run the first `tool_run` phase**

Run: `cd godot && sh tests/run.sh`
Expected: all `PASS`, `test_tools.gd` among them.

`terrain/tool_run.tscn`: a `Node` with `tool_run.gd`, which instantiates `main.tscn` as `edit_run.gd` does (mouse events swallowed, `persist_edits = false` until Task 8 switches it to the `tool_run` world), connects the overlay's `timed`, waits for `collider_live` then a frame, and keeps these helpers: `_read(field) -> PackedByteArray` (sync `texture_get_data` of a window field), `_f(bytes, cell) -> float` and `_b(bytes, cell) -> int` (texel `posmod(c.y, size) · size + posmod(c.x, size)`), `_box(center, half) -> Array[Vector2i]` (θ wrapped, rows clamped), `_vol(field_bytes, surface_bytes, cells) -> float` (`Σ v · (R − s) · Δθ`, float64), `_sum(field_bytes, surface_bytes) -> float` (the same over every texel of the window), `_pore(sat0, sat1, material, loose, surface) -> float` (`Σ (sat1 − sat0) / 255 · capacity · (R − s) · Δθ` over every texel, the capacity `porosity[m] · soak_column` of the cell's top material, dirt where `loose > 0.01`), `_removed(s0, s1, cells) -> float` (`Σ 0.5 · Δθ · (s0 − s1) · (2 · (R − s0) + (s0 − s1))`, the annulus between the two surfaces), `_op(cell: Vector2i, radius: int, mode: int, amount: float, dir := Vector2i.ZERO, limit := 0.0) -> EditLayer.Op` (an `Op` with those fields and `pack = false`; `Op` has no constructor, and every `_op(..)` in the phases below is this helper), `_report(what, ok)` and `_expect`. Sites are cells on the spawn's column, `spawn_cell + Vector2i(0, 40 · k)` for `k` as given. Phase `stamps` at site `k = 1` (`S1`), everything through `terrain.stamp_tool` with `tool_params` values, three frames after each stamp before reading; the deposit, push and tamp checks sum over `_box(S1, 6)` (a 0.11 m layer is below repose, so nothing slumps out of it once Task 3's simulation runs):

1. Deposit: `_op(S1, spoil_radius, MODE_DEPOSIT, 1.5)`: `_vol(loose)` over the box within 0.1 % of 1.5, every disc cell's compaction byte 0 and mask 255: `deposit conserves: ok`.
2. Push: `_op(S1, 2, MODE_PUSH, push_share, (0, 1), push_max)` three times: the loose volume unchanged within 1e-4 relative, the loose-weighted mean row over the box grew by at least 0.05 cells: `push moves forward, conserves: ok`.
3. Tamp: `_op(S1, 2, MODE_TAMP, tamp_step, ZERO, swell)` four times, reading between: after three the disc's compaction bytes are 191 ± 1 (0.75) where loose > 1e-3; after four every such cell has loose 0, compaction 0, material 0, and `Σ (s_after − s_before) · area(s_before)` over the tamp disc equals the loose volume over that disc before the fourth (the pushes moved some loose outside it, which does not fold) divided by 1.25 within 0.1 %: `tamp folds with the swell: ok`.
4. Spill: read `sat0`; `_op(S1 + (0, 10), 2, MODE_SPILL, 0.5)`: the whole-window delta `_sum(water_depth) − before + _pore(..)` within 2 % of 0.5 (exact in this task; from Task 3 the sheet runs and soaks, and the sum still holds): `spill conserves: ok`.
5. Bore: record `s0` over `_box(S1 + (0, 20), 3)`; 30 ticks of `_op(S1 + (0, 20), bore_radius, MODE_BORE, bore_step, ZERO, pump_rate / bore_rate)` with `counted` set to a lambda summing the volume and recording wet, at 10 a second; wait 5 frames: the counter sum equals `_removed(s0, s1, box)` within 0.1 %, no tick was wet, the five disc cells dropped by 1.0 m ± 1 mm, their `clay_top` and `clay_bottom` are at most the new surface, their material is 0, 1 or 2 by the rule: `bore counts what it cut: ok`.
6. Pack slots: `edits.pack_tiles(window, six resident tiles with S1's tile first)` (two lists; the second reuses slot 0); wait 4 frames: `edits.blobs` has all six, and `EditLayer.decode(blobs[S1's tile], S1 local)` has `loose` bitwise equal to the window's texel and mask 255 (had the second list's write reached `_down` before the first list's copy, this blob would be the fifth tile's zeros): `pack slots reused across lists: ok`. This is the only check of that reuse on this branch; its failure means `pack_tiles` must wait a frame between lists.
7. Prints `PASS`/`FAIL`, exits 0/1.

Run: `cd godot && godot --rendering-driver vulkan --path . res://terrain/tool_run.tscn`
Expected: the six `ok` lines, `PASS`, no `ERROR` lines; the `edit` lists under 0.5 ms.

- [ ] **Step 5: Commit**

```bash
git add godot/terrain/edit_layer.gd godot/terrain/shaders/edit.glsl godot/terrain/terrain.gd godot/terrain/timing_overlay.gd godot/terrain/tool_params.gd godot/terrain/tool_run.gd godot/terrain/tool_run.tscn godot/tests/test_edit_layer.gd godot/tests/test_tools.gd
git commit -m "Terrain: bore, deposit, push, tamp and spill stamp modes with a bore counter; ToolParams; Terrain.stamp_tool"
```

---

### Task 3: The simulation pass: slump, water flow, soak and wetting, transport, activity, settle-and-pack, the collider throttle

**Files:**
- Create: `godot/terrain/terrain_sim.gd`, `godot/terrain/shaders/sim.glsl`, `godot/tests/test_terrain_sim.gd`
- Modify: `godot/terrain/terrain.gd` (`sim`, `_process`, `_move_window`, `_exit_tree`, the throttle, `set_obstacle`), `godot/terrain/edit_layer.gd` (nothing new; the stats buffer is Task 2's), `godot/terrain/timing_overlay.gd` (`"sim"`), `godot/terrain/tool_run.gd`
- Test: `godot/tests/test_terrain_sim.gd`, `godot/tests/test_hold_rule.gd`

**Interfaces:**
- Consumes: Task 1's `tile_at`, `evicted_by`; Task 2's `stats_rid`, `stats_size`, `pack_tiles`, `pack_tiles_sync`, `ToolParams`, `stamp_tool`, `set_obstacle`; `MaterialSet` rows 0..3; `ColliderPatch.on_edit`, `zone_holds`, `has_zone`, `zone`.
- Produces:
  - `class_name TerrainSim extends RefCounted`: `const STEP := 1.0 / 60.0`, `MAX_STEPS := 2`, `MAX_ACTIVE := 16`, `NO_CELL := Vector2i(-1, -1)`; `var params: ToolParams`, `var materials: MaterialSet`, `var obstacle := NO_CELL`, `var obstacle_radius := -1`, `var absorbed := 0.0` (m³ taken by reservoirs, from landed stats); `var steps := 0` (steps run, for the driver). `func setup(window: TerrainWindow, edits: EditLayer) -> void` (render thread: compiles `sim.glsl`, creates `_flux_loose`, `_flux_water` as `R32G32B32A32_SFLOAT` and `_flux_pore` as `R8G8B8A8_UNORM` window-sized storage textures, one uniform set: bindings 0..10 the window's `FIELDS` images, 11, 12, 13 the flux textures, 14 `edits.stats_rid()`). `func settle(window: TerrainWindow, delta: float, flags: PackedInt32Array) -> Array[Vector2i]` (CPU only: for each slot index `s` with `flags[s] & 3`, the tile `window.tile_at(slot)` is active with quiet 0 when resident; every other active tile's quiet grows by `delta`; tiles with quiet `>= params.settle_time`, and the quietest beyond `MAX_ACTIVE`, are removed and returned in that order). `func step(window: TerrainWindow, delta: float) -> Array[Vector2i]`: `settle(window, delta, _flags)` then `_flags.fill(0)`; accumulates `delta` (clamped to `MAX_STEPS · STEP`, so an idle stretch banks no steps), and for each whole `STEP` (at most `MAX_STEPS`) with active tiles, one render-thread list between `sim_begin/_end`: a flux dispatch (16 × 16 groups) per active tile, a barrier, an apply dispatch per active tile, `steps += 1`; then every frame, active or not, after any list: `buffer_get_data_async(stats, _on_stats.bind(_generation), 0, size)` and `buffer_clear(stats, 0, size)`. `_on_stats(data, generation)`: returns when `generation != _generation` (the window moved since the request: its slots name other tiles); else `_flags = data.slice(0, data.size() − 4).to_int32_array()`, `absorbed += data.decode_u32(data.size() − 4) · 1e-6` (the last uint is the absorbed total; nothing else). `func invalidate() -> void` (`_generation += 1`; `Terrain._move_window` calls it). `func activate(tiles: Array[Vector2i]) -> void` (each resident tile active with quiet 0: the CPU-side activation for an obstacle lifted or moved, decision 3). `func has_active() -> bool`, `func active_tiles() -> Array[Vector2i]`, `func is_active(tile: Vector2i) -> bool`, `func drop(tiles: Array[Vector2i]) -> void`. The push block of `sim.glsl` (std430, 112 bytes) is `_params(window, tile, mode, soak_tick)`: 0 `tile`, 8 `first_tile`, 16 `n_theta`, 20 `slots`, 24 `mode`, 28 `soak_tick`, 32 `active_mask` (uvec2: bit `s.y * slots + s.x` of a 64-bit value for every active tile's slot `s`, the low word at 32, the high at 36), 40 `obstacle`, 48 `obstacle_radius`, 52 `dtheta`, 56 `R`, 60 `slump_rate`, 64 `flow_rate`, 68 `transport_share`, 72 `transport_depth`, 76 `repose_tan[3]` (tan of dirt's dry, damp, saturated angles), 88 `capacity[4]` (`porosity[m] · soak_column`), 104 `wetting` (dirt's wetting distance), 108 `move_eps`.
  - `sim.glsl`: `local_size 8 × 8`; `texel(c, out t)` and `wrap` as `edit.glsl`; `active(c)` (the slot bit of `c`'s tile in `active_mask`); `blocked(c)`; `DIR4 = (1,0), (0,1), (−1,0), (0,−1)`, the opposite of `k` is `(k + 2) % 4`; `dirt_topped(loose, mat)` = `loose > 0.01 || mat == 0`; `reservoir(ws, H)` = `ws > H + 1e-3`. Mode 0 (flux), per cell `c` of the tile with texel `t`:

    ```
    read s, L, d, sat, mat, ws;  H = s + L;  res = reservoir(ws, H);  a = (R - s) * dtheta
    W = res ? ws : H + d
    tr = sat < 0.5 ? mix(repose_tan[0], repose_tan[1], 2 sat) : mix(repose_tan[1], repose_tan[2], 2 sat - 1)
    outL = outW = vec4(0); pore = uvec4(0); given = 0; q = byte(sat)
    for k in 0..3: n = c + DIR4[k] (n.x wrapped)
        if !texel(n, tn) || !active(n) || blocked(n): continue
        read s_n, L_n, d_n, sat_n, mat_n, ws_n;  H_n = s_n + L_n;  W_n = reservoir(ws_n, H_n) ? ws_n : H_n + d_n
        w = (k even) ? 0.5 * ((R - s) + (R - s_n)) * dtheta : 1.0
        ex = (H - H_n) - tr * w;        if ex > 0: outL[k] = slump_rate * ex
        df = W - W_n;                    if df > 0 && !res: outW[k] = flow_rate * df
        if soak_tick && dirt_topped(L, mat) && dirt_topped(L_n, mat_n) && given < q
                && q - byte(sat_n) > w / wetting * 255 + 1: pore[k] = 1; given += 1
    tw = sum(outW); if tw > d: outW *= d / tw
    for k: outL[k] += transport_share * min(outW[k] / transport_depth, 1) * L
    tl = sum(outL); if tl > L: outL *= L / tl
    store flux_loose[t] = outL * a;  flux_water[t] = outW * a;  flux_pore[t] = vec4(pore) / 255
    ```

    Mode 1 (apply), per cell `c`:

    ```
    read s, L, d, sat, mat;  a;  res = reservoir(ws, s + L);  q = byte(sat)
    own = flux_loose[t], ownW = flux_water[t], ownP = bytes of flux_pore[t]
    inL = inW = 0; inP = 0
    for k: n = c + DIR4[k]: if texel(n, tn) && active(n): j = (k + 2) % 4;  inL += flux_loose[tn][j];  inW += flux_water[tn][j];  inP += byte(flux_pore[tn][j])
    if res: atomicAdd(stats[slots * slots], uint(round((inW + d * a) * 1e6)));  inW = 0;  d = 0   // a lake absorbs what flows in and what was spilled on it
    L2 = max(L + (inL - sum(own)) / a, 0);  d2 = max(d + (inW - sum(ownW)) / a, 0);  q2 = q + inP - sum(ownP)
    if soak_tick: cap = capacity[dirt_topped(L2, mat) ? 0 : mat];  qm = cap / 255
        if cap > 0 && d2 >= qm && q2 < 255: q2 += 1;  d2 -= qm
    if L2 != L || d2 != d || q2 != q: store L2, d2, q2 / 255, mask 1   // every change, however small: conservation
    moved = abs(L2 - L) > move_eps || abs(d2 - d) > move_eps || q2 != q   // the activity gate only
    if moved: atomicOr(stats[slot of t], 1u)
        for each edge the cell sits on (g.x == 0, g.x == 127, g.y == 0, g.y == 127): if texel(c + that DIR4): atomicOr(stats[slot of that neighbour tile], 2u)
    ```

    The comment block at the top states the conservation argument (decision 2) and the neighbour rule (decision 3).
  - `Terrain`: `var sim: TerrainSim` created and set up after `window.edits.setup` (`sim.params = tool_params`, `sim.materials = materials`); `set_obstacle(cell, radius)` also sets `sim.obstacle`, `sim.obstacle_radius`, and when an obstacle was set before (`_obstacle_radius >= 0`) first calls `sim.activate(EditLayer.stamp_tiles(window, _obstacle, _obstacle_radius + 1))`, so a pile held against a wall slumps on when the wall goes (decision 3). `func _collider_touch(cell: Vector2i, radius: int) -> void` (records the one pending touch `_touch_cell`, `_touch_radius`, last touch wins; `−1` means none) and `func _flush_collider(now: float) -> void`: nothing without a touch; if `patch.has_zone and ColliderPatch.zone_holds(patch.zone, cell, radius, params.n_theta())`: when `now − _edit_at >= tool_params.collider_edit_interval`, `patch.on_edit(cell, radius)`, `_edit_at = now`, clear the touch; else when `now − _zone_at >= tool_params.collider_zone_interval` (both stamps start at `−INF`): `patch.on_edit`, `_zone_at = _edit_at = now`, clear. `stamp_tool` calls `_collider_touch(op.cell, op.reach())` in place of Task 2's direct `on_edit`, still not for `MODE_PUSH`. `_process`, after `far.follow(cell)`: `var settled := sim.step(window, delta)`; `if not settled.is_empty(): window.edits.pack_tiles(window, settled)`; `if sim.has_active() and _last_reach >= 0: _collider_touch(_last_tool, _last_reach)` (this is how a push that moved loose reaches the collider); `_flush_collider(Time.get_ticks_msec() / 1000.0)`; then `patch.issue_again(window)` and the rest as today. `_move_window(center)`: before `window.move_to(center)`, `var leaving := window.evicted_by(center).filter(sim.is_active)`; `window.edits.pack_tiles(window, leaving)`; `sim.drop(leaving)`; `sim.invalidate()`. `_exit_tree`: `window.edits.pack_tiles_sync(window, sim.active_tiles())` before `_save_edits()` (guarded for a null window). `edit` is unchanged (its stamp flags the tile on the GPU, so a dug pile slumps).
  - `timing_overlay.gd` `_gpu` gains `"sim"`.

- [ ] **Step 1: Write the failing tests**

`godot/tests/test_terrain_sim.gd`:

```gdscript
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
	# A landing from before a window move is dropped: its slots name other tiles.
	var stale := PackedByteArray(); stale.resize(65 * 4); stale.encode_u32(0, 1)
	sim.invalidate()
	sim._on_stats(stale, 0)
	check(sim.settle(w, 0.0, sim._flags).is_empty() and not sim.has_active(), "a stale landing is ignored")
	sim._on_stats(stale, 1)
	check(sim.settle(w, 0.0, sim._flags).is_empty() and sim.is_active(w.tile_at(Vector2i(0, 0))), "a current landing counts")
	sim.drop(sim.active_tiles())
	# A flag on a slot with no resident tile is ignored.
	w._resident.clear()
	flags.fill(0); flags[3] = 1
	check(sim.settle(w, 0.0, flags).is_empty() and not sim.has_active(), "no tile, no activity")
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
```

Append to `test_hold_rule.gd` before `patch.free(); box.free(); ...` (reusing `terrain` and `patch`):

```gdscript
	# The collider throttle: the first touch goes at once; in-zone touches bake at most every edit interval; a
	# touch that would move the zone waits for the zone interval.
	terrain.params = WorldParams.new()
	terrain.tool_params = ToolParams.new()
	terrain.patch = patch
	patch._n_theta = terrain.params.n_theta()
	patch._pending = false
	terrain._collider_touch(Vector2i(100, 100), 2)
	terrain._flush_collider(10.0)
	check(patch.has_zone and patch.zone == Vector2i(100, 100) and patch._again_edit and patch._again_big, "first touch sets the zone at once")
	patch._again_edit = false; patch._again_big = false
	terrain._collider_touch(Vector2i(102, 100), 2)
	terrain._flush_collider(10.1)
	check(not patch._again_edit, "an in-zone touch waits for the edit interval")
	terrain._flush_collider(10.21)
	check(patch._again_edit and not patch._again_big and patch.zone == Vector2i(100, 100), "then the edit shape bakes, zone kept")
	patch._again_edit = false
	terrain._collider_touch(Vector2i(140, 100), 2)
	terrain._flush_collider(10.5)
	check(not patch._again_big and patch.zone == Vector2i(100, 100), "a zone move waits for the zone interval")
	terrain._flush_collider(11.01)
	check(patch._again_big and patch._again_edit and patch.zone == Vector2i(140, 100), "the zone moves after a second")
```

- [ ] **Step 2: Run them to verify they fail**

Run: `cd godot && godot --headless --path . --fixed-fps 60 --quit-after 7200 -s res://tests/test_terrain_sim.gd; godot --headless --path . --fixed-fps 60 --quit-after 7200 -s res://tests/test_hold_rule.gd`
Expected: `TerrainSim` not found; `_collider_touch` not found.

- [ ] **Step 3: Implement the simulation, the throttle and the `Terrain` wiring**

As in Interfaces. `settle` runs before the lists so a freshly settled tile is not stepped again before its pack; the pack lists go out from `Terrain._process` after `step`, in the same frame, so the render graph orders them after the last apply.

- [ ] **Step 4: Run the suite, then extend and run the driver**

Run: `cd godot && sh tests/run.sh`
Expected: all `PASS`.

`tool_run.gd` gains, after `stamps`, with `sim` the terrain's simulation and `_settled()` a helper that waits until `not sim.has_active()` and the pack readbacks of the site's tiles have landed (`edits.blobs` holds them and the blob's `loose` at the site's centre equals the window's), at most 10 s:

1. Phase `slump` at `S2` (`k = 2`): record the `sim` pass times and the active tile count per frame from here on. `terrain.set_obstacle(S2 + (0, 3), 1)` (a wall across the pile's +z side, cells +2 to +4), then deposit 30 m³ (`MODE_DEPOSIT`, radius 1: a 5.6 m column); wait `_settled()`, printing the settle time. Over `_box(S2, 24)`: the loose volume within 0.5 % of 30; the steepest slope among cells with loose > 0.01 toward any non-blocked neighbour (`(H_c − H_n) / w`, `w` across as the shader's mean width, 1 m along) at most `tan(35°) · 1.02`; `S2 − (0, 3)` holds loose above 0.01 m (the pile spread three cells on its open side); every cell within 1 of `S2 + (0, 3)` has loose below 1e-6 (the wall held); `sim.has_active()` false and `edits.blobs` has the tile with the pile's centre loose bitwise equal to the window's: `pile settles at repose against the mask, conserved, packed: ok`. Then `set_obstacle(TerrainSim.NO_CELL, −1)`, wait `_settled()`: the volume unchanged within 0.5 %, at least one of the former wall cells above 0.05 m, the steepest slope again within `tan(35°) · 1.02`: `mask lifts, the pile slumps on: ok`. Prints the `sim` list times per active tile for the phase (median, max; expected median under 0.1 ms per tile) and the active tile count's max (expected 1 or 2).
2. Phase `seam`: teleport to `θ = 0` on the spawn row (`await _settled_patch()`, the wait `edit_run._settled` does), deposit 20 m³ at cell `(0, row)` (radius 2); the sum over `_box((0, row), 24)` within 0.5 % of 20 after settling, tiles `(127, row / 128)` and `(0, row / 128)` were both seen active (poll `sim.active_tiles()` each frame): `seam pile: ok`.
3. Phase `ends`: teleport to `(spawn.x, −length / 2 + n_z − 4)`; `stamp_tool` of a radius-2 deposit at row `n_z − 2` returns false (its disc would leave the station); a 20 m³ deposit at row `n_z − 3` is accepted and, settled, holds its volume within 0.5 % over `_box(.., 24)` (rows clamped) with no `ERROR` line: `end rows: ok`. Teleport back to the spawn.
4. Phase `sheet` at `S3` (`k = −1`): a thin sheet runs downhill a cell a step until it soaks in, so water sums are whole-window deltas: read `sheet0 = _sum(water_depth)`, `sat0` and `absorbed0 = sim.absorbed`; `_wet_ever`, a per-texel flag, is set from a `water_depth` read every 0.5 s during the phase (a synchronous 1 MB read each; the summary marks the phase as carrying driver reads). Spill 2 m³ of water (`MODE_SPILL`, radius 2); after 3 s: cells with depth > 5 mm number at least 20; after `_settled()` (or 15 s): `(_sum(water_depth) − sheet0) + _pore(sat0, sat1, ..) + (sim.absorbed − absorbed0)` within 2 % of 2; every cell whose saturation rose is dirt-topped and within 3.05 m (cell centres, true widths) of a `_wet_ever` cell: `water spreads and soaks within 3 m: ok`. The 20-cell and 3 s figures are estimates from the rates: print the count seen; if the first run shows fewer, lower the threshold to what was seen less a margin and say so in the commit (the spread is what is proved, not the number).
5. The final `PASS`/`FAIL` as before.

Run: `cd godot && godot --rendering-driver vulkan --path . res://terrain/tool_run.tscn`
Expected: every `ok`, `PASS`, no `ERROR`; `sim` median under 0.1 ms per active tile, max under 0.25; the pile settles in under 5 s (an estimate from the 1/8 decay; print the time, and if it is longer, the plan's figure is what changes, not the rate).

Manual: `godot --path .`, hold `]` to raise a mound, then `[` into it from the side: the cut face of the raised dirt holds (it is solid), nothing slumps; the GPU overlay shows `sim` while a tile is active and `n/a` a second after. Then, with the pit still fresh (under a second after the last `[`, its tile active), quit with the window's close button: no `ERROR` line at exit (the exit pack ran a list and a synchronous readback during engine quit, the one path the drivers' in-process restart does not exercise); run again: the pit is there. Remove the test pit afterwards (`rm .../worlds/default/tiles/*.edit`, as in slice 2).

- [ ] **Step 5: Commit**

```bash
git add godot/terrain/terrain_sim.gd godot/terrain/shaders/sim.glsl godot/terrain/terrain.gd godot/terrain/timing_overlay.gd godot/terrain/tool_run.gd godot/tests/test_terrain_sim.gd godot/tests/test_hold_rule.gd
git commit -m "Terrain: simulation pass over active tiles (slump, sheet water, soak and wetting, transport), settle-and-pack, collider throttle"
```

---

### Task 4: Feet: `Player` signals, `Tools` node, push on movement, tamp on landing

**Files:**
- Modify: `godot/player.gd`, `godot/main.tscn`, `godot/terrain/tool_run.gd`
- Create: `godot/terrain/tools.gd`
- Test: `godot/tests/test_player.gd`, `godot/tests/test_tools.gd`

**Interfaces:**
- Consumes: Task 2's `EditLayer.Op`, `Terrain.stamp_tool`, `tools`, `materials`; `Cyl.theta_of`, `WorldParams.cell_of`.
- Produces:
  - `Player`: `signal stepped(floor_velocity: Vector3)` (every physics tick while `is_on_floor()` after `move_and_slide`, the velocity with its component along `up_direction` removed, global) and `signal landed(speed: float)` (the tick `is_on_floor()` turns true after at least `AIRBORNE_TICKS` consecutive ticks off the floor; `speed` is the downward speed along `up_direction` the body had before `move_and_slide`, at least 0). `const AIRBORNE_TICKS := 9` (0.15 s at 60 Hz: a 3 m/s jump is airborne about 0.6 s; the ground dropping a few centimetres under the feet when a throttled collider bake lands is caught within two or three ticks, so walking over a pile never counts as a landing). `var _airborne := 0` (ticks since the floor was last under the body).
  - `class_name Tools extends Node` (`tools.gd`): `@export var terrain: Terrain`, `@export var player: Player`; `var pushes := 0`, `var tamps := 0` (stamps made, for the driver). `_ready` connects the two signals. `_on_stepped(v)`: nothing under `terrain.tool_params.push_min_speed`; else `terrain.stamp_tool` of an `Op` with `cell = player_cell()`, `radius = foot_radius`, `mode = MODE_PUSH`, `amount = push_share`, `dir = push_dir(station-local v, theta)`, `limit = push_max`, `pack = false`; `pushes += 1` when accepted. `_on_landed(speed)`: at or above `tamp_land_speed`, an `Op` with `cell = player_cell()`, `radius = foot_radius`, `mode = MODE_TAMP`, `amount = tamp_step`, `limit = materials.swell_factor[0]`, `pack = false`; `tamps += 1` when accepted. `func player_cell() -> Vector2i` (the cell of the player's origin). `static func push_dir(v_local: Vector3, theta: float) -> Vector2i`: with `t = Vector3(cos(theta), sin(theta), 0)` (spinward), `dt = v.dot(t)`, `dz = v.z`: `Vector2i.ZERO` when both are under 1e-6, else `(sign(dt), 0)` when `|dt| >= |dz|`, else `(0, sign(dz))`.
  - `main.tscn`: `[node name="Tools" type="Node" parent="." node_paths=PackedStringArray("terrain", "player")]` with `script = tools.gd`, `terrain = NodePath("../Station/Terrain")`, `player = NodePath("../Station/Player")`, after `DebugEdit`.

- [ ] **Step 1: Write the failing tests**

In `test_player.gd`, before the `for i in 180` loop, connect the signals:

```gdscript
		var landings: Array[float] = []
		var steps: Array[Vector3] = []
		player.landed.connect(func(speed: float) -> void: landings.append(speed))
		player.stepped.connect(func(v: Vector3) -> void: steps.append(v))
```

and after the drift check:

```gdscript
		# The drop (about 0.45 s airborne, longer than AIRBORNE_TICKS) lands exactly once at a few m/s; any
		# settling contact after it is too short to count. Standing still, every step reports no floor speed.
		check(Player.AIRBORNE_TICKS == 9, "airborne ticks")
		check(landings.size() == 1 and landings[0] > 1.0 and landings[0] < 10.0, "landed once at %s" % [landings])
		check(not steps.is_empty() and steps.all(func(v: Vector3) -> bool: return v.length() < 0.05), "steps while standing %d" % steps.size())
```

Append to `test_tools.gd` before `if failed:`:

```gdscript
	# push_dir: the axis-quantised (theta, z) direction of a station-space velocity at angle theta.
	check(Tools.push_dir(Vector3(1, 0, 0), 0.0) == Vector2i(1, 0), "spinward at theta 0 is +x")
	check(Tools.push_dir(Vector3(0, 1, 0), 0.5 * PI) == Vector2i(1, 0), "spinward at theta pi/2 is +y")
	check(Tools.push_dir(Vector3(-1, 0, 0.5), 0.0) == Vector2i(-1, 0), "the larger component wins")
	check(Tools.push_dir(Vector3(0.2, 0, -1), 0.0) == Vector2i(0, -1), "axial")
	check(Tools.push_dir(Vector3.ZERO, 0.0) == Vector2i.ZERO, "no motion, no direction")
```

- [ ] **Step 2: Run them to verify they fail**

Run: `cd godot && godot --headless --path . --fixed-fps 60 --quit-after 7200 -s res://tests/test_player.gd; godot --headless --path . --fixed-fps 60 --quit-after 7200 -s res://tests/test_tools.gd`
Expected: `landed` not found; `Tools` not found.

- [ ] **Step 3: Implement the signals, `Tools` and the scene node**

As in Interfaces. `landed` and `stepped` are emitted after `move_and_slide`, from `_physics_process` (main thread, outside any readback), so the stamps they trigger may dispatch.

- [ ] **Step 4: Run the suite, then extend and run the driver**

Run: `cd godot && sh tests/run.sh`
Expected: all `PASS`.

`tool_run.gd` gains `_tools` (`main.get_node("Tools")`), `_face(dir_local: Vector3)` (sets `player.global_basis = station.global_basis * Basis(up.cross(-d), up, -d)` with `up = -station.down_at(player.global_position)` in station space and `d = dir_local`, as `_on_first_live` builds it) and `_press` from `edit_run`. Phases after `sheet`, at `S4` (`k = −2`):

1. `walk`: deposit 12 m³ (radius 2), wait `_settled()`; read `L0` over `_box(S4, 24)`; teleport the player to `S4 − (0, 8)` (8 m before the pile along −z), `_face(Vector3(0, 0, 1))`, wait 0.5 s, record `tamps0 = _tools.tamps`, hold `W` for 1.5 s, release, wait 2 s and `_settled()`. Every 0.1 s from the press to the release (15 synchronous reads of `surface` and `loose`; the summary marks the phase) sample the player's feet (origin minus 1 m along its up) against `surface + loose` at its cell and keep the minimum clearance. Read `L1`: `_tools.pushes >= 10`; `_tools.tamps == tamps0` (no landing was counted while walking over the pile: the collider catching up under the feet is not a jump); the loose volume unchanged within 0.5 %; the loose-weighted mean row grew by at least 0.1 cells; the minimum clearance over the walk is at least −0.3 m (the player crossed the pile on it, not in it, with the bake at most 0.2 s behind): `walking pushes forward, conserves, stands on it: ok`.
2. `jumps`: teleport the player onto the pile's highest cell (max `surface + loose` in the box), wait 1 s and `_settled()`, read `s0`, `L0`; press `SPACE` four times 1.2 s apart (`_press(KEY_SPACE, true)`, held three frames so a 60 Hz physics tick sees it, then `false`); wait 2 s after the fourth and `_settled()`; read `s1`, `L1`: `_tools.tamps >= 4`; `solid_gain = Σ (s1 − s0) · area(s0)` over the box is above 0.1 m³; `loose_lost = Σ (L0 − L1) · area(s0)`; `|solid_gain · 1.25 − loose_lost| <= 0.01 · loose_lost`; at least one cell has loose 0 and `s1 > s0`: `four landings fold the patch, volume accounted: ok`.

Run: `cd godot && godot --rendering-driver vulkan --path . res://terrain/tool_run.tscn`
Expected: every `ok`, `PASS`, no `ERROR`.

Manual: `godot --path .`, hold `]` for a second to make a mound, then walk into it: the far side rises a little as you cross; jump on the same spot four times: the dirt under you goes solid (flat, ground colour once Task 6 lands).

- [ ] **Step 5: Commit**

```bash
git add godot/player.gd godot/main.tscn godot/terrain/tools.gd godot/terrain/tool_run.gd godot/tests/test_player.gd godot/tests/test_tools.gd
git commit -m "Terrain: the player's feet push loose dirt while walking and tamp it on landing"
```

---

### Task 5: The auger: scene, placement and pickup on `E`, bore ticks, readback-driven deposits, stop at depth or rock, one at a time, pause out of window

**Files:**
- Create: `godot/terrain/auger.gd`, `godot/terrain/auger.tscn`
- Modify: `godot/terrain/tools.gd`, `godot/terrain/debug_edit.gd`, `godot/terrain/tool_run.gd`
- Test: `godot/tests/test_tools.gd`

**Interfaces:**
- Consumes: Task 2's `Op`, `stamp_tool`, `can_stamp`, `set_obstacle`, `tools`, `materials`; Task 3's `sim`; `ColliderPatch.tangent_frame`, `surface_point`, `covers`; `Terrain.height_at`; `NoiseReport.rock_site`.
- Produces:
  - `DebugEdit`: `static func look_hit(vp: Viewport, exclude: Array[RID]) -> Dictionary` (the crosshair ray of today's `_process`, `REACH` long, the hit dictionary or empty); `_process` uses it.
  - `auger.tscn`: `Auger` (`Node3D`, `auger.gd`) with `Mesh` (`MeshInstance3D`, `CylinderMesh` top and bottom radius 1, height 12, at `(0, -4, 0)`) and `Body` (`StaticBody3D`) holding a `CollisionShape3D` with a `CylinderShape3D` radius 1, height 12, at `(0, -4, 0)`.
  - `class_name Auger extends Node3D`: `signal stopped(reason: String)`; `var terrain: Terrain`, `cell: Vector2i`, `side: Vector2i`, `mode := "bore"` (follows the last landed tick: `"pump"` when it was wet, `"bore"` when dry; decision 5), `depth := 0.0` (m issued while the mode read bore), `running := true`, `stop_reason := ""`, `removed := 0.0` (m³ landed from the counter, dry ticks), `deposited := 0.0` (m³ of loose placed), `spilled := 0.0` (m³ of water placed), `ticks := 0`, `refused := 0`; `var _pending := 0.0`, `_pending_wet := false`, `_next_tick := 0` (ms). `func setup(t: Terrain, c: Vector2i, s: Vector2i, ground_h: float) -> void`: `transform = ColliderPatch.tangent_frame(theta_c, z_c, R)` with the origin raised to `Cyl.position(theta_c, z_c, ground_h, R)` (`theta_c`, `z_c` the cell's centre). `func spoil_cell() -> Vector2i` = `spoil_cell_of(cell, side, terrain.tool_params.spoil_offset, n_theta)`; `static func spoil_cell_of(cell: Vector2i, side: Vector2i, offset: int, n_theta: int) -> Vector2i` (θ wrapped). `static func stop_reason_for(depth: float, bore_depth: float, volume: float, wet: bool) -> String`: `""` when wet; `"rock"` when `volume <= 0`; `"depth"` when `depth >= bore_depth`; else `""`. `_process`: first, when `_pending > 0`: `stamp_tool` of an `Op` with `cell = spoil_cell()`, `radius = spoil_radius`, `mode = MODE_SPILL if _pending_wet else MODE_DEPOSIT`, `amount = _pending if _pending_wet else _pending · swell`, `pack = false`; when accepted, add to `spilled` or `deposited` and clear `_pending`. Then, when `running`, `Time.get_ticks_msec() >= _next_tick` and (`mode == "pump"` or `depth < bore_depth`): `_next_tick += 1000 / bore_rate` (first set at setup); when `terrain.can_stamp(cell, bore_radius) and terrain.can_stamp(spoil_cell(), spoil_radius)`: `stamp_tool` of an `Op` with `cell`, `radius = bore_radius`, `mode = MODE_BORE`, `amount = bore_step`, `limit = pump_rate / bore_rate`, `counted = _counted`, `pack = false`; `ticks += 1`, and when `mode == "bore"`: `depth += bore_step`; else `refused += 1` (paused). When `stop_reason` is set (by a landing) and `running`: `running = false`, `print("Auger stopped: " + stop_reason)`, `stopped.emit(stop_reason)`. `_counted(volume, wet)` (inside the readback flush: flags only): `_pending += volume`, `_pending_wet = wet`; `mode = "pump" if wet else "bore"`, `removed += volume` when dry; `stop_reason = stop_reason_for(depth, bore_depth, volume, wet)` when `running and stop_reason == ""`.
  - `Tools`: `var auger: Auger`; `const AUGER := preload("res://terrain/auger.tscn")`; `func place(theta: float, z: float, side: Vector2i) -> Auger` (null with a `print` when an auger exists or `terrain.can_stamp` fails for the bore or spoil cells; else instantiates, `setup` with `ground_h` from `patch.surface_point` when `patch.covers` the point else `height_at`, adds it under `terrain.station`, `terrain.set_obstacle(cell, bore_radius)`); `func pickup() -> void` (`set_obstacle(NO_CELL, −1)`, `queue_free`, `auger = null`); `_unhandled_input`: `E` pressed, not an echo, `terrain.viewer == player`: with an auger, pick it up when the player's origin is within `pickup_distance` of it (station space), else `print("Pick up the auger first")`; without one, `DebugEdit.look_hit` with the player excluded; a hit within `place_reach` of the player places with `side = push_dir(hit − player, theta_hit)` (both station-local), else `print("Nowhere to place the auger")`.

- [ ] **Step 1: Write the failing tests**

Append to `test_tools.gd` before `if failed:`:

```gdscript
	# The auger's stop rule and its spoil cell across the seam.
	check(Auger.stop_reason_for(0.5, 10.0, 0.02, false) == "" and Auger.stop_reason_for(10.0, 10.0, 0.02, false) == "depth", "boring on, then at depth")
	check(Auger.stop_reason_for(0.5, 10.0, 0.0, false) == "rock", "a dry tick that cut nothing is rock everywhere")
	check(Auger.stop_reason_for(20.0, 10.0, 0.0, true) == "", "a pump never stops")
	check(Auger.spoil_cell_of(Vector2i(16382, 7), Vector2i(1, 0), 7, 16384) == Vector2i(5, 7), "spoil cell wraps")
	check(Auger.spoil_cell_of(Vector2i(10, 9), Vector2i(0, -1), 7, 16384) == Vector2i(10, 2), "spoil cell along the axis")
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd godot && godot --headless --path . --fixed-fps 60 --quit-after 7200 -s res://tests/test_tools.gd`
Expected: `Auger` not found.

- [ ] **Step 3: Implement the auger, the key and the ray helper**

As in Interfaces.

- [ ] **Step 4: Run the suite, then extend and run the driver**

Run: `cd godot && sh tests/run.sh`
Expected: all `PASS`.

`tool_run.gd` gains, after `jumps` (the player back at the spawn, `_settled_patch()`), with `A = spawn_cell + Vector2i(6, 0)` and `side = Vector2i(1, 0)`:

1. `bore`: read `s0` over `_box(A, 24)`; `_tools.place(theta_A, z_A, side)` (not null); records `patch.baked("edit")` landings and zone moves per second from here; waits for `stopped` (at most 40 s) and `_settled()`: the reason is `"depth"`; `removed = _removed(s0, s1, the 5 bore cells)`; `auger.removed` within 0.1 % of it; `_vol(loose)` over the box within 0.5 % of `removed · 1.25` and of `auger.deposited`; the shaft cells have loose < 1e-6 and surface `s0 − 10 ± 0.05`; no cell within 2 cells of `A` (the shaft and its rim ring) holds loose above 0.01 m (the spoil does not reach the rim on its own, decision 6); the steepest loose slope (as in `slump`, excluding neighbours within 1 of `A`) at most `tan(35°) · 1.02`; `auger.refused == 0`: `bore to depth, spoil conserved and clear of the rim: ok`. Prints the bore's wall time, the edit-bake rate (landings per second over the bore: expected at most 5) and zone moves (expected 1).
2. `box`: a 1 m `box.tscn` (as `edit_run`) placed 2 m over the pile's highest cell; after 3 s: `linear_velocity` under 0.05 m/s, its lowest corner's clearance to the collider (`edit_run`'s `_corner_clearance`) within `[−0.05, 0.1]`, and its bottom within 0.1 m of `surface + loose` at its cell: `box rests on the pile: ok`. Free the box.
3. `pickup`: `_tools.pickup()`; wait 1 s: the shaft cells still hold loose < 1e-6 (nothing reaches the rim on its own) and `_tools.auger == null`; then `_op(A + (0, 2), 0, MODE_DEPOSIT, 2.0)` (a 1.9 m column on the cell beside the shaft cell `A + (0, 1)`, which the mask would have held while the auger stood), wait `_settled()`: the loose sum over the box is the earlier sum plus 2 within 0.5 % and at least one cell within 1 of `A` holds loose above 0.05 m (dirt pushed to the rim slumps into the open hole): `pickup opens the hole: ok`.
4. `pause`: `_tools.place` at `A + (0, 20)` with `side = (0, 1)` (not null), then `place` again at `A`: null, and `_tools.auger` is the first: `one auger at a time: ok`. After 1 s of boring, teleport the player 600 m spinward (`_settled_patch()`, 1 s): `auger.refused > 0` and `auger.ticks` stops growing; teleport back, wait 2 s: ticks grow again, no `ERROR`; `pickup()`: `pause and resume: ok`.
5. `rock`: teleport to `NoiseReport.rock_site(maps, params)` (`_settled_patch()`); read `s0` and `bedrock_top` over `_box(cell + (3, 0), 3)`; place an auger at the player's cell + (3, 0), side (1, 0); wait for `stopped` (at most 10 s: the window cell may carry up to a metre of cover over the macro's bare rock): reason `"rock"`, `auger.depth < bore_depth`, `auger.removed` within 0.1 % of `_removed(s0, s1, shaft cells)`, every shaft cell's surface at its `bedrock_top` within 1e-3: `rock floors the bore: ok`; `pickup()`; teleport back to the spawn.

Run: `cd godot && godot --rendering-driver vulkan --path . res://terrain/tool_run.tscn`
Expected: every `ok`, `PASS`, no `ERROR`; the bore takes 30 ± 2 s; the edit-bake rate over the bore at most 5 per second.

Manual: `godot --path .`, look at the ground 5 m ahead, press `E`: the cylinder stands there and dirt heaps beside it over half a minute, then "Auger stopped: depth" prints; walk into the heap and push it about; walk up to the auger and press `E`: it vanishes, the hole stays; press `E` again looking at a lake's shallows (ClickTeleport with Ctrl+click can get you there): water pours out beside it.

- [ ] **Step 5: Commit**

```bash
git add godot/terrain/auger.gd godot/terrain/auger.tscn godot/terrain/tools.gd godot/terrain/debug_edit.gd godot/terrain/tool_run.gd godot/tests/test_tools.gd
git commit -m "Terrain: the auger: placed and picked up on E, bores to depth or rock, deposits its spoil from the counter readback"
```

---

### Task 6: Rendering: the loose look, sheet water, the P dump

**Files:**
- Modify: `godot/terrain/shaders/cylinder_tile.gdshaderinc`, `godot/terrain/shaders/tile.gdshader`, `godot/terrain/shaders/water.gdshader`, `godot/terrain/terrain.gd` (`_material`), `godot/terrain/debug_window_dump.gd`, `godot/terrain/tool_run.gd`

**Interfaces:**
- Consumes: Task 1's `ground_of`, `loose_tex`.
- Produces:
  - `cylinder_tile.gdshaderinc`: `uniform sampler2D depth_tex : filter_nearest;` (`water_depth`). `tile.gdshader`: `uniform sampler2D saturation_tex : filter_nearest;`, varyings `loose_v`, `sat_v` (the vertex's texels); fragment: `bool pile = loose_v > 0.02;` `id = pile ? 0 : id;` `ALBEDO = material_color[id].rgb * (pile ? 0.75 : 1.0) * mix(1.0, 0.6, sat_v) * mix(0.55, 1.0, smoothstep(0.5, 1.0, up)) * mix(1.0, 0.7, wet) * (1.0 + (pile ? 0.3 : 0.08) * (hash(g) - 0.5))`; `ROUGHNESS = pile ? 1.0 : 0.95`. `water.gdshader`: `g = ground_of(k)`, `w = height_of(water_tex, k)`, `dd = height_of(depth_tex, k)`, `level = max(w > g ? w : -1e9, dd > 0.005 ? g + dd : -1e9)`, `depth = level > g ? level − g : −1.0`, the vertex at `level` when wet else `g − 1.0`; the fragment discards `depth <= 0.005`. `Terrain._material` sets `depth_tex` on both and `saturation_tex` on the ground.
  - `debug_window_dump.gd` reads `loose` and `water_depth`, tints a loose cell's colour toward `Color(0.3, 0.2, 0.1)` by half, and prints `loose %d cells, max %.2f m, %.1f m3; sheet %d cells, max %.3f m, %.2f m3` (volumes with the cell's true area).

- [ ] **Step 1: Make the changes**

No headless test reaches a shader; the driver's screenshots and the dump are the check.

- [ ] **Step 2: Extend and run the driver**

`tool_run.gd`: after `bore` (the auger still standing), tilt the camera down onto the pile (`_player.look(Vector2(0, 300))`), wait 6 frames, save `user://debug/tool_pile.png`; after `sheet`, the same at `S3` as `tool_puddle.png`; both phases also run the P dump (`debug_window_dump.gd` instantiated with `window` and `center` as `noise_report.gd` does, `_dump` on the render thread) and check its printed loose volume against `_vol(loose)` within 1 %.

Run: `cd godot && godot --rendering-driver vulkan --path . res://terrain/tool_run.tscn`
Expected: `PASS`; `tool_pile.png` shows a darker, rougher heap beside the cylinder on lighter ground; `tool_puddle.png` shows a sheet with darker dirt around it.

Manual: `godot --path .`, place an auger, watch the pile: it reads as loose dirt; four jumps on it leave ground-coloured dirt; press `P` with a pile in view: the dump line names its cells and volume.

- [ ] **Step 3: Run the suite**

Run: `cd godot && sh tests/run.sh`
Expected: all `PASS`.

- [ ] **Step 4: Commit**

```bash
git add godot/terrain/shaders/cylinder_tile.gdshaderinc godot/terrain/shaders/tile.gdshader godot/terrain/shaders/water.gdshader godot/terrain/terrain.gd godot/terrain/debug_window_dump.gd godot/terrain/tool_run.gd
git commit -m "Terrain: loose dirt drawn darker and rougher, sheet water drawn over the ground, loose and sheet in the P dump"
```

---

### Task 7: Pumping at a lake: the water proof

**Files:**
- Modify: `godot/terrain/tool_run.gd`; any fix the phase needs in `godot/terrain/shaders/sim.glsl`, `edit.glsl`, `auger.gd`

**Interfaces:**
- Consumes: Task 5's `Tools.place`, `Auger.spilled`, `mode`; Task 3's `TerrainSim.absorbed`; `MacroMaps.lakes` (`{theta, z, radius, level}`).
- Produces: the `pump` and `rock_spill` phases below and whatever they expose. No new interfaces.

- [ ] **Step 1: Write the phases**

`tool_run.gd`, after `pickup` and before `rock`:

1. `pump`: for the lakes of `maps.lakes` nearest the spawn first (at most five): teleport the player to `(lake.theta, lake.z + lake.radius + 6)` (`_settled_patch()`), read `water_surface` and `surface` along the player's column from the lake centre's row outward along +z and find `shore`, the first cell where `water_surface <= surface + 1e-3` after a wet run; accept the lake when the window's `material` is 0 for the four cells from `shore` to `shore + 3`; print the lake chosen, or, when none of the five qualifies, print each one's shore row and the four materials found and fail (the default world's banks have not been checked for this; the follow-ups carry the dependency). `A = (column, shore − 3)` (three cells into the water), `side = (0, 1)`: read `sat0` and `water_surface` (whole window) and start the `_wet_ever` sampling; `_tools.place(..)`; wait 10 s; `pickup()`; wait `_settled()` or 15 s; read again: `auger.mode == "pump"`; `pumped = auger.spilled` (at least 8 m³); whole-window `sheet = _sum(water_depth)`, `pore` as in the `sheet` phase, `absorbed = sim.absorbed − before`; `|sheet + pore + absorbed − pumped| <= 0.02 · pumped`; the `water_surface` texture is bitwise unchanged; at least one dirt cell's saturation rose; every risen cell is dirt-topped and within 3.05 m of a `_wet_ever` cell or a reservoir cell; the mean ground height of the cells holding sheet water at the end is at or below the spoil disc's mean ground (it ran downhill): `pumped water runs downhill, soaks dirt within 3 m, lake unchanged: ok`. Prints `pumped`, `sheet`, `pore`, `absorbed`.
2. `rock_spill`, inside the `rock` phase at the rock site, before its auger: spill 1 m³ at the player's cell + (0, 4) (bare rock: check its `material` is 2 or 3, else move along +z until it is); after 3 s: the `saturation` texture is bitwise unchanged, `sim.absorbed` unchanged and whole-window `_sum(water_depth)` within 2 % of 1 (the sheet runs over rock until the window's edge or a hollow stops it; nothing soaks): `rock does not soak: ok`.

- [ ] **Step 2: Run the driver**

Run: `cd godot && godot --rendering-driver vulkan --path . res://terrain/tool_run.tscn`
Expected: both new `ok` lines, `PASS`, no `ERROR`. If the water sum misses by more than 2 %, the first suspects are the reservoir test at the shore (a cell whose `water_surface` is a hair above the ground is a reservoir and absorbs) and the pump's `take` on a sheet cell; print the per-term figures before changing a rate.

- [ ] **Step 3: Run the suite**

Run: `cd godot && sh tests/run.sh`
Expected: all `PASS`.

- [ ] **Step 4: Commit**

```bash
git add godot/terrain/tool_run.gd godot/terrain/shaders/sim.glsl godot/terrain/shaders/edit.glsl godot/terrain/auger.gd
git commit -m "Terrain: tool run pumps at a lake shore; water sums (sheet, pore, absorbed) hold to 2 percent, rock stays dry"
```

---

### Task 8: Persistence: a pile and a puddle survive a scroll mid-slump and a restart mid-bore

**Files:**
- Modify: `godot/terrain/tool_run.gd`; `godot/terrain/terrain.gd` only if the phases find a gap

**Interfaces:**
- Consumes: Task 3's pack-before-evict and `pack_tiles_sync` at exit; `WorldIO.save`, `Terrain.world_name`, `persist_edits`; `DirAccess.copy_absolute`.
- Produces: the driver runs on the `tool_run` world from this task on: `_ready` copies `params.tres` and `maps.res` from `user://worlds/default` into `user://worlds/tool_run` when missing, removes every file under `user://worlds/tool_run/tiles`, and sets `_terrain.world_name = "tool_run"`, `persist_edits = true` before `add_child(main)`. `func _restart() -> void`: `main.queue_free()` (so `Terrain._exit_tree` packs and saves), two frames, instantiate `main.tscn` again with the same settings, rebind `_station`, `_terrain`, `_player`, `_tools`, the overlay's `timed`, wait for `collider_live` and a frame.

- [ ] **Step 1: Write the phases**

`tool_run.gd`, after `rock` (back at the spawn):

1. `scroll` at `S6` (`k = 3`): deposit 20 m³; wait 0.3 s (assert `sim.has_active()`); read `L0` over `_box(S6, 24)`; teleport 600 m spinward (`_settled_patch()`, 1 s): `not window.is_resident(tile of S6)`; teleport back (`_settled_patch()`): read `L1` at once: the volume within 0.1 % of `L0` (the pack at eviction, re-applied); wait `_settled()`: still within 0.5 % and at repose: `pile survives a scroll mid-slump: ok`. Also reads the whole-window water total (`sheet + Σ sat · capacity · area`, the `sheet` phase's puddle among it) before the teleport and after the return, the same wanted set both times: within 2 %.
2. `restart`: place an auger at `S7 = spawn_cell + (−6, 0)` with side `(−1, 0)`; wait 8 s (mid-bore); record `depth0 = auger.depth`, `s_hole0` at `S7`, `L0` over `_box(S7, 24)`, and the whole-window water total; `await _restart()`: `_terrain.window.edits.blobs.size() >= 3` (the tiles loaded from `tool_run/tiles`); `_tools.auger == null`; teleport to `S7` (`_settled_patch()`): `s_hole1` within `2 · bore_step` of `s_hole0`; `L1` within `0.3 m³ + 1 %` of `L0` (one tick's spoil at most); the water total within 2 % (the player spawns on the same tile as `S7`, so the wanted set is the same); `_settled()`: `restart mid-bore keeps the hole, the pile and the puddle: ok`.

- [ ] **Step 2: Run the driver**

Run: `cd godot && godot --rendering-driver vulkan --path . res://terrain/tool_run.tscn`
Expected: both `ok`, `PASS`, no `ERROR`; `user://worlds/tool_run/tiles` holds the edited tiles afterwards (the default world's `tiles/` untouched).

- [ ] **Step 3: Run the suite**

Run: `cd godot && sh tests/run.sh`
Expected: all `PASS`.

- [ ] **Step 4: Commit**

```bash
git add godot/terrain/tool_run.gd godot/terrain/terrain.gd
git commit -m "Terrain: tool run proves a pile and a puddle survive a scroll mid-slump and a restart mid-bore on a world copy"
```

---

### Task 9: Measurement summary, budgets, notes and follow-ups

**Files:**
- Modify: `godot/terrain/tool_run.gd`, `docs/terrain-research.md` (section 6.8, after the edit slice measurements), `docs/superpowers/plans/2026-10-27-terrain-edits-followups.md` (mark what this plan closed)
- Create: `docs/superpowers/plans/2026-10-28-terrain-slice-3-followups.md`

**Interfaces:**
- Consumes: the overlay's `timed`, `ColliderPatch.baked`, `TerrainSim.steps`, `active_tiles`, `viewport_get_measured_render_time_gpu`; `smoke_run.gd`'s `_stat`, `_pct`, `_mean`, `_times`.
- Produces: `tool_run.gd` prints a summary after its checks: machine and driver; per pass (`sim` per active tile, `edit`, `pack` per tile, `apply` per tile, `bake_edit`, `bake`, `detail` per tile) count, median, p90, max in ms and the count over budget (`sim` 0.25 per active tile per frame, computed as the frame's `sim` lists summed and divided by that frame's active count; `edit`, `pack`, `apply` 0.5; `bake_edit`, `bake` 1; `detail` 2); per phase (`slump`, `sheet`, `walk`, `jumps`, `bore`, `pump`, `scroll`) the active tile count mean and max, the frames with any active tile, the edit-bake landings per second and the zone moves, the frame interval mean, p99, max and the count over 16 ms, and the GPU frame mean and p99, with the number of the driver's own synchronous reads in that phase beside them (the `walk` clearance samples and the `_wet_ever` samples of `sheet` and `pump` are 1 MB stalls of the driver's making, so a frame-interval max in those phases is not the game's); a one-line trace of the active tile count sampled every 2 s of the bore; the conservation residuals of every phase in percent. Timing is reported, not asserted.

- [ ] **Step 1: Add the summary**

As in Interfaces, with `smoke_run.gd`'s static helpers.

- [ ] **Step 2: Run under both drivers, and the slice 2 drivers once more**

Run: `cd godot && godot --rendering-driver vulkan --path . res://terrain/tool_run.tscn`, then `godot --path . res://terrain/tool_run.tscn`, then `godot --rendering-driver vulkan --path . res://terrain/edit_run.tscn`, `godot --rendering-driver vulkan --path . res://terrain/bake_check.tscn`, `godot --path . res://terrain/smoke.tscn -- --blackout`, and `sh tests/run.sh`.
Expected: `PASS` everywhere; on Vulkan `sim` under 0.25 ms per active tile per frame at the median, at most 2 active tiles through the bore, edit bakes at most 5 per second and one zone move in the bore, GPU frame mean under 6 ms; on Metal GPU figures `n/a`, behaviour the same.

- [ ] **Step 3: Record the numbers and the follow-ups**

In `docs/terrain-research.md` section 6.8, after the edit slice block, add "Tools slice measurements, 2026-10-28" with the Vulkan table (passes with budgets, per-phase active tiles, bake rates, frames), the conservation residuals, one line on the Metal run, and the bore's wall time. In the edits follow-ups doc, add a line under each item this plan touched: the stamp radius in cells (still cells; the tools size their discs in cells), the stamped-tile-evicted limit (now packed before eviction), the request-failure guard if applied. New `2026-10-28-terrain-slice-3-followups.md`: tamping ignores wetness (decision 7); compaction of loose that slumps into a partly tamped cell keeps the destination's value; the collider follows the simulation only around the last tool stamp (decision 10), so loose carried far by water is drawn but not collided until something stamps there; `MAX_ACTIVE` eviction freezes a tile mid-motion at a 1024 window; the flux textures are window-sized (36 MB at 1024); sixty push lists a second while walking; `regenerate()` resets active tiles (decision 15); a stamp whose activity flag has not landed when a teleport evicts its tile in the next frame or two is neither packed before eviction nor by the stamp (the same two-frame class as slice 2's accepted limit); the water sheet has no sink and no velocity, so a thin sheet on a slope runs a cell a step (60 m/s) until it soaks in or meets a hollow or the window's edge, where the flux refusal parks it, and parked material does not resume when that neighbour tile later enters (no cell moves, so no neighbour bit) until something stamps there; pore water is `saturation · capacity` of the cell's top material, so loose carried onto or off clay changes the volume the same byte stands for (a drift inside the 2 % the dirt-bank checks allow); a lake does not wet its own banks (only standing sheet water soaks; the research's halo around every water body is a later slice); a quit loses the bore tick in flight; the lake test's shore search depends on the world's lakes having dirt banks; any budget miss measured.

- [ ] **Step 4: Commit**

```bash
git add godot/terrain/tool_run.gd docs/terrain-research.md docs/superpowers/plans/2026-10-27-terrain-edits-followups.md docs/superpowers/plans/2026-10-28-terrain-slice-3-followups.md
git commit -m "Terrain: tool run measurements, budgets and follow-ups for the next slice"
```
