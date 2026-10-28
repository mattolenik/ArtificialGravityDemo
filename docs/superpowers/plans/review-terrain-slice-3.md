# Review: Terrain slice 3 plan (2026-10-28-terrain-slice-3.md)

Reviewed against the approved spec (`docs/superpowers/specs/2026-10-28-terrain-slice-3-design.md`), the writing-plans method, and the code in this worktree (`godot/terrain/*.gd`, `shaders/*.glsl`, `player.gd`, `main.tscn`, `tests/*.gd`). Read-only; nothing was run (no claim about existing test output needed the suite).

## Verdict

**Ready with fixes.** No Critical defects. The architecture (two new fields on the slice 2 blob, stamp modes with a bore counter, a flux/apply simulation over GPU-flagged active tiles, settle-and-pack, a throttled collider) is sound and respects every binding engine fact. Eight Important defects would each make a task fail or need a small redesign during execution; all have one- or two-line fixes in the plan text. Counts: Critical 0, Important 8, Minor 17.

## Defects

### Important

**1. Lifting the obstacle mask re-activates nothing, so the `mask lifts` and `pickup` phases cannot pass.**
Plan lines 417 (`set_obstacle(TerrainSim.NO_CELL, −1)`, wait `_settled()`: "at least one of the former wall cells above 0.05 m") and 562 (`pickup`: "at least one cell within 1 of A above 0.05 m (the rim slumped into the open hole)"). Both phases first wait `_settled()` (line 415: `not sim.has_active()`), which packs and drops the tile. `set_obstacle` (line 176, 313) only stores `sim.obstacle`; decision 3 (line 40) makes activity come solely from GPU flags, and nothing on the GPU runs on a dropped tile. The pile held against the wall or the shaft rim stays as a cliff forever until a stamp touches that tile. Fix: `Terrain.set_obstacle` activates the tiles of `EditLayer.stamp_tiles(window, old_cell, old_radius + 1)` on the CPU (`sim.activate(tiles)`: quiet 0, resident only) when it clears or moves an obstacle; add the method to `TerrainSim`'s Interfaces and a line to `test_terrain_sim.gd`.

**2. The apply pass (mode 2) does not flag, so a tile evicted mid-slump comes back frozen; the `scroll` phase's "at repose" fails.**
Line 171 says `flag(t)` is "called by every mode that changes a cell, mode 0 included"; apply is a copy and is not listed, and nothing on the CPU activates entering tiles (line 313's `_move_window` only packs and drops the leaving ones). Line 666 deposits 20 m³, teleports away 0.3 s later (far from settled), returns, and asserts "wait `_settled()`: still within 0.5 % and at repose". With the pile re-applied bitwise and no flag, `_settled()` returns at once and the slope is the frozen mid-slump one. Review Focus 3 (line 74) is exactly this case. Fix: in `edit.glsl` mode 2, `flag(t)` when the applied cell has `loose > 0` or `water_depth > 0` (not for every masked cell, or every edited tile that enters would be stepped for a second and re-packed). Note it in decision 3.

**3. The apply pass stores only when `moved` (> `move_eps`), which breaks the conservation claim.**
Lines 307–308: `moved = |L2 − L| > move_eps || ...; if moved: store L2, d2, q2`. A sender with four outflows of 5e-5 m changes by 2e-4 (stored, loses it) while each receiver changes by 5e-5 (not stored, never gets it): mass is destroyed; the mirror case creates it. The settling tail of a geometric decay (decision 2's 1/8 per step) sits in this regime for ~10 steps per cell, so a pile leaks of order 0.1 % while settling — against the `scroll` phase's 0.1 % (line 666) and decision 2's "conserved to float rounding" (line 39). Fix: store (and set mask 1) when `L2 != L || d2 != d || q2 != q`; use `move_eps` only for the activity flag and the neighbour bit. Then the claim holds to float rounding, and untouched cells are still not masked.

**4. Every push stamp touches the collider, so plain walking drives an edit bake 5×/s and a zone move (a 2.7 ms Jolt build and a new NaN hole under the player) every second, on bare ground with nothing to push.**
Line 176: `stamp_tool` records `_last_tool` and touches the collider for every accepted op; line 448: `_on_stepped` stamps a `MODE_PUSH` every physics tick at ≥ 0.5 m/s; line 313: the throttle fires at the zone interval whenever the touch leaves the zone. The GPU refuses pushes over `loose == 0` (line 174: `out = 0`, nothing stored, no flag), but the CPU does not know that. Compare `collider_patch.gd:183-188` (a zone move always punches a new hole) and the slice 2 measurements (`2026-10-27-terrain-edits-followups.md:27`, 2.7 ms per big bake). The spec reserves "one 2.7 ms hitch per second" for water carrying dirt away (spec line 84), not for walking; `smoke_run`'s 60 s legs would pick up 60 zone moves and 300 edit bakes that slice 2 did not have. Fix: push ops do not touch the collider directly; the sim's per-frame re-touch of `_last_tool` (decision 10) covers a push that actually moved loose, three frames later. Keep the direct touch for bore, deposit, spill and tamp (they always change cells). State it in decision 10 and line 176.

**5. The bore counter's landing can call a freed auger: an `ERROR` line in the `pickup` and `pause` phases, intermittently.**
Line 168: `_counted(data, cb)` calls `cb.call(...)` unconditionally; line 529: `pickup()` does `queue_free`. A tick's readback lands up to two frames after the tick (`collider_patch.gd:268-270` describes the flush), and `pickup()` runs right after `stopped`/after 1 s of boring (lines 562–563), so one tick in three to six has a readback in flight at the free. Calling a `Callable` on a freed `Node` prints an error, and every phase asserts "no `ERROR` line". Fix: `_counted` returns when `not cb.is_valid()` (false once the object is freed); one line, say so at line 168.

**6. Pushing from under the player's own feet against a 5 Hz collider produces spurious landings ≥ 2 m/s, so walking slowly over a pile tamps it.**
Lines 448–449: a push moves `min(0.05 · loose, 0.03)` m per footprint cell per physics tick; line 313: the edit shape rebakes at most every 0.2 s. A player on a 1 m pile at 1 m/s stays ~60 ticks on a cell; in one 0.2 s bake interval the ground under them drops up to 12 × 3 cm = 36 cm. When the bake lands the capsule (`player.tscn`, radius 0.5, `floor_snap_length` default 0.1) goes airborne and lands at √(2·9.8·0.36) ≈ 2.65 m/s > `tamp_land_speed` 2 (line 44), which is `landed` by line 447's rule, so `_on_landed` tamps; four such stutters fold the cell. The spec ties tamping to "repeated jumping" (spec line 48) and bans "a pile the player ... gets launched by" (spec line 30). Fix: emit `landed` only after at least N airborne ticks (a 3 m/s jump is ~0.6 s airborne; 0.15 s excludes the collider catch-up), or push only into the cell ahead and not from the cells under the capsule; add the airborne-ticks rule to `test_player.gd`'s expectations (the drop at the start is long enough).

**7. The spoil disc at 5 cells contradicts the spec's "does not reach the rim on its own", and the plan knows it.**
Decision 6 (line 43): "a 35° cone of 4.5 m base radius, which reaches the rim: while the auger stands the obstacle mask holds it off the shaft; after pickup the rim slumps into the hole". Spec line 70, a "my call", binding: "the spoil disc is centred about 4 m from the axis, so a full bore's spoil ... does not reach the rim on its own". The difference comes from the bore disc: `disc_cells(1)` is a 5-cell plus (≈5.4 m² at `(R − h)·Δθ ≈ 1.07 m` across, `world_params.gd:467-468,495-496`) against the spec's π m² circle, so the plan removes 54 m³ where the spec assumed 32. Either `spoil_offset = 7` (the cone's near edge at 2.5 m clears the rim at 1.5; the `pickup` phase then needs a push toward the rim before asserting a slump, or must drop that assertion), or get the user's explicit acceptance of the deviation and say so in decision 6. The follow-ups line (line 709) already lists it, which is not the same as the user deciding it.

**8. The `stamps` phase's spill assertion breaks from Task 3 on, once the simulation runs.**
Line 248: spill 0.5 m³ at `S1 + (0, 10)`, read "three frames after", `_vol(water_depth)` within 0.1 % (over an unnamed box; `_box(S1, 6)` from item 1 does not even contain the spill disc's far cells). The spill flags its tile (line 173), so from Task 3 the sheet flows a cell per step and soaks a quantum every 6 steps (`0.2 / 255` m, line 46): within three frames (up to six steps) water leaves the box and up to 2 % of a 4 cm sheet soaks in. `tool_run` is one driver re-run in full at every task (line 243 onward), so Tasks 3–9 inherit a failing `spill conserves`. Fix: make the check whole-window, `_sum(water_depth) + pore` within 2 % (the `sheet` phase's sums, line 420), and name the box for the deposit, push and tamp checks (`_box(S1, 6)` holds them: a 0.1 m layer is below repose, so nothing slumps).

### Minor

**9.** Line 42: "a tick's cell 4,000" units is wrong by ~10×: a 1/30 m cut on a 1.07 m² cell is 0.036 m³ = 36,000 units; harmless (a full bore is 5.4e7, a uint holds 4.3e9), but fix the comment. Also compute the annulus as `cut · (2(R − s) − cut)` rather than `(R − s')² − (R − s)²`: at R − s ≈ 2800 the float32 squares have an ulp of 0.5 against a difference of 187, 0.27 % per term (averages out over a bore, but the product form is exact to 1e-7 for free).

**10.** Lines 247 and 500: "`Σ (s_after − s_before) · area`" does not say which surface's area; with `area(s_before)` the identity against `loose_volume / 1.25` is exact, with `s_after` it is off by `Δs / (R − s)` (0.03 % for a 1 m fold, inside the tolerance but say which). Line 247's "the loose volume before the fourth" must be over the tamp disc only: the pushes of item 2 moved loose outside the radius-2 disc, and that loose does not fold.

**11.** Lines 174–175: "store when it changed; mask 1; flag" reads as unconditional mask and flag; both must be inside the "changed" branch, or a push over bare ground masks and activates the tile every tick (decision 3's own rationale).

**12.** Line 667 (`restart`): "the hole's shaft has loose < 1e-6 (nothing poured in: the obstacle is gone with the prop, so the pile may slump in; allow it, assert only the sum)" asserts and un-asserts the same thing. Drop the `< 1e-6` clause.

**13.** Line 274 (`settle`): flags land two frames late and are keyed by slot; after `_move_window` a landed flag for an evicted tile activates whatever tile now sits in that slot, which is then stepped for a second and packed, producing an all-zero 524 KB blob in RAM and on disk per slot (up to 16 per teleport, 8 MB). Tag `_on_stats` landings with the window's move count and ignore stale ones, or skip packing a tile whose blob would be all-zero mask.

**14.** Line 313: one touch slot (`_touch_cell`). The auger's bore (at its cell) and the feet's push (at the player's) overwrite each other each frame; a kept out-of-zone touch waiting for the zone interval can be replaced by an in-zone one and lost until the sim re-touches. Harmless with the single `_last_tool` re-touch, but say the slot is "last touch wins" so the implementer does not build a queue.

**15.** Line 499 (`walk`): the player ends 7–12 m past the pile at `run_speed` 15 m/s, so "feet within 0.3 m of ground" is checked on flat ground and does not pin Review Focus 3's "stand on it, not in it". Record the minimum clearance to `surface + loose` at the player's cell over the phase (as `edit_run.gd:110-114` does with `_low`) and assert ≥ −0.3.

**16.** Lines 420, 631: `_wet_ever` is sampled every 0.5 s with a synchronous whole-texture read plus a 262k-texel GDScript loop (~100 ms stall), inside the `sheet` and `pump` phases whose frame intervals Task 9 (line 696) reports. Either exclude those frames or note that the driver's own reads produce the hitches.

**17.** Line 44: `foot_radius 1` is a 5-cell plus about 1.1–1.5 m in radius; the spec says "a disc of about 0.5 m radius" (spec line 74). Say in decision 7 that the footprint is one cell wider than the spec's number and why (a radius-0 push has a single source cell).

**18.** Line 528: an auger set on a puddle pumps the 5-cell footprint dry in one tick (`take = min(depth · area, share)`) and the next tick's centre cell reads dry, so it bores. The spec (line 80) says "for as long as it stands there". State the rule (pump while standing water or a reservoir is under the centre; bore otherwise) in decision 5 so the implementer does not guess.

**19.** Decision 4 (line 41) replaces the spec's "Stamps ... go through `EditLayer.stamp`, so they pack their tiles back as today" (spec line 84) with settle-pack, pack-before-evict and exit-pack. Equivalent in effect, but one new hole: a stamp in frame N whose activity flag has not landed by a teleport in frame N+1 is neither active (not packed before eviction) nor packed by the stamp. Two frames, same class as slice 2's accepted limit; add it to the follow-ups list (line 709).

**20.** Line 709: "a thin sheet ... runs ... until it meets ... the window's edge, where the flux refusal parks it" should add that parked material never resumes when the neighbour tile later becomes resident (no cell moves, so no neighbour bit), until something stamps there.

**21.** Line 274: the fixed-step accumulator should be clamped to `MAX_STEPS · STEP` (an idle stretch must not bank steps); one word in the Interfaces.

**22.** Naming: `Terrain.tools: ToolParams` (line 176) and `class_name Tools extends Node` (line 448), so `Tools.terrain.tools.push_share` and the driver's `_tools` (the node) sit next to `tools` (the params). Rename the resource property `tool_params` or the node `Hands`/`ToolUse`.

**23.** Line 305: the pore-water volume is `q · capacity[top material] / 255`; when a cell's top changes (loose carried onto clay or off it) the same `q` becomes a different volume and the water sum drifts. Within 2 % on the dirt banks the driver chooses, but note it as a known inaccuracy in the follow-ups.

**24.** Line 39: "1/8 per step ... cannot overshoot (each pair's difference shrinks by at most a quarter per step)" is false in general: a source drops by the sum of its four outflows and a sink rises by the sum of its four inflows, so a pair's difference can shrink by up to the largest excess around it and invert when a tall column sits beside a gentle slope. It settles (the outflow is a fraction of the excess over repose, so the scheme is a damped diffusion), but state the stability argument correctly: bounded by `4 · slump_rate ≤ 1/2` of the largest excess per step, never negative loose.

**25.** Line 167: `Op(S1, spoil_radius, MODE_DEPOSIT, amount = 1.5)` and friends are shorthand; `Op` has no constructor. Give the driver a `_op(cell, radius, mode, amount, dir, limit)` helper in Task 2's Interfaces so the phases' text is unambiguous.

## Spec coverage (question 1)

Every goal, every "user decided" item and every "my call" maps to a task: the auger (Task 5), loose dirt as a layer with mass (Tasks 1–3), push and tamp (Task 4), pumping, sheet flow, pooling, bounded wetting, transport (Tasks 3, 7), persistence through scroll and restart (Task 8), flat cost (Task 3, measured in Task 9). The obstacle mask while the auger stands (lines 171, 283, 529), one auger (line 529), no prop persistence (line 528, 667), the pump outlet onto the spoil side (line 528), reservoirs absorbing and sourcing (lines 172, 303), capacity `porosity × 0.5 m` (line 44, `soak_column`), lateral wetting moving quanta rather than creating them (lines 288–289, 304), water sums to 2 % (lines 420, 631), zone moves ≤ 1 Hz and edit shape ≤ 5 Hz (line 44, 313, tested at 374–399), the simulation under 0.25 ms per active tile with at most 16 (lines 274, 696) are all present. Every "left to the builder" item is decided with an alternative and a reason (decisions 2–11). Contradictions: the spoil disc (defect 7) and the letter of "pack their tiles back as today" (defect 19).

## Mass conservation (question 2)

Deposit and spill: `t = (amount / N) / area(s)` per disc cell, N = `disc_cells(radius)`, every cell resident by `can_stamp`: exact. Push: a gather, `out(x)` identical in the sender's and receiver's invocations, the receiver converts by `area(s_{c−dir}) / area(s_c)`, the receiver of every disc cell lies in the box of `radius + 1`: exact. Tamp: `s += loose / swell` is the swell applied once both ways: exact with `area(s_before)`. Bore: the annulus is exact in float64 on the CPU side; the GPU's float32 squares cancel (defect 9) but the bore-long sum passes 0.1 %. Simulation: volumes are written by the source with its area and divided by the receiver's area; symmetric send/receive conditions (`texel && active`, `blocked` only on the receiving side and then the flux is zero): conserving except for the `moved` gate (defect 3). Reservoir absorption is a counted sink; the pump on a reservoir is a counted source (`auger.spilled`). The driver reads whole textures synchronously at phase boundaries (1 MB each, a GPU stall each, acceptable in a driver) and sums in float64 with the same area convention the shaders use. The counter: `buffer_clear` before the list, `buffer_get_data_async` after `compute_list_end`, `_counted` → `Auger._counted` sets `_pending`, `mode`, `stop_reason` only; the deposit goes out from the next `_process`. Safe under the readback rules, with defect 5's guard.

## The flux scheme (question 3)

No cell is written by two threads (flux writes its own texel; apply writes its own fields and reads neighbours' flux; a barrier between the two groups; one list per step). Stability: see defect 24 for the correct bound; settling is geometric at ≥ 1/8 per step on the excess, so a tile goes quiet below `move_eps` in a few seconds. The obstacle mask is honoured on the receiving side in the flux and in the push; blocked cells may send (they hold nothing). Tile edge: outflow toward an inactive tile is refused; the neighbour is flagged only by a cell that `moved` on the edge, which is how material arrives there, so no stall in practice (a radius-0 stamp on an edge cell over ground sloping only into the inactive tile is the one stall case, and no tool makes it). No leak and no oscillation: a refused pair simply waits two frames. The seam: `texel()` wraps `d` and `n.x` is wrapped (lines 283, edit.glsl:50-58), the stamp flags both tiles, both slot bits are in the mask. End rows: `texel()` rejects `c.y < 0` and `ty ≥ slots` (which is `c.y ≥ n_z` when the wanted origin is clamped), `can_stamp` refuses a disc that leaves the station, the `ends` phase pins it.

## Cross-task contracts (question 4)

Blob version 2: `CELL_BYTES 32`, `loose` at +24, `water_depth` at +28, eight uints per cell at `(j·128 + i)·8`, mask at uint 5 (edit.glsl:96-129 today uses 6 uints; the plan's offsets are consistent across `edit.glsl`, `EditLayer.decode`, `upgrade_v1`, `WorldIO` and the test, which also checks the saved header `2, BLOB_SIZE`). `FIELDS` 9 and 10 → `edit.glsl` bindings 11, 12 (2 + index), `detail.glsl` set 1 bindings 9, 10, `sim.glsl` 0..10 in `FIELDS` order, `collider_bake.glsl` binding 3 (free: `o_patch` is 2), the tile and water shaders as samplers: consistent. `ToolParams` fields: every name used in Tasks 2–5 and the driver appears in decision 7 and `test_tools.gd`. Push constants: `edit.glsl` 96 bytes and `sim.glsl` 112 bytes are valid std430 (ivec2 at 8-aligned offsets, float arrays with stride 4, totals multiples of 16) and the two tests decode the offsets the plan lists. `tiles_generated`/`_dispatch`: unchanged; activity comes from flags (defect 2 fills the apply gap).

## Collider (question 5)

`surface + loose` reaches the bake through `collider_bake.glsl`'s `surface()` for resident cells and therefore `surface_point`, `center_height`, `teleport` and `_on_live` (`collider_patch.gd:137-144, 260-282`); the macro fallback outside the window carries no loose, which is right since loose exists only in the window. The throttle sits in `Terrain` and still calls `patch.on_edit` from `_process` before `issue_again` (line 313), so `on_edit → issue_again → _issued_zone → landings set flags` is untouched (`collider_patch.gd:183-216`); `test_hold_rule.gd`'s new block is consistent with `zone_holds`' reach of 16 for radius 2. The hold rule reads only the big patch's extent (`terrain.gd:214-216`), so a pile cannot hold the player. A bore beside the player: only the five shaft cells drop, the prop's static body stands in them; the 0.8 m strip of a shaft cell outside the radius-1 cylinder is a 10 m heightfield wall the capsule can slide down, which is the slice 2 follow-ups' open-pit limit, not a new defect. Defects 4 and 6 are the real collider risks.

## Feet (question 6)

Implementable from `player.gd:45-65`: `is_on_floor()` after `move_and_slide`, `_was_on_floor`, `up_direction` set each tick, the downward speed is `-velocity.dot(up_direction)` before the call. The feedback loop exists (defect 6).

## Auger (question 7)

Placement, `E` (no conflict: `FlyCamera` polls `KEY_E` in `_process`, `fly_camera.gd:75`, and the plan ignores `E` while it is the viewer), the 10 Hz tick with `_next_tick`, the readback-driven deposit, the stop rule (tested), pause by refusal and resume, the spoil cell across the seam (tested) are all specified. Underspecified: the pump-then-dry rule (minor 18), `ground_h` from `surface_point` needs `Cyl.height_of` (obvious), and the freed-auger landing (defect 5).

## Writing-plans rules (question 8)

Header, Global Constraints, Decisions with alternatives, File Structure, five Review Focus items each pinned to a task, tasks with Files/Interfaces/steps/commit, tests with exact assertions: all present. The plan (716 lines) is about a third of the code it describes and the only full body is `sim.glsl`'s algorithm, which the signature does not determine. Windowed checks print and quit; `tool_run` grows to ~2 minutes by Task 8, which is long but self-quitting. Ambiguities an implementer would have to resolve: minors 10, 11, 25.

## Budgets and measurement (question 9)

Every budget is measured by the driver on Vulkan through the overlay's `timed` pairs (`sim` per active tile per frame, `edit`, `pack`, `apply`, `bake_edit`, `bake`, `detail`), the frame GPU time through `viewport_get_measured_render_time_gpu`, bake rates through `ColliderPatch.baked`; nothing is asserted on timing; the Metal run is behaviour only with `n/a` figures. Nothing is measured that cannot be. Minor 16 is the one caveat.

## Strengths

- The flux/apply split with volumes on the true cell areas, the same area convention in the stamps, the shaders and the driver, and the reservoir counted as a source and a sink: the conservation story is coherent end to end.
- The bore counter (8 bytes, cleared before the list, read after it, landing sets state only) is the smallest possible answer to "deposit exactly what was removed" and also decides wet or dry.
- GPU-flagged activity with a CPU quiet timer, the neighbour bit across tile edges, pack-before-evict and a synchronous pack at exit cover every way a tile can leave.
- The collider throttle lives in `Terrain` and leaves `ColliderPatch`'s issue order byte for byte as it is; the headless test of the throttle is exact.
- The driver runs on a copy of the default world and restarts the terrain in-process, so the restart proof is real and the default world is never touched.
- Every "left to the builder" item is decided with the alternative and the reason, and the push-constant layouts are pinned by headless tests before any shader is compiled.

## Could not verify

- That `buffer_get_data_async` copies `_down` before the next pack list in the same callback reuses the slots (line 169, `pack_tiles` with more than four tiles). The render graph tracks the buffer's copy-from usage so the order should hold, but no code on this branch does it yet.
- That a compute list plus a synchronous `buffer_get_data` can run from `_exit_tree` at application quit (line 313, `pack_tiles_sync`). It works when a driver frees `main.tscn`; the engine-quit path is unexercised.
- The `sheet` phase's "at least 20 cells with depth > 5 mm after 3 s" (line 420) and "the pile settles in under 5 s" (line 424): both depend on the spawn's slope and the chosen rates; the geometric-decay argument makes 2–4 s plausible.
- The `pump` phase's shore search (line 631) depends on the default world having a lake with four dirt cells beyond its shore on the chosen column; the plan already names this in the follow-ups.
- Whether Jolt's heightfield update at 5 Hz under a walking player flickers `is_on_floor` beyond the drop case in defect 6.
