# Terrain slice 3: follow-ups

What the slice 3 plan (`2026-10-28-terrain-slice-3.md`: the auger, loose dirt, tamping and spilled water) left open on purpose, so the next slice's brief can pick it up. Nothing here blocks boring, piling, walking over a pile, tamping it or pumping a puddle, nor their surviving a scroll and a restart. What this plan did to the edits slice's items is marked in `2026-10-27-terrain-edits-followups.md`; the measurements are in `docs/terrain-research.md` section 6.8, "Tools slice measurements".

## Carry into the next slice's brief

- **Tamping ignores wetness** (decision 7). A tamp adds `tamp_step` to a loose cell's compaction whatever its saturation; how wet loose dirt tamps is the spec's refinement for later.
- **Loose that slumps into a partly tamped cell keeps the destination's compaction.** The flux moves volume, not compaction, so fresh loose arriving on a cell tamped to 0.75 folds with it at the next tamp.
- **The collider follows the simulation only around the last tool stamp** (decision 10). While that stamp's tile is active the zone is re-touched every frame; loose carried far by water, or a pile slumping in a tile no tool touched last, is drawn but not collided until something stamps there.
- **`MAX_ACTIVE` eviction freezes a tile mid-motion** (decision 3). At 512 the window is 16 tiles, the cap; at a 1024 window (64 tiles) the quietest active tile beyond 16 is packed and dropped mid-slump and moves again only when touched.
- **The flux textures are window-sized**: 4 + 4 + 1 MB at 512, 36 MB at 1024 (decision 14), plus `flux_loose_d` (below), though only active tiles use them.
- **Sixty push lists a second while walking** (decision 12), each a 5 × 5 box: a fixed per-list cost every frame the player walks, pile or not.
- **`regenerate()` resets active tiles to their last pack** (decision 15). A debug path (noise tuning), not handled, and not yet said in `TerrainWindow.regenerate`'s comment.
- **A stamp whose activity flag has not landed when a teleport evicts its tile** in the next frame or two is neither packed before eviction (only active tiles are) nor by the stamp (the tools leave packing to the settle pack). The same two-frame class as slice 2's accepted limit.
- **The water sheet has no sink and no velocity.** A thin sheet on a slope runs a cell a step (60 m/s) until it soaks in, meets a hollow or reaches the window's edge, where the flux refusal parks it. Parked material does not resume when that neighbour tile later enters the window (no cell moves, so no neighbour bit) until something stamps there.
- **Pore water is `saturation · capacity` of the cell's top material**, so loose carried onto or off clay changes the volume the same byte stands for (dirt 0.2 m, clay 0.25 m of water at saturation): a drift inside the 2 % the water checks allow.
- **A lake does not wet its own banks.** Only standing sheet water soaks; the research's halo around every water body (`docs/terrain-research.md` 6.4) is a later slice.
- **A quit loses the bore tick in flight**: the shaft keeps the cut, but its counter readback never lands, so that tick's spoil (about 0.2 m³) is not deposited.
- **The pump phase's shore search depends on the world's lakes having dirt banks**: `tool_run`'s `_lake_shore` tries the five lakes nearest the spawn and fails the phase if none has four dirt cells past its shore.
- **Budget misses measured** (`docs/terrain-research.md` 6.8, "Tools slice measurements"; reported, not asserted). `tool_run.tscn` on Vulkan, final run: 493 of 5932 frames (8.3 %) over the `sim` budget of 0.25 ms per active tile, the worst 2.8 ms (4.4 in an earlier run), against a median of 0.102 ms that is mostly the list's fixed cost; 17 of 1210 edit lists over 0.5 ms (the worst 1.77 ms); 2 bake_edit and 1 bake list over 1 ms (the worst 1.92 and 1.63 ms); the GPU frame p99 6.19 ms in the scroll (6.11 to 6.79 ms in slump, sheet, jumps and bore in an earlier run; the means 3.1 to 3.7, so the 6 ms mean budget holds). `edit_run.tscn` on Vulkan: 2 standing and 10 walking edit lists over 0.5 ms (the worst 1.74), 1 walking bake_edit over 1 ms (1.12); in an earlier run 2 of 14 big bakes over the 4 ms hitch budget in `map_data` CPU (max 6.44 ms; 3.88 in the final run, against slice 2's 2.80). `bake_check.tscn`: one of three big bakes at 1.75 ms GPU against 1 ms in an earlier run. Frame intervals over 16 ms: 3 to 22 per phase on Vulkan (missed refreshes, not traced), 13 to 159 on Metal, whose mean is 8.9 to 10.0 ms against Vulkan's 8.5 to 8.7; `edit_run` has 1 in its dig and 4 in its trench, where slice 2 had none.
- **The pack time is reported per list, not per tile.** Pairing the pack lists with their tile counts failed: the driver's synchronous reads, which begin as a tile settles, likely stall the frames whose timestamps carry the settle packs (17 timed against 29 counted as issued from the active set's changes, in the first run). A pack list holds one to four tiles, so its time bounds the per-tile one; a per-tile figure needs the tile count carried with the timestamp or the reads moved off those frames.

## Found during execution

Simulation and activity:
- Changed by the final runs (ruling 14): `TerrainSim.step` asks for the stats readback only in a frame that ran a simulation list or after a stamp or an apply (`EditLayer.stats_pending`), no longer every frame; and `TerrainSim.stalled()` (a readback unanswered for over 10 process frames, which happens only while no frame is drawn) stops the feet's pushes and tamps (`tools.gd`). `smoke.tscn -- --blackout` had printed 722 timestamp-overflow ERROR lines (a timed push list every physics tick into a GPU frame that never turned over), a fence timeout and a 140 ms resume frame (some 280,000 idle readbacks queued); now none, in two runs. The hold rule could not gate the feet: the player walks 124 m on the patch for 8.5 s before it is held, and a held player emits no `stepped` or `landed` anyway. Since gated too: a standing auger neither ticks nor deposits while `stalled()` (`auger.gd`; it had kept issuing ten timed lists a second, enough to overflow the 256 timestamps in about 13 s; not run against a blackout, the smoke places no auger). Still open: a tile active at the stall's onset keeps issuing its timed `sim` lists, each with a stats readback, for `settle_time` (about 60 lists) until it settles for want of landings; bounded, but not gated.
- The `sim` list has a fixed cost of about 0.085 ms per list under MoltenVK (a 16-tile bench: about 0.03 ms per tile plus that), so at one active tile the per-tile figure sits near the 0.25 ms budget at p90; folding a frame's two steps into one list would halve the fixed part (`terrain_sim.gd`).
- A tile that settles within the readback latency just before a quit has its async settle pack land after `_save_edits`, and the exit pack skips it (`terrain.gd` `_exit_tree`); track packs in flight in `EditLayer` and include them in the exit pack. Not seen in the restart phase.
- A stamp issued after `Terrain._process` on a tile the next frame's move evicts rides the move-frame readback and activates the entering tile; and pack-before-evict sees only `_active`, so an evicted tile whose flag landed but has not been settled is not packed. Both need a stamp about 256 m from the player; closable by issuing the stats readback at the old generation inside `invalidate` (about 4 lines, one 260 B readback per move) (`terrain_sim.gd`).
- The sheet phase's 3.05 m wetting check depends on the 0.5 s wet sampling (the true reach is about 2 m by quanta; 2.27 to 2.93 m measured); sample every frame or mark wet cells on the GPU (`tool_run.gd`).
- The timing overlay keeps the last `sim` time instead of showing n/a a second after activity ends (`timing_overlay.gd`, pre-existing behaviour).
- `TerrainSim._params` rebuilds the active mask and the 112-byte block for every dispatch (up to 32 per step); build them once per step (`terrain_sim.gd`).
- Settled piles have faces of about 37° between the axis and diagonal directions: the eight-neighbour slump holds 35° on the eight directions only (`sim.glsl`).
- The second flux texture `flux_loose_d` adds 4 MB at 512 (16 MB at 1024) to decision 14's memory figures (`terrain_sim.gd`).

Stamps:
- Changed by the final runs (ruling 13): a tamp no longer touches the collider directly (`Terrain.stamp_tool`). Decision 10 assumed tamps always change cells, but a landing on bare ground changes nothing, and it sent an edit bake and moved the zone (a 2.7 ms big bake) after the spawn, every teleport and every jump on plain ground; it took `bake_check.tscn`'s test hole away during its box drop. A tamp that changes a pile flags its tile, and the re-touch follows it as it follows a push.
- The one-workgroup limit of the bore and push `barrier()` (reach at most 3) is enforced only by an `assert` in `stamp_op`, stripped in release builds; `can_stamp` or `stamp_tool` should refuse larger reaches (`edit_layer.gd`, `terrain.gd`).
- A tamp `Op` with `limit` left at 0 divides by zero in the shader and raises the cell to `h_max`; guard `limit > 0` or clamp the divisor (`edit.glsl`).
- The bore's centre read `texel(pc.cell, tc)` skips the θ wrap, safe only because `cell_of` wraps; use `at(ivec2(0))` (`edit.glsl`).
- The bore counter counts `dh`, not the float32-stored cut: a +0.024 % bias, about 1.3e-3 m³ per 10 m bore (`edit.glsl`).
- The scoop's solid cut has the same float32 bias (about -0.04 % per scoop near 410 m, growing with height).
- `disc_cells` runs for every stamp, raise (121 iterations per debug dig) and push (every frame while walking) included; compute it only for bore, deposit and spill (`edit_layer.gd`).
- `_counted` has no `data.size() == 8` guard; `pack_tiles_sync` stalls once per slot rather than once per list (`edit_layer.gd`).

Auger and controls:
- `_pending_wet` is the last landing's flag, so a dry and a wet landing in one frame at the bore-to-pump transition misfile one tick (about 0.2 m³) (`auger.gd`).
- A pickup mid-bore discards the spoil of ticks still in flight and any undeposited `_pending` (`auger.gd`).
- `E` reads `keycode` while the fly camera and `DebugEdit` read physical keys; use `physical_keycode` (`tools.gd`).
- `place` accepts a placement under the player (the cylinder spawns through the capsule); needs a 1.5 m minimum distance (`tools.gd`).
- The cell-centre formula is duplicated in `auger.gd`, `tools.gd` and `tool_run.gd`; add `WorldParams.cell_center(c)`.
- The shovel's held scoop is not saved across a restart; a scoop on a cell under sheet water leaves the water in place (`tools.gd`, `edit.glsl`).
- A wet scoop leaves the cell's moisture behind and the dump is dry.
- A scoop or dump does not test the standing auger's obstacle, so a dump can drop loose into its shaft.
- A scoop whose counter readback never lands (only on a broken device, which already logs an ERROR) leaves `T` stuck pending.
Player:
- `floor_snap_length` is now 0.3 (was 0.1) so a 15 m/s runner stays on 35° to 40° descents (a 0.1 snap left a pile's shoulder); a feel change the user may tune (`player.tscn`).
- The walk phase's clearance check samples cell-centre heights 0.1 s apart (±0.35 m on a 35° slope); interpolate bilinearly if it flakes (`tool_run.gd`).

Rendering and debug:
- `P` is not wired in `main.tscn`; the window dump is reachable only from `debug_window`, `noise_report` and `tool_run`.
- The dump's `sheet N cells` counts any depth above 0, while the shader draws sheets above 5 mm (`debug_window_dump.gd`).
- Nothing asserts that the puddle screenshot holds a sheet (a hand-tuned 4 s delay in `tool_run.gd`'s sheet phase).

Drivers:
- The pump phase's downhill check counts the spoil disc's own cells among the sheet-holding cells, and its 3.05 m wetting test is nearly implied by geometry at the default world's only qualifying lake (the spoil sits 4 rows past the shore) (`tool_run.gd`).
- `_rock_spill`'s all-rock disc test ignores `loose > 0.01`: a loose-covered rock cell would make the site soak and fail the run, never pass it wrongly (`tool_run.gd`).
- The `tool_run` world copy keeps a stale `maps.res` if the default world is regenerated (delete `user://worlds/tool_run` then); the in-process restart frees `EditLayer`, `TerrainSim` and `ColliderPatch` with readbacks in flight (dropped silently in every run so far, timing dependent) (`tool_run.gd`).
- The 8-corner clearance loop is duplicated between `edit_run.gd` and `tool_run.gd`.
- Test coverage gaps: `test_terrain_sim` covers neither `invalidate` zeroing landed flags nor OR against overwrite; `test_edit_layer` checks neither a version 2 file of the old size nor a version 3 file; the `stepped` and `landed` thresholds are exercised only by `tool_run`; the skip warning in `world_io.gd` names version 2 even for a wrong-sized version 1 file.
