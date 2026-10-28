# Review of the three terrain-edit plans (A, B, C)

Reviewed 2026-10-27 against the checkout at `c6240c7` (branch `terrain`), Godot 4.7.2.stable, and the Godot `4.7` branch sources. Evidence is cited as `file:line` in this repo, as `src:file:line` for engine sources downloaded to `/tmp/plan-probe/src/`, or as a probe result from a throwaway headless project in `/tmp/plan-probe/proj/` (no project file was touched, nothing ran windowed). Written to /tmp because the checkout refused the write.

Plans: `docs/superpowers/plans/2026-10-27-terrain-edits-A.md`, `-B.md`, `-C.md`. Brief: `docs/superpowers/plans/2026-10-27-terrain-slice-1-followups.md` R1, R3, R4–R7, topsoil, bake occupancy, second patch.

Summary: **execute C**, after fixing one ordering hazard in its collider task and its topsoil test, with four small transplants (A's `--blackout` smoke route, A's autosave, B's `test_material_set`, and rock's colour for material 3). A is the runner-up: its bake rewrite and GPU-truth storage are sound, but its snapshot machinery is the most code of the three and its in-place rebake measures 2.9–4.0 ms per edit on this machine. B's R6 and bake-search decisions are wrong and its CPU-authoritative edit path is scaffolding by its own account.

---

## Part 1. Engine facts

### a. NaN samples make holes under Jolt in 4.7.2: yes

- `src:jolt_height_map_shape_3d.cpp:71-73` (`_build_height_field`): `// Godot has undocumented (accidental?) support for holes by passing NaN ... so we translate any NaN to FLT_MAX`, and `FLT_MAX` is Jolt's `cNoCollisionValue` (`src:HeightFieldShape.cpp:537-539` quantises it to `cNoCollisionValue16`). The mesh fallback (`_build_mesh`, used when width ≠ depth or the map is under 4 wide) also drops triangles touching a NaN vertex (`:12-19, :123-128`).
- The 4.7 class reference for `HeightMapShape3D` says: "Holes can be punched through the collision by assigning `NAN` to the height of the desired vertices (this is supported in both GodotPhysics3D and Jolt Physics)." (doc/classes/HeightMapShape3D.xml, 4.7 branch.)
- Probe (`/tmp/plan-probe/proj/probe.gd`, Jolt, headless): a 257×257 map with a 45×45 NaN block at the centre: ray at the hole centre `NO HIT`; ray at x = 60 hits at the expected height; ray at x = 22.5 (the triangles touching the rim sample) `NO HIT`, at x = 23.5 a hit, so exactly the triangles that touch a NaN sample are dropped, as C's decision 8 assumes. NaN at sample 0 still builds and collides elsewhere (`HeightMapShape3D::set_map_data` makes `min_height`/`max_height` NaN then, `src:height_map_shape_3d.cpp`, but the Jolt module never reads them: `src:jolt_height_map_shape_3d.cpp:174-200`).
- Bonus fact that explains why 257 works at all: Jolt rounds the sample count up to the block size and pads with no-collision (`src:HeightFieldShape.cpp:441, :703`); the Godot module does no padding itself.

C's decision 9 fallback ("if 4.7.2's Jolt module does not treat NaN as a hole") is therefore moot and can be deleted from Tasks 4 and 7.

### b. `buffer_update` while a compute list is open: refused with an error

`src:rendering_device.cpp:1167ff`: `ERR_FAIL_COND_V_MSG(compute_list.active && !p_skip_check, ERR_INVALID_PARAMETER, "Updating buffers is forbidden during creation of a compute list.")` (`p_skip_check` is not exposed to GDScript). Nothing is uploaded. B and C state this correctly; A says "must be called outside an open compute list", consistent.

Two related facts the plans lean on:

- Ordering: `_buffer_update` records `draw_graph.add_buffer_update(..., p_buffer->draw_tracker, ...)` (`:1088-1165`), so the render graph orders an upload after an earlier list's reads of the same buffer (A's "the render graph orders a later chunk's `buffer_update` after the earlier chunk's reads" and C's single `_up` buffer reused between apply lists are both fine).
- The readbacks have **no** such guard: `buffer_get_data_async` (`:1336`) and `texture_get_data_async` (`:2793`) record a graph command immediately, while a compute list becomes a graph command only at `compute_list_end` (`src:rendering_device_graph.cpp`, `add_compute_list_end` allocates the command; `add_buffer_get_data` allocates its own at call time). A readback issued *inside* an open list is therefore recorded *before* the list and silently returns stale data; the synchronous `buffer_get_data` additionally calls `_flush_and_stall_for_all_frames()` (`:1289-1334`). Every readback must follow `compute_list_end`. Also `capture_timestamp` is refused after the first dispatch of a list (`:8704`); all three plans bracket outside lists, fine.

### c. `compute_list_add_barrier` and the same image in two dispatches: works

`src:rendering_device.cpp:7069-7089`: `compute_list_add_barrier` is literally `compute_list_end(); compute_list_begin();` followed by re-binding the previous pipeline, uniform sets and push constant. The two halves are two graph commands; each list's resources are tracked from its uniform sets (`UNIFORM_TYPE_IMAGE` → `RESOURCE_USAGE_STORAGE_IMAGE_READ_WRITE`, `:4540-4576`; storage buffers → `STORAGE_BUFFER_READ_WRITE`, `:4677-4707`), so the graph inserts the image barrier between them and the second dispatch sees the first's stores. Usage is tracked by RID, not by the GLSL `writeonly`/read-write qualifier, so detail's write-only set and apply's read-write set on the same RIDs (B decision 3) need nothing special. Without a barrier, dispatches in one list are one command with no synchronisation between them, so a read-after-write between two dispatches in one list races (B's barrier, C's stamp→pack barrier and A's "disjoint texels, no barrier" are all correct).

One consequence for B: after the barrier the *detail* pipeline is re-bound, so B's apply pipeline must be bound after it (B's Task 6 does bind it; no defect).

### d. Two heightfields on one `StaticBody3D`, one under the other's NaN hole

- Composition is verified: in the probe, a 65×65 shape 3 m lower as a second `CollisionShape3D` on the same body, enabled under the hole: a ray through the hole hits `shape 1` at the small shape's height. `JoltShapedObject3D::_try_build_compound_shape` wraps the two in a `MutableCompoundShape` (or static when optimised) and `SetShape(..., DontActivate)` on change (`src:jolt_shaped_object_3d.cpp`, fetched 4.7).
- Contact quality for a box crossing the rim is not provable headless. The relevant settings: `physics/jolt_physics_3d/simulation/use_enhanced_internal_edge_removal` defaults to `true` (`src:jolt_project_settings.cpp:39`) and the project does not override it (`godot/project.godot`); `JoltBody3D::_add_to_space` sets `mEnhancedInternalEdgeRemoval = true`. Jolt's removal works per body pair, which covers both sub-shapes of one body (this is also the research doc's reason for one body, `docs/terrain-research.md` 6.8 "Jolt sees heightfields, grouped"). Both shapes are bakes of the same surface in two tangent frames, so their step at the overlap is sub-millimetre, far inside Jolt's 0.02 m penetration slop. Conclusion: C's design is sound with small residual risk; C's `bake_check` should slide a box across the rim (it only drops one through the hole).
- A's claim "overlapping heightfields cannot lower ground" is right: Jolt collides with every sub-shape, so a body rests on whichever is higher; a second shape without a hole can raise but never lower. So A's rejection of a hole-less second shape is valid. A's follow-on "NaN-holing the big patch costs the same full rebuild" is incomplete: the hole is rebaked only when the zone moves (C decision 8, once per ~36 m of trench), not per edit.

### e. The `map_data` cost is irreducible from GDScript; 65×65 is about 0.25 ms

- Path: `HeightMapShape3D::set_map_data` copies and min/maxes every sample, then `_update_shape` → `shape_set_data` → `JoltHeightMapShape3D::set_data` → `destroy()` (`src:jolt_height_map_shape_3d.cpp:174-200`); the next build runs `HeightFieldShapeSettings::Create` in full (`:77-82`: bits-per-sample fit, quantisation, range blocks, `CalculateActiveEdges` over every triangle). Jolt has a partial update, `HeightFieldShape::SetHeights` (`src:HeightFieldShape.cpp:994`), but the module never calls it, and nothing in `PhysicsServer3D` exposes it. So from GDScript the only lever is the sample count.
- Measured headless with the body in a Jolt space (probe, 8 repetitions each): 257×257 **2.87–3.97 ms**; 65×65 as a second shape on the same body **0.24–0.32 ms**; 65×65 as a body's only shape 0.24–0.67 ms; 256×256 2.4 ms. The follow-ups' 2.8 ms in-game figure and C's 0.2 ms estimate are both borne out. Note the 257 figure reaches the spec's whole 4 ms hitch budget on its own.

### f. `ResourceSaver` omits default-valued exported script fields in `.tres`: yes

Empirical, on this machine: `user://worlds/default/params.tres` contains only `script = ExtResource(...)` under `[resource]`; `user://worlds/test_world/params.tres` contains only `radius`, `length`, `h_sea`, the three values the test changes. Consequences: the doc comment on `WorldParams` ("a world file reproduces itself regardless of later changes to the defaults", `godot/terrain/world_params.gd:1-2`) is false in 4.7.2; adding `soil_slope_deg` (all three plans) means every existing world takes the *current* default on load, and changing that default later changes what an old world would regenerate to. None of the three plans' persistence depends on `.tres` (all write raw per-tile files), so this costs nothing now, but C's Task 2 note ("the stored default world predates the knob; it changes only on regeneration") should add that the knob is not pinned by the world file.

---

## Part 2. Decision comparison

| decision | A | B | C | judgement for this codebase |
|---|---|---|---|---|
| Edit storage and where the override is applied | Dense 24 B/cell planar blob per tile, GPU window is truth; `detail.glsl` itself reads an upload ring (set 1 binding 9, `edit_index` push constant) and overwrites flagged cells in the same dispatch | Dense 32 B/cell block with a per-field mask, CPU is truth; `edit_apply.glsl` after detail behind a barrier in the same list; live edits re-upload the whole 512 KB block | Dense 24 B/cell interleaved blob, GPU is truth; `edit.glsl` mode 2 in its own short list after the detail list, one 393 KB `_up` buffer | **C.** GPU-truth is what the dig slice's op kernels need (research 6.8 "uploads are op lists"); B's CPU path is replaced by its own Task 9 note. A's in-detail override is the least code but couples `detail.glsl` to the blob layout and the far window's set; C's separate apply pass is the reusable shape and costs one dispatch. |
| Readback cadence, how the CPU learns values | Snapshot 30 frames after a tile first turns dirty, at eviction (async, or a sync flush slot when the 4-slot ring is full), at flush; generations; `_reapply` on re-entry | Never: CPU-authoritative; `cell_height` reads the override, else the collider's bilinear surface, else macro | Pack every touched tile (1–4) right after every stamp into a 4-slot `_down`, `buffer_get_data_async` lands 2 frames later | **C.** Simplest machinery that keeps the blob current within 2 frames, no eviction race, no sync fallback; 4 MB/s at 10 Hz. A's ring + generations + flush slot + reapply dictionary exists only to tolerate reading back late. |
| Edit API and debug edit | `Terrain.edit(theta, z, radius, dh)` GPU disc op (cosine falloff) plus `TerrainEdits.set_cell` + `regenerate` for tests; `G`/`H` at the crosshair via a physics ray, 10 Hz | `Terrain.write_cells(cells, field, values)` absolute + `cell_height`; `[`/`]` per press, disc 4 m ahead of the ground body | `Terrain.edit(theta, z, radius, dh)` GPU disc op (parabolic), refused unless every tile is resident; `[`/`]` under the viewer at 10 Hz | **C** (A equivalent). The GPU op is the tool shape; B's cell list puts the shape loop in GDScript. A's crosshair aim is the nicer debug tool (dig where you look, not only under your feet) and is a cheap optional transplant. |
| Collider rebake policy (R3) | Whole 257² patch rebaked in place at the same centre, throttled 0.1 s, never while pending, when a stamp `touches` it; 2.9–4 ms CPU per rebake accepted | Same, via `ColliderPatch.mark_dirty`/`edit_bake_due` | 65×65 `EditShape` on the same body rebaked per edit (0.25 ms), NaN hole ±22 cells in the big patch, big rebake only when the zone moves (`zone_holds`, margin 4) | **C.** It is the only one that meets "without a visible hitch" with margin: 0.25 ms vs 2.9–4.0 ms on the main thread at up to 10 Hz, at 120 Hz V-Sync (8.33 ms frames). R3 itself says 2.8 ms "will not survive per-edit rebakes", and the later flowing-material slice needs per-frame refresh. Cost: the zone bookkeeping (Part 3, C1). |
| Bake shader rewrite | One workgroup per row, `local_size_x = 257`, 409 mapped samples in shared memory, each thread scans every segment; fixed N = 257 | Two passes: map to an `rg32f` image, then per column a binary search treating the row as monotone plus a ±16 segment scan | One pass, one invocation per output sample, k-range from `asin(x/R)` to `asin(x/(R − h_max))` ±1, parametric `n` and hole | **C.** The bound is correct (proof in Part 3, B2) and the shader is parametric, which the edit shape needs. A's is also correct and the smallest change, but is fixed at 257 and 512 shared slots. B's search is wrong for tall faces at altitude. |
| Far window (R4) | Documented limit, code comments, no task | Documented limit, `far_terrain.gd` header, follow-up note | Same as B | Equal; all correct. |
| Hold-rule tests (R5) | `test_hold_rule.gd` on stubs + a `--blackout` route in the existing `smoke_run.gd` | `test_hold_rule.gd` (with registry) + new `hold_check.tscn`: teleport 100 m then walk 24 m, box check | `test_hold_rule.gd` (with `covers` ignoring `_pending`) + new `hold_check.tscn`, 10 s run | **A's route** in **C's test**: no new scene, the smoke driver already has the counters, and it is literally R5's check. B's teleport trick shortens the wait but adds a scene. |
| Bedrock flag (R6) | New 9th window field `flags` (`EDITED`, `ROCK_FACE`); lift kept; stamp clears `ROCK_FACE` | Material 3 "rock face"; the lift is **removed**; `bedrock_top` is always the stratum | Material 3 only where the lift happened (`face && b + nb < h − 0.01`); lift kept; stamp never writes 3 | **C.** Zero extra storage (C's 9th field is `edit_mask`, which A's `flags` also is, so that is a wash), the id travels through the blob and the tile shader for free, and the data stays consistent with spec 4.2. B breaks the spec (Part 3, B1). Keep rock's colour for id 3, not C's darker shade. |
| `theta_of` / `cell_of` (R7) | `theta_of` returns 0 at TAU; `cell_of` without z clamp; replaces 2 sites | Same; `cell_of` clamps z; replaces 2 sites | Same; no z clamp; replaces 4 sites (`terrain.gd:74,301`, `collider_patch.gd:101`, `debug_window.gd:294`) | **C** (most complete; the no-clamp matches the sites replaced, `godot/terrain/terrain.gd:301`). |
| Topsoil knob | `soil_slope_deg = 40`, quadratic falloff, raw differences over 2·32 m as `_spawn` does | 45°, linear, true θ width | 30°, linear, true θ width, `_slope` helper | **C.** The only default argued from the generated slopes (rim-adjacent cells 32°, mountains 14°); B's 45° does nothing on the default world (only rims reach it, and rims already have `d = 0`, `macro_generator.gd:519`); A's raw-difference slope under-reads mountains by ~40% (cell width 19 m at 1500 m, not 32). All three tests share one hazard (Part 3). |
| Rigid-body hold and per-body patch | Group `ground_bodies`, `_hold(body, hold)` with a `_held` dict, per-body patch deferred with a sketch | `register_body` registry pruned by `is_instance_valid`, Emitter gets a `terrain` export and `main.tscn` changes | Group `terrain_ground`, `_hold` state in body meta, per-body patch deferred with a sketch (C's `ColliderPatch(65)` is already parametric after Task 4) | **C.** A group is one line in `emitter.gd` and no scene edit; meta state leaves no stale keys for freed bodies. C's parametric patch makes the deferred per-body design a genuine next step. |
| Persistence and save cadence | Per-tile `.edits` (format word + blob, `open_compressed` zstd); flush + save at `_exit_tree`, autosave landed blobs every 30 s | Per-tile `.edits` (16-byte header, zstd); written when a dirty tile leaves the window and at `_exit_tree` | Per-tile `.edit` (version, raw size, zstd blob); saved only at `_exit_tree`; `persist_edits` export so drivers never write the default world | **C + A's autosave.** C's `persist_edits` keeps the drivers clean; A's 30 s autosave of unsaved blobs is a dozen lines and the only protection against a crash. B's write-on-exit during a window step is a hitch risk. |
| Measurement | `edit_check` table with budgets (detail, bake, stamp, `map_data`, GPU frame, interval, rebakes), both drivers, recorded in research 6.8 | `smoke_run` edit phase, table, follow-ups doc | `edit_run` summary per pass (count/median/p90/max/over budget), `map_data` per kind, per phase intervals, which collider path shipped; follow-ups doc | Equal in substance; C's reports the collider path and p90, A's names budgets per row. Any. |

---

## Part 3. Defects per plan

Grades: **Critical** = the plan as written cannot deliver the goal or breaks slice 1; **Important** = a task would fail or need redesign during execution; **Minor** = fix in passing.

### Plan A (0 Critical, 2 Important, 7 Minor)

**A1. Important. Task 8 Step 4 and Task 10's table expect "rebakes between 4 and 6 for 5 s of digging"; the design gives 25–50.** `EDIT_REBAKE_INTERVAL = 0.1` with 50 ops at 10 Hz, each setting `_edit_pending`, and `touches` true throughout (the dig point is fixed, the patch centre does not move under 64 m of walking) yields a rebake every 0.1 s minus those skipped while a bake is in flight (2–3 frames at 120 Hz), i.e. roughly 25–50. An executor following the expected output would "fail" the step. Fix: expect 20–50 and say why.

**A2. Important. D7 accepts a 2.9–4.0 ms main-thread stall per edit rebake** (Part 1e; A writes "under 4 ms", the probe's max was 3.97 ms headless). At up to 10 Hz on 8.33 ms frames that is a third to half of a frame spent in `map_data` while the frame's own CPU work continues, and R3 says this cost "will not survive per-edit rebakes". The design works, but "without a visible hitch" is decided only by Task 10's rate phase, after Tasks 4–9 are built on it; if it misses, the redesign is C's Task 7. Fix: adopt C's edit shape (and C's parametric bake), or make the rate-phase measurement the first thing the collider work runs so the decision is taken early.

A3. Minor. Task 7's wording for `_dispatch(tiles, leaving)` puts the snapshot's readback ("a free ring slot with an async readback ... or the flush slot with a synchronous `buffer_get_data`") in the sentence that describes the list. Per Part 1b, both readbacks must be issued after `compute_list_end` or they read stale data (async) or stall mid-list (sync). Say so explicitly.

A4. Minor. Task 1's topsoil test takes slopes from the final `m.surface`, but `_banks` runs after `_strata` (`godot/terrain/macro_generator.gd:78`) and lowers water-adjacent cells by up to `tan 35° · 32 m` per neighbour step (`:552-566`), steepening neighbours after `_strata` chose `d`. At 40° the false-failure chance is small; skip cells within two of water.

A5. Minor. Task 1's slope uses raw differences over `2 · macro_cell` across θ (as `_spawn`, `:640`), but a macro cell is `(R − s) · 32 · dθ` wide: 32 m at sea level, 19 m at 1500 m, so mountain slopes read ~40% too gentle. B and C use the true width.

A6. Minor. A 9th window field for `EDITED` is justified, and `ROCK_FACE` rides on it; but after a stamp clears `ROCK_FACE` the lifted `bedrock_top` stays in the cell as data. Document that an edited cell's strata are "real by fiat".

A7. Minor. D14's synchronous flush fallback (`buffer_get_data`) is a full GPU stall on a window step; A marks it `ponytail:`. `load_edits` also loads every edited tile's 393 KB into RAM at start.

A8. Minor. `_hold`'s `_held` dictionary keeps freed bodies as keys (the group loop stops visiting them, the dict does not shrink). C's meta on the body avoids it.

A9. Minor. Task 3's headless test pins only constants (`FIELDS.size() == 9`, two flag values); the real check is the windowed dump. Acceptable, but say so in the step.

Checked and found right in A: `tiles_touched` seam and end-row cases (Task 6 test values verified by hand against `wrap_tile`/`tiles_along`); `stamp.glsl` 48-byte push block and per-cell wrap + residency test from `collider_bake.glsl:234-241`; the detail push constant's `pad` → `edit_index` at byte 60 (`terrain_window.gd:295-314`); the bake rewrite keeps `Cyl.bake_row`'s rules (`cyl.gd:32-62`: vertical segment takes the higher end, uncovered takes the end sample), 409 ≤ 512 shared slots on the default world (`half_n = 204`, `collider_patch.gd:121`); hold-rule test matches `_hold_body` (`terrain.gd:201-206`); same-centre rebake leaves `covers` unchanged; the 30-frame snapshot and the 36-frame waits in `edit_check` line up; `_exit_tree` runs on window close and on `quit()`.

### Plan B (0 Critical, 3 Important, 6 Minor)

**B1. Important. R6 as "material 3 and no lift" breaks slice 1's data semantics.** Decision 11 and Task 3 set `float bt = clamp(b + nb, 0.0, h)` and `material = face ? 3.0 : ...`. On a face the window then says `is_rock(material)` while `bedrock_top < surface` by the interpolated depth; spec 4.2 defines `bedrock_top` as "equals `surface` where rock is exposed" and `material` as derived from the strata (design 6.2 step 5), and 6.1 step 8 wants faces to expose rock. The visual stays (row 3 = rock's colour, and `tile.gdshader:49` already clamps ids to 2), but the dig slice's auger would cut dirt out of a face that draws as rock, and any strata consumer sees a rock surface with soil under it. R6 asked readers to treat the jump as a flag, not to remove the jump. Fix: keep the lift and mark only lifted cells (C's rule), or A's flag bit.

**B2. Important. Pass B's binary search + ±16 scan can return the wrong envelope on a tall face at altitude.** The predicate "`mapped[k].x ≤ x`" is non-monotone across a fold-back: for an `x` in the overlap, it is true on the bottom run up to some `k₁`, false up to the face, true again on the plateau up to `k₂`, then false. A bisection converges to `k₁` or `k₂`, never to the middle, and the three covering segments (bottom, face, plateau) span about `2 · H sin φ / spacing` samples. B's bound ("under 16 samples for faces up to 200 m at the patch edge") assumes 1 m spacing and a centred landing; at altitude a sample is 0.77 m in `x` (follow-ups, measured limits), so a 200 m face at φ = 204·dθ spans ≈ 40 samples, and from `k₁` the window reaches the face but not the plateau: the column takes the face or bottom height, tens of metres low, not "only its overhang envelope". On the default world cliff bands are at most `cliff_max = 60 m` (fold ≤ 4.7 m ≈ 6 samples), so B's `bakecheck` on rows 0/128/256 would pass by luck; the plan's own claim is unproven and false in general. Fix: C's asin-bounded single pass (proof: a segment `(k, k+1)` covering `x > 0` needs `(R − h_k) sin φ_k ≤ x` and `(R − h_{k+1}) sin φ_{k+1} ≥ x` or the mirror, so `φ_k ≤ asin(x / (R − h_max))` and `φ_{k+1} ≥ asin(x / R)`; both ends lie in `[⌊asin(x/R)/dθ⌋ − 1, ⌈asin(x/(R − h_max))/dθ⌉ + 1]`), or A's full scan.

**B3. Important. Task 2's test computes `f` from the final surface; `_banks` changes it after `_strata`.** `_banks` (`macro_generator.gd:541-575`) runs after `_strata` (`:78`) and caps water-adjacent land at the water neighbour plus `tan 35° · 32 m = 22 m`, dropping those cells by tens of metres on the small world (hills next to rivers), which changes their neighbours' central differences. With the knob at 10° (`tan = 0.176`, i.e. 11 m over 64 m), many such neighbours have `f_test < f_gen` and `depth ≤ d_max · f_test + 1e-3` fails. Fix: test the factor on cells with no water within two macro cells, or expose the pre-bank surface to the test, or unit-test the factor function.

B4. Minor (design debt). Decisions 1 and 5 make the CPU authoritative and upload a whole 512 KB block per edited tile per stamp; B's own Task 9 follow-up says the real tools replace `write`/`cell_height` with GPU ops and a readback. Tasks 5 and 8 are partly scaffolding for the debug stamp.

B5. Minor. `far.gdshader:14` keeps `material_color[3]` while `materials.tres` grows to four rows; Godot truncates the array silently, so nothing breaks, but update it (C does).

B6. Minor. `soil_slope_deg = 45` is inert on the default world: the only 45° macro slopes at 32 m are cliff jumps, whose rim cells already have `d = 0` (`:519`). Say so, or pick a default that bites.

B7. Minor. Writing a block (zstd of 512 KB) when a tile leaves the window, and loading one from disk for every entering tile with a file, both run on the main thread inside `move_to`, on the path the 4 ms window-step budget guards; a teleport can do both 16 times. Save on a timer and at `_exit_tree` (A), keep blobs in RAM (A, C).

B8. Minor. Task 4's registry needs `Emitter.terrain`, a `main.tscn` edit and `bodies()` pruning; a group is one line in `emitter.gd` and no scene change (A, C).

B9. Minor. Task 7's `bakecheck` reads `_shape.map_data` for rows 0, 128, 256 only; add a row through a cliff band (the `--cliff` idea in C's Task 3) so B2's case is at least sampled.

Checked and found right in B: `compute_list_add_barrier` between detail and apply (Part 1c); `buffer_update` before `compute_list_begin` (1b); per-slot storage buffers created lazily; `disc_cells` seam/end test values; `EditLayer.bit("material") == 32` consistent with the apply pass's "bit 32"; `edit_bake_due` test on a headless patch; `hold_check` geometry (teleport 100 m keeps the box covered, the edge is 24 m ahead).

### Plan C (0 Critical, 2 Important, 9 Minor)

**C1. Important. Task 7's coalescing can land a hole before the edit shape that backs it.** `on_edit` on a zone move calls `_bake_edit` then `_rebuild_here`. If an edit bake is already in flight (`_pending_edit`), the new-zone edit bake is deferred to `_again_edit` and issued only when the old one lands, but the big bake with the *new* hole is issued at once; it lands ≥ 1 frame before the new edit shape, and the old edit shape covers the old zone, not the new. Review Focus 3 asserts "no physics tick may see a hole without the edit shape under it", and `edit_run`'s trench phase would not catch a one-tick hole (a body falls ~1 mm in it). Fix (one rule): when `_pending_edit` is set at a zone move, set `_again_big` as well and issue both bakes from the edit landing, edit first; or re-evaluate `zone_holds` on the edit landing and only then move the zone.

**C2. Important. Task 2's test (`steep_bare == steep` at 12°) has the same post-bank hazard as B3**, and with `tan 12° = 0.21` (13.6 m over 64 m) against bank drops of up to 22 m per step it is likely to fail on the small world: a cell steepened by its capped neighbour is "steep" in the test but kept its soil in `_strata`. Same fix as B3.

C3. Minor. Decision 4's reasoning ("the stamp's cells are near the viewer, never in a tile about to leave") does not hold for `Terrain.edit` in general: a stamped tile evicted and re-entered within the 2-frame readback applies the old blob, and nothing re-applies when the pack lands. Fix: keep a per-slot generation; in `_packed`, if the tile is resident and its slot was regenerated after the stamp, call `apply_entering` for it. Or document it as a limit of this slice.

C4. Minor. `center_height()` reads sample `_MID` (`collider_patch.gd:74-75`), which is NaN once the zone is within 22 cells of the patch centre (digging under one's feet right after a rebuild). Only `_on_first_live` uses it, before any zone exists; add a comment or a NaN guard so the next caller is not surprised.

C5. Minor. `bake_check` step 3 expects 1681–2209 NaN samples for a ±22-cell hole; the hole is defined in cell space and a cell is `(R − h) · dθ` wide in `x`, so the count is `45 × 45 · (R − h) · dθ`: 2160 at the spawn's height (~420 m) and 2475 at the hull. Derive the expected range from the local cell width or the test fails on a different world.

C6. Minor. Part 1d is not pinned: `bake_check` drops a box through the hole but never slides one across the rim between the two shapes. Add "push a box from the big patch into the edit shape; it stays within 5 cm of the surface".

C7. Minor. Task 3 gives material 3 the colour `(0.42, 0.42, 0.45)`, a visible change to slice 1's cliffs ("a shade darker"); unless the user asked for it, use rock's colour (B's choice) and keep the id as data only.

C8. Minor. Decision 9 and the fallback branches in Tasks 4 and 7 are moot (Part 1a); delete them and the "which path shipped" line in Task 9.

C9. Minor. `Terrain.edit` stamps and then `on_edit` reads the window in the same frame; the graph orders the bake's reads after the stamp's writes (1c), fine, but say "after the stamp's list has ended" so an executor does not put the bake inside it.

C10. Minor. Task 3 has no headless test; B's `test_material_set.gd` (B Task 3 Step 1) pins the four-row resource and `ROCK_FACE` for free.

C11. Minor. Task 9 edits the slice 1 follow-ups doc to strike closed items; harmless, but the brief treats that doc as the record of what slice 1 left open, so a pointer line is better than strike-throughs.

Checked and found right in C: `stamp_tiles` test values (seam at column 2, first rows at `j = 1`, four tiles at `(127, 127)`) against `wrap_tile` and the row clamp; the stamp's residency test rejects rows `≥ n_z` automatically because `wanted_origin` keeps `first_tile.y + slots ≤ tiles_along` (`terrain_window.gd:237-240`, `collider_bake.glsl:236-237`); the 64-byte push blocks for `edit.glsl` (56 B used) and the new bake (64 B exactly); the asin bound (B2's proof) and the `best == NONE` fallback (only past the ends, which `half_n` makes unreachable); `covers` unchanged by a hole (the edit shape backs it) and `surface_point`'s NaN fallback for `teleport`/`_on_live`; `_down` slot reuse is ordered by the graph's copy-before-write tracking; `apply_entering` runs for every (re-)entering tile from `_dispatch`; `persist_edits = false` in drivers; `Loaded N edited tiles` before the first `_move_window`; the hold test matches `_hold_body`.

### Rules check (writing-plans skill)

All three have the required header, Interfaces blocks, five Review Focus items with owning tasks, and commits per task. Steps without a failing test are the GPU-only ones (A Task 5 uses a windowed check as the failing test; B Task 6 and C Task 3 start at "implement"), which the headless constraint justifies if the step says so (C Task 3 does, B Task 6 does not). Code bodies appear only where the signature does not determine them (A's stamp rule and bake mapping, B's pass B search, C's bake pseudo-code). All three are longer than the spec they argue from; equally. B's Task 9 "Anything the measurement run showed" decides nothing. None of these changes the ranking.

---

## Part 4. Recommendation

**Execute plan C.** It is the only plan whose collider meets the goal with margin (0.25 ms per edit against 2.9–4.0 ms, Part 1e), its bake rewrite is the one that is both correct and parametric, its GPU-authoritative edit layer is the one the dig slice keeps, and its R6 and `cell_of` choices are the tidiest. Its two Important defects are a one-rule ordering fix and a test adjustment, neither a redesign.

Before Task 1, amend C:

1. **C1 (Task 7):** on a zone move while `_pending_edit`, defer the big bake to the edit landing and issue edit then big from there. Add to `edit_run`'s trench phase an assertion that a `baked("big")` landing with a new hole is always preceded in the same frame by a `baked("edit")` for that zone (count pairs), which pins the rule.
2. **C2 (Task 2):** restrict the test's steep/gentle classification to land cells with no water within two macro cells (one extra `continue`), and say why in the comment.
3. **C8:** delete decision 9 and the fallback sentences in Tasks 4, 7 and 9 (settled, Part 1a).
4. **C7:** material 3 takes rock's colour.

Transplants, each with its reason:

- **From A, Task 2 Step 3: the `--blackout` route in `smoke_run.gd`** instead of C Task 8's `hold_check.tscn`. One file less, the counters and summary already exist (`smoke_run.gd:181-217`), and it is R5's literal check. Keep C's `test_hold_rule.gd` (its "`covers` ignores a pending bake" line is the better headless pin) and C's manual box check.
- **From A, D13: the 30 s autosave** into C Task 6. C saves only at `_exit_tree`; a crash in a GPU-heavy dev build loses every edit. C's `_packed` already knows which tiles changed; a `_unsaved` set and a `SAVE_INTERVAL` timer in `Terrain._process` is a dozen lines, writes only landed blobs (no stall), and `persist_edits` still gates it.
- **From B, Task 3 Step 1: `test_material_set.gd`** into C Task 3, with C's names (`ROCK_FACE`, four rows equal to rock's). C's Task 3 has no headless test; this one is free.
- **Optional, from A, D5/Task 6: the crosshair aim** (`debug_edit.gd`'s physics ray along the camera, excluding the viewer's RID) in place of C's under-the-viewer stamp, if the user wants to dig where they look. Keep C's 10 Hz hold-to-dig; A's `G`/`H` versus C's `[`/`]` is taste.
- **From A, Task 8: the "bake vs CPU" rows through `Cyl.bake_row`** are already in C's `bake_check` (rows 128 and 8); add a row through a cliff band (C's own `--cliff` scan from Task 3) so the fold-back path of the new shader is sampled, which neither A nor C does today.

Also carry into C the fact from Part 1f: the `WorldParams` doc comment is wrong in 4.7.2; fix the comment when adding `soil_slope_deg` (one line, Task 2).

**If the controller prefers the smaller collider change** (in-place rebake, no second shape): A is the closest executable plan. Fix A1, replace A's D14/Task 7 snapshot machinery (ring, generations, flush slot, `_reapply`) with C's decision 4 (pack at edit time, 2-frame landing), which removes A's Review Focus 2 and its sync fallback outright, and make A2's rate-phase measurement the first thing Task 8 runs so the 2.9–4.0 ms decision is taken with numbers. Do not take B's R6 or bake search in any combination.
