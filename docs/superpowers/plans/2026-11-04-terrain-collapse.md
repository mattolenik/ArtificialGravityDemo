# Terrain collapse and pillars: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A roof over a hollow fails by the span rule and falls as a chimney until its debris or the surface stops it; the player places pillars that hold roofs up; the shells of a thin skin over a hollow go.

**Architecture:** Everything runs in the voxel box of the tunnels project. The span rule is a new block in `box_sand.glsl`'s flux pass per active brick, mirroring the cave-in's failure bookkeeping with the loose going down instead of up. A pillar is a fifth material and a gap with that material byte in the column form; `box_edit.glsl` gains a column op that places or takes one; the pack and unpack carry it. The drivers prove the rest.

**Tech Stack:** Godot 4.7.2, GDScript, GLSL compute on the main RenderingDevice, Jolt. Headless tests under `godot/tests`, GPU drivers through `godot/tests/offscreen.sh` on Vulkan.

**Spec:** `docs/superpowers/specs/2026-11-04-terrain-collapse-design.md` (the tunnels design, `2026-11-03-terrain-tunnels-design.md`, is its base).

## Global Constraints

- Godot 4.7.2 standard build; GDScript + GLSL compute on the main RenderingDevice; Jolt; no GDExtension. Nothing dispatches GPU work or does file I/O inside a readback callback.
- 1 m cells and voxels, heights radial from the hull, station-local (θ, z); window fields and version 3 blobs unchanged in layout (the gap material byte is already stored).
- Budgets: the box's step under 0.25 ms per active brick; a remesh under 0.5 ms a chunk; a chunk landing under 2 ms CPU.
- Material numbers come from `godot/terrain/materials.tres`; the free height and the roof span are one number, `roof_span_dry` / `roof_span_saturated`; dirt's dry value becomes 5 m.
- Work on `terrain`, on a branch in this checkout (`collapse`), never on `main`; nothing is pushed.
- Headless tests cannot create a RenderingDevice; GPU behaviour is proven by drivers through `sh tests/offscreen.sh <scene> </abs/log>` with `DRIVER=vulkan`, one GPU run at a time across sessions (`pgrep -f 'Godot --path'` finds another; wait for it). `tests/offscreen.sh` imports first; after a shader edit run `godot --headless --path . --import` before any parse check that loads the box.
- A change to `box_column.glslh` does not reimport the shaders including it (`box_pack.glsl`, `box_unpack.glsl`, `box_sand.glsl`, `box_edit.glsl`): touch them.
- Every driver check that passes today keeps passing (`box_run.tscn` all phases, `tool_run.tscn`, `edit_run.tscn`), with the expectations this plan changes and no other.

## Review Focus

1. A roof voxel in the box's outermost column or layer: its support disc reaches outside the box; the reads clamp to the box's edge and the edge counts as support, so a tunnel dug to the box's edge does not fall at the edge (Task 4's test `test_span_edge`).
2. A chimney that climbs to the box's ceiling (24 m over the feet): the layer above the box is never judged, the chimney stops there, and the column packs as it is; nothing is lost (Task 5's `roof` phase sums the volume; Task 4 documents the stop).
3. A wet roof: the saturation byte mixes the span toward the saturated value, so a roof that stood dry fails wet (Task 4's test `test_span_reach_saturation`).
4. A pillar in a column whose gaps overflow: the pack's merge never turns the pillar into loose (Task 2's test `test_pillar_overflow_merge`).
5. `P` aimed at a floor with no roof within the span, at rock, or at the player's own cell: a printed refusal and nothing placed (Task 3's driver step and `test_pillar_range`).

---

### Task 1: The fifth material and the 5 m free height

**Files:**
- Modify: `godot/terrain/material_set.gd` (every array gains a fifth entry, `pillar`)
- Modify: `godot/terrain/materials.tres` (the same; `roof_span_dry[0]` 4 → 5)
- Modify: `godot/terrain/voxel_box.gd:78` (`MATERIALS_BYTES`), `material_table()` (five rows), a new `const PILLAR := 4`
- Modify: `godot/terrain/voxel_column.gd` (`const PILLAR := 4` beside `ROCK`)
- Modify: `godot/terrain/shaders/box_sand.glsl` (the `Materials` block's arrays `[5]`; `mt_[y_top] >= 2u` stays, rock and pillar never fail)
- Modify: `godot/terrain/shaders/chunk.gdshader` and `godot/terrain/shaders/tile.gdshader` (`material_color[5]`, the id clamps to 4)
- Modify: `godot/terrain/box_run.gd` (the cave phase: the second pit's target depth and report against `free + 1.0` and `free`; the header's "4 m" and "5 m" lines)
- Test: `godot/tests/test_tools.gd` (the materials check)

**Interfaces:**
- Produces: `VoxelBox.PILLAR == 4`, `VoxelColumn.PILLAR == 4`; `MaterialSet` rows: dirt, clay, rock, rock_face, pillar; `materials.tres` row 4: color `Color(0.36, 0.26, 0.16)`, porosity 0, wetting_distance 0, swell_factor 1.0, repose 40/40/40, roof_span 20/20, stable_slope 90/90, compression_index 0.005; `roof_span_dry = [5, 6, 20, 20, 20]`; `VoxelBox.MATERIALS_BYTES == 100` with the block laid out `stand_dry[5], stand_sat[5], swell[5], free_dry[5], free_sat[5]` at byte offsets 0, 20, 40, 60, 80.

- [ ] **Step 1: Write the failing test** in `tests/test_tools.gd`, next to the existing materials check:

```gdscript
check(m.names.size() == 5 and m.names[4] == "pillar" and m.swell_factor[4] == 1.0 and m.roof_span_dry[0] == 5.0 and m.roof_span_dry[4] == 20.0 and m.stable_slope_dry[4] == 90.0, "the fifth material and dirt's 5 m free height")
check(VoxelBox.PILLAR == 4 and VoxelColumn.PILLAR == 4 and VoxelBox.MATERIALS_BYTES == 100, "the pillar's id and the table's size")
```

- [ ] **Step 2: Run it** `godot --headless --path . -s res://tests/test_tools.gd` — Expected: FAIL on "the fifth material" (the arrays hold four).
- [ ] **Step 3: Implement**: the five-entry arrays in `material_set.gd` and `materials.tres`; `PILLAR` in both scripts; `MATERIALS_BYTES := 100` and `material_table()` writing five rows at the offsets above; `float ...[5]` in `box_sand.glsl`'s block; `material_color[5]` and `clamp(..., 0, 4)` in both shaders; the cave phase's `depth2 > free` and its dig loop's target `free + 1.0`, with the header lines reading "the 5 m free height".
- [ ] **Step 4: Run** `godot --headless --path . --import` then `sh tests/run.sh` — Expected: 22 PASS.
- [ ] **Step 5: Run the cave phase** `BOX_PHASE=cave DRIVER=vulkan sh tests/offscreen.sh res://terrain/box_run.tscn /abs/log` — Expected: PASS, both cave checks ok with the pit under 5 m keeping its walls and the one over caving.
- [ ] **Step 6: Commit** `git commit -am "Terrain collapse: the pillar material and dirt's 5 m free height"`.

### Task 2: A pillar's stored form

**Files:**
- Modify: `godot/terrain/shaders/box_column.glslh` (`Col` gains `int gm[4]`, read from `w_gap_material0..3`; `column_voxels` fills a gap whose material is `PILLAR` with solid `ONE` voxels of material `PILLAR` from `ceil(bottom)` to `floor(top) - 1`, the partial ends as the unpack treats a run's ends)
- Modify: `godot/terrain/shaders/box_pack.glsl` (a run of pillar voxels is pushed with a material flag; the gap writer emits it as a gap with material 4, bottom and top its own; `drop_run_1` skips a pillar run and drops the lowest dirt run between gaps instead)
- Modify: `godot/terrain/shaders/box_unpack.glsl` (touched for the include)
- Modify: `godot/terrain/voxel_column.gd` (`unpack` makes pillar voxels from a pillar gap; `pack` writes a pillar run as a gap with `gap_material == PILLAR`; the overflow merge skips it)
- Test: `godot/tests/test_voxel_column.gd`

**Interfaces:**
- Consumes: `VoxelColumn.PILLAR` (Task 1).
- Produces: a column Dictionary whose `gap_material[g] == VoxelColumn.PILLAR` unpacks to voxels with `material == PILLAR` and `solid == FRACTION_ONE` over the gap's whole voxels; `pack` round-trips it; the GPU pack and unpack do the same (proven by the `pillar` driver phase in Task 5).

- [ ] **Step 1: Write the failing tests** in `tests/test_voxel_column.gd`:

```gdscript
# test_pillar_round_trip: a gap 402..405 with the pillar material unpacks to pillar voxels and packs back exactly.
var post := col(410.0); post.gap_bottom[0] = 402.0; post.gap_top[0] = 405.0; post.gap_material[0] = VoxelColumn.PILLAR
var pv := VoxelColumn.unpack(post, 380, 40)
check(pv.material[22] == VoxelColumn.PILLAR and pv.solid[22] == VoxelColumn.FRACTION_ONE and pv.material[24] == VoxelColumn.PILLAR and pv.solid[21] == VoxelColumn.FRACTION_ONE and pv.material[21] == 0 and pv.solid[25] == VoxelColumn.FRACTION_ONE and pv.material[25] == 0, "a pillar gap is three pillar voxels between dirt")
var pb := VoxelColumn.pack(pv, 380, post)
check(pb.gap_bottom[0] == 402.0 and pb.gap_top[0] == 405.0 and pb.gap_material[0] == VoxelColumn.PILLAR and pb.surface == 410.0, "the pillar packs back as its gap")
# test_pillar_overflow_merge: five gaps, the second a pillar: the merge drops a dirt sliver, never the pillar.
```

(Write the overflow case with `col()` holding four air gaps and a pillar gap between the two lowest; after `pack(unpack(...))` the pillar gap is still present with its material and the loose gained equals the dropped dirt sliver's volume by the swell.)

- [ ] **Step 2: Run it** — Expected: FAIL on "a pillar gap is three pillar voxels" (the unpack makes air).
- [ ] **Step 3: Implement** the CPU reference in `voxel_column.gd`, then the GLSL in `box_column.glslh` and `box_pack.glsl` to the same rule; touch the four includers.
- [ ] **Step 4: Run** `godot --headless --path . --import` then `sh tests/run.sh` — Expected: 22 PASS.
- [ ] **Step 5: Run the unpack phase** `BOX_PHASE=unpack DRIVER=vulkan sh tests/offscreen.sh res://terrain/box_run.tscn /abs/log` — Expected: PASS (the GPU voxels still equal the CPU rule's).
- [ ] **Step 6: Commit** `git commit -am "Terrain collapse: a pillar is a gap with the pillar material, on the CPU and the GPU"`.

### Task 3: Placing and taking a pillar

**Files:**
- Modify: `godot/terrain/shaders/box_edit.glsl` (mode 6 `pillar_column`: over the op's one column and its range, if any voxel holds material `PILLAR` set those to air and count them negative; else find the lowest voxel over the highest voxel holding loose or solid at or under `pc.centre.z` and fill upward every voxel with `fs == 0u` until a voxel with `fs > 0u` within the range, as solid `ONE` of material `PILLAR`, counting them; no roof found within the range: count 0 and change nothing; the counter carries the signed count)
- Modify: `godot/terrain/voxel_box.gd` (`const EDIT_PILLAR := 6`; `func pillar(p: Vector3, reach: float, counted: Callable) -> bool`: a `_disc_op`-shaped dispatch over one column from the voxel of `p`'s height to `reach` over it, `counted(count: float, _flag)` landing with the signed voxel count)
- Modify: `godot/terrain/tools.gd` (`P`: `shovel_hit()`; the hit's cell within a cell of the player's cell refused with "Too close to stand a pillar"; `terrain.box.pillar(hit.position, terrain.materials.roof_span_dry[0] + 1.0, _pillared)`; `_pillared` prints "A pillar of %d m" / "The pillar taken away" / "Nothing to hold up there", and touches the collider around the cell; a counter `pillars` for the drivers)
- Test: `godot/tests/test_tools.gd` (`test_pillar_range`: the static `Tools.pillar_range(hit_h: float, reach: float) -> Vector2i` returns the voxel span `[floori(hit_h), floori(hit_h + reach)]`)

**Interfaces:**
- Consumes: `VoxelBox.PILLAR`, the material row (Task 1); the pack's pillar gap (Task 2).
- Produces: `VoxelBox.pillar(p, reach, counted)`; `Tools.pillars: int` (placed minus taken); the drivers call `_tools.place_pillar(cell: Vector2i)`, a thin wrapper at the cell's collider point.

- [ ] **Step 1: Write the failing test** in `tests/test_tools.gd`: `check(Tools.pillar_range(402.3, 6.0) == Vector2i(402, 408), "a pillar's voxel range")`.
- [ ] **Step 2: Run it** — Expected: FAIL (no such function).
- [ ] **Step 3: Implement** the op, the box method, the key and the wrapper.
- [ ] **Step 4: Run** `godot --headless --path . --import` then `sh tests/run.sh` — Expected: 22 PASS.
- [ ] **Step 5: Driver step**: in Task 5's `pillar` phase (write its first half now): after the tunnel is dug, `_tools.place_pillar(c + Vector2i(0, 4))`, wait a frame, read the column (`_column_vox(_stack(cell), cell)`): the voxels between the floor's and the roof's partials hold `material == 4` and `solid == FRACTION_ONE`; the pack after `_settled` gives `gap_material0 == 4` at that cell (`_read("gap_material0")`); a second `place_pillar` at the same cell takes it away (the column's voxels air again, the gap's material 0); `place_pillar` on open ground prints the refusal and counts 0. Run `BOX_PHASE=pillar`.
- [ ] **Step 6: Commit** `git commit -am "Terrain collapse: P stands a pillar on a tunnel's floor under its roof, or takes it away"`.

### Task 4: The span rule

**Files:**
- Modify: `godot/terrain/shaders/box_sand.glsl` (after the slope-stability block in `flux_column`: for each voxel y of the column with `fs[y] >= ONE / 4 && mt_[y] < 2u` and the voxel under it (in the brick, or `solid_of` below) under `ONE / 4` of solid: the thickness `t` = the solid in the voxels from y up to the first with `fs < ONE / 4`, in metres, each voxel's `fs / ONE`, capped at 1; `R = 0.5 * mix(mt.free_dry[m], mt.free_sat[m], sat) * t`; the support disc: the voxels of the layer under y within `ceil(R)` cells along θ and z whose centre lies within R (the θ distance scaled by `(R_hull − h) dtheta`), read through `find`/the index as the slump reads neighbours, outside the box counting as support; `support = fs + fl >= ONE / 2 || material == PILLAR`; the nearest support's distance d and direction; the second support within R in the half-disc opposite; `fails = none || (!second && d > R / 2)`; on failure `cut = min(slump_rate * fs, ...)` as the stability block bounds its cut, the gain `cut * swell` into this voxel's room (half at most) and the room of the voxel under it (through `send` to y − 1, a quarter of that room at most, as the block does upward), the `out` high half carrying `cut`)
- Modify: `godot/terrain/voxel_box.gd` (static `roof_reach(span_dry: float, span_sat: float, sat: float, thickness: float) -> float` and static `span_fails(nearest: float, opposite: float, reach: float) -> bool` with `INF` for none, the CPU reference of the rule's arithmetic)
- Test: `godot/tests/test_voxel_box.gd`

**Interfaces:**
- Consumes: the material table's five rows (Task 1), the pillar material as support (Task 2).
- Produces: a roof that fails under the rule in the running box; the two statics for the tests and the drivers.

- [ ] **Step 1: Write the failing tests** in `tests/test_voxel_box.gd`:

```gdscript
# test_span_reach: dry dirt, a roof a voxel thick reaches 2.5 m; half a voxel, 1.25; saturated, 0.75; over a voxel caps at 2.5.
check(VoxelBox.roof_reach(5.0, 1.5, 0.0, 1.0) == 2.5 and VoxelBox.roof_reach(5.0, 1.5, 0.0, 0.5) == 1.25 and VoxelBox.roof_reach(5.0, 1.5, 1.0, 1.0) == 0.75 and VoxelBox.roof_reach(5.0, 1.5, 0.0, 2.0) == 2.5, "the reach")
# test_span_rule: a 3 m tunnel holds, a 6 m room fails, a cantilever fails past a quarter span and holds within it, nothing within reach fails.
check(not VoxelBox.span_fails(1.5, 1.5, 2.5) and VoxelBox.span_fails(3.0, 3.0, 2.5) and VoxelBox.span_fails(2.0, 4.0, 2.5) and not VoxelBox.span_fails(1.0, 4.0, 2.5) and VoxelBox.span_fails(INF, INF, 2.5), "the span rule")
# test_span_reach_saturation: the saturated mix makes a dry 3 m tunnel fail: reach 0.75 at sat 1.
check(VoxelBox.span_fails(1.5, 1.5, VoxelBox.roof_reach(5.0, 1.5, 1.0, 1.0)), "a wet roof over a 3 m tunnel fails")
# test_span_edge: a support outside the box counts: INF on one side with the edge on it is the edge's distance.
check(not VoxelBox.span_fails(1.0, 1.0, 2.5), "the box's edge is a support")
```

- [ ] **Step 2: Run it** — Expected: FAIL (no such statics).
- [ ] **Step 3: Implement** the statics, then the GLSL block to the same rule.
- [ ] **Step 4: Run** `godot --headless --path . --import` then `sh tests/run.sh` — Expected: 22 PASS.
- [ ] **Step 5: Run the tunnel and the shell phases** (`BOX_PHASE=tunnel`, then `BOX_PHASE=shell`) — Expected: the tunnel phase PASS with its pit dug to five scoops (Task 5 moves the pit; run after Task 5 if the pit is still 3.5 m); the shell phase's crumb count printed.
- [ ] **Step 6: Commit** `git commit -am "Terrain collapse: the span rule in the sand step, a roof failing by the nearest support in a disc with a cantilever clause"`.

### Task 5: The drivers

**Files:**
- Modify: `godot/terrain/box_run.gd` (a `_pit(c: Vector2i, depth: float) -> float` helper lifted from the tunnel phase's pit loop, used by tunnel, roof and pillar; the tunnel phase's pit to `4.2` m; the play phase's pit cap to five scoops and its comments; the `shell` phase asserting no crumb deeper than 1.0 m once settled; the `roof` and `pillar` phases; the header)
- Modify: `godot/terrain/box_run.gd`'s phase dictionary and list (`roof`, `pillar` after `shell`)

**Interfaces:**
- Consumes: `_tools.place_pillar(cell)` (Task 3); the span rule (Task 4); `_scoop_at`, `_settled`, `_read`, `_vol`, `_gap_loose`, `_swelled_loss`, `_chunk_landed`, `_stack`/`_column_vox` as the existing phases use them.
- Produces: the phases below, each a `_report`.

- [ ] **Step 1: The `roof` phase** at a flat site in the middle of a chunk 160 cells past the spawn: `_pit(c, 4.2)` (five scoops), the player into the pit, seven balls at `aim(0.5, 1.5 + 0.5 k, 1.5)` as the tunnel phase digs; wait 10 s after `_settled`: the surface over the tunnel's cells (rows 2..5, both columns) unchanged and the gap tops there unchanged within 0.05 m, the loose over those cells under 0.05 m³ ("a 3 m tunnel under a roof over a voxel thick holds"); then widen to 6 m: balls at `aim(-1.0, d, 1.5)` and `aim(2.0, d, 1.5)` for d in 2.0..4.0 step 0.5; within 10 s the gap tops over the room's middle column rise by at least 0.9 m (the roof layer fell) while the surface there is unchanged ("a 6 m room loses its roof and keeps a dome"); then widen to 8 m: balls at `aim(-2.0, ...)` and `aim(3.0, ...)`; within 20 s the surface over the room's middle sinks by at least 1.0 m and the loose over the room's cells (surface and gaps) equals the solid lost (`_swelled_loss` over the room's box) within 0.1 % ("a room too wide climbs to a sinkhole, conserved").
- [ ] **Step 2: The `pillar` phase**: the same pit and tunnel; `place_pillar` at the tunnel's middle cell (row 3.5 → `c + Vector2i(0, 3)`) before widening to 6 m; after 10 s the gap tops over the room unchanged within 0.05 m ("a pillar holds a 6 m room"); `place_pillar` there again (taken away); within 10 s the gap tops over the middle rise by at least 0.9 m ("the roof falls when the pillar goes"). The pillar's stored form from Task 3's step 5 stays in this phase.
- [ ] **Step 3: Run** `BOX_PHASE=roof`, `BOX_PHASE=pillar`, `BOX_PHASE=shell`, `BOX_PHASE=play`, `BOX_PHASE=tunnel` on Vulkan — Expected: each PASS.
- [ ] **Step 4: Run the full drivers**: `box_run.tscn`, `tool_run.tscn`, `edit_run.tscn` — Expected: PASS each; the step's GPU time per active brick printed under 0.25 ms.
- [ ] **Step 5: Commit** `git commit -am "Terrain collapse: the roof, pillar and shell phases of the box run; the pits dug to five scoops"`.

### Task 6: Notes

**Files:**
- Modify: `docs/terrain-research.md` (a paragraph after the tunnels' figures: the collapse project's rules as built, the step's cost with roof voxels counted, the sinkhole figures)
- Modify: `docs/superpowers/plans/2026-10-28-terrain-slice-3-followups.md` (the shells' entry closed by the span rule; a new section "After the collapse project" with what is left: connectivity, beams, rock debris, the free height's feel at 5 m)
- Modify: `docs/superpowers/specs/2026-11-04-terrain-collapse-design.md` (its status line: built, the drivers' figures)

- [ ] **Step 1: Write them** from the drivers' logs.
- [ ] **Step 2: Commit** `git commit -am "Terrain collapse: notes and figures"`.
