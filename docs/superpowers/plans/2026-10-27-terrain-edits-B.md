# Terrain Edits (slice 1 follow-ups R1, R3 and company) Implementation Plan (version B)

> Not chosen. The comparison is in [review-terrain-edits.md](review-terrain-edits.md); the chosen plan is [2026-10-27-terrain-edits-C.md](2026-10-27-terrain-edits-C.md), which absorbed this plan's headless material-set test. Its R6 (removing the bedrock lift on faces) and bake-search decisions were found wrong (review Part 3, B1 and B2).

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A per-cell edit of the terrain survives the window scrolling away and back, is drawn by the detail pass and stood on by the collider, and the collider keeps up with edits at a hand tool's rate without a visible hitch; with the slice 1 follow-ups R4 to R7, the steep-slope topsoil rule, the bake shader's occupancy and the "boxes fall while flying" defect folded in.

**Architecture:** An `EditLayer` keeps absolute per-cell overrides in dense 128 × 128 blocks, one per edited tile, on the CPU while the tile is resident and in `user://worlds/<name>/tiles/` otherwise. When a tile enters the window, `TerrainWindow` uploads its block to a per-slot storage buffer and runs `edit_apply.glsl` after `detail.glsl` in the same compute list; a live edit re-uploads the block and runs the apply pass alone. `ColliderPatch` rebakes at its current centre when an edit lands inside it, at most every 0.1 s, with the bake split into a map pass and a resample pass so it runs on the whole GPU. `Terrain` holds every registered body (the player and spawned boxes) that no live patch covers.

**Tech Stack:** Godot 4.7.2 standard build, Forward+, Jolt, GDScript, GLSL compute on the main `RenderingDevice` (storage buffers, `buffer_update`, `compute_list_add_barrier`, `texture_get_data_async`), `HeightMapShape3D`, `FileAccess.open_compressed` (zstd).

**Spec:** none for this slice. The plan argues from the follow-ups doc [docs/superpowers/plans/2026-10-27-terrain-slice-1-followups.md](2026-10-27-terrain-slice-1-followups.md) (its scope), the slice 1 design [docs/superpowers/specs/2026-10-24-terrain-slice-1-design.md](../specs/2026-10-24-terrain-slice-1-design.md) (conventions, datum, budgets, what later slices own) and the research doc [docs/terrain-research.md](../../terrain-research.md) sections 6.1, 6.6 and 6.8 (span columns, consistency, the GPU plan). Where those are silent the Decisions section records the call, its alternative and the reason, so a reviewer can check each one.

## Decisions

1. **Edit storage: dense per-tile override blocks, CPU-authoritative.** Each edited tile has a 128 × 128 block of 32-byte cells (`uint mask; float surface, bedrock_top, clay_bottom, clay_top, water_surface; uint material | compaction << 8 | saturation << 16; uint pad`), 512 KB, keyed by tile index and local cell, i.e. by world cell `(i, j)` with `i` in `[0, n_theta)` wrapped and `j` in `[0, n_z)` clamped. The mask says which of the eight fields are absolute; the apply pass writes those, then re-clamps the ordering invariant `0 ≤ bedrock_top ≤ clay_bottom ≤ clay_top ≤ surface` and derives `material` from the strata unless its bit is set. A tool that lowers `surface` therefore stores one absolute number per cell; the strata under it follow by `min`, which is exact where it binds and as deterministic as unedited terrain where it does not, so R1's warning about replaying differences on another driver does not apply. *Alternative:* a sparse op list per tile (cell, field, value). Rejected: replaying it needs a GDScript loop or a coalescing pass at tile entry, while a block uploads with one `buffer_update` and no loop. *Alternative:* a GPU-authoritative block (relative ops applied on the GPU, block read back on tile exit), which is what the research doc's "uploads are op lists" wants eventually. Deferred to the dig slice: it needs readback ordering against slot reuse and gives this slice nothing it needs; sketched in Task 9's notes.
2. **Fields stored: all eight, with a per-field mask.** Storing only `surface` would be 4 bytes per cell, but the next slice's tamper writes `compaction`, a pump writes `water_surface`, and a dense block with a mask costs nothing in code. Memory: 512 KB per edited resident tile on the CPU and the same in its slot's storage buffer, allocated lazily per slot: at most 16 slots (8 MB) at the 512 window, 64 (32 MB) at 1024, typically a few tiles for a hand tool. Non-resident tiles live only on disk. If the 1024 case ever matters, a 16-byte layout (heights as the spec's 1/32 m `u16` pairs) halves it; noted in Task 5's comments, not built.
3. **GPU read: an `edit_apply.glsl` dispatch per tile after `detail.glsl`, in the same compute list, one barrier between the detail dispatches and the apply dispatches** (R1). Set 0 is the slot's storage buffer, set 1 the window images (read-write; detail's set is write-only, so the apply shader gets its own set on the same RIDs). A live edit runs `buffer_update` and the apply dispatch alone. `buffer_update` is forbidden inside a compute list, so uploads precede `compute_list_begin`. *Alternative:* make `detail.glsl` read the block itself. Rejected: the far window shares the detail pipeline and must not read edits (R4), and a live edit would re-run the whole detail pass.
4. **Persistence: `user://worlds/<name>/tiles/<ti>_<tj>.edits`, zstd via `FileAccess.open_compressed`, a 16-byte header (magic `0x45544741`, version 1, stride 32, cells 16384) then the block.** Written when a dirty tile leaves the window and on `Terrain._exit_tree`. A sparse block compresses to a few KB. *Alternative:* one `.res` per tile via `ResourceSaver`. Rejected: slower, and the block is bytes.
5. **Edit API: `Terrain.write_cells(cells: Array[Vector2i], field: String, values: PackedFloat32Array)`** with world cells and absolute values, plus `Terrain.cell_height(cell) -> float` (the override if any, else the live collider's surface, else the macro surface) so a stamp can be relative to what is there. The debug edit, `DebugEdit` on keys `[` and `]`, lowers or raises a 3 m disc 4 m ahead of the ground body by 1 m per press. It exists only to drive the pipeline; the real tools (auger, tamper, their input and their relative ops) are the dig slice's. *Alternative:* a disc under the Ctrl-click point. Rejected: the click lands on the 32 m macro surface, metres off the fine surface at grazing angles; 4 m ahead of the player is exact, visible, and does not drop the player into its own pit.
6. **Collider rebake on edits (R3): rebake the whole patch at its current centre, throttled to one bake in flight and at most one per 0.1 s; fix the bake's occupancy with a two-pass map-then-resample.** Cost per rebake after this plan: GPU under 0.1 ms (pass A maps 407 × 257 samples, pass B resamples 257 × 257 columns: 66k invocations instead of 257), readback 2 frames, CPU 2.8 ms for the `map_data` assignment (Jolt rebuilding the shape; not reducible from GDScript). At 10 rebakes per second that is 28 ms of main-thread time per second, each inside the spec's 4 ms frame-hitch budget and under the 8.33 ms frame at 120 Hz, so no frame is missed; Task 9 measures it. *Alternative:* a small second `HeightMapShape3D` over the edit zone with NaN holes in the big patch. It cuts the 2.8 ms to about 0.05 ms per edit but adds a second body (Jolt's internal-edge removal does not cross bodies: a seam to snag on), hole bookkeeping in the bake and a zone that must move with the tool. Deferred until a continuous tool shows the 2.8 ms; sketched in Task 9's notes. *Alternative:* one invocation per output column in a single pass. Rejected: each column would scan a 400-sample row or guess its sample index from a height it has not read yet; the two-pass version is two short kernels.
7. **Hold rule and rebakes:** an edit rebake keeps the patch's frame and centre, so `ColliderPatch.covers` is unchanged while it is in flight and the player is never held by an edit. A viewer-movement rebake that falls due while an edit rebake is in flight waits for the next frame, as today.
8. **Far window (R4): nothing but a documented limit.** The 8 m window regenerates from the macro maps and shows no edits. It is only drawn beyond 256 m, where a hand edit of a few metres is a dot; a cheap approximation (sampling the 1 m override at each 8 m cell's centre) would show a pit as a random single cell and is worse than nothing. If the dig slice's earthworks pass 8 m, it downsamples the edit block's surface into the far window; noted in Task 9's follow-ups.
9. **R5: a headless test on `ColliderPatch.covers` and `Terrain._hold` with stub bodies, and a windowed driver `hold_check.tscn` that stops the render loop for 10 s.** Task 4 owns both. Instead of walking 124 m with the loop off, the driver teleports the body 100 m spinward (still covered) and walks the last 24 m, so the check is short and deterministic.
10. **Second collider patch per rigid body: deferred; boxes are held instead.** `Terrain.register_body(body)` adds a body to the hold rule: any registered body that no live patch covers has `process_mode` set to `DISABLED` (a `RigidBody3D` leaves the physics space with its state and resumes when re-enabled) until a patch covers it again. Boxes left near the player while the camera flies away freeze in place instead of falling to the hull. *Alternative:* a `ColliderPatch` per distant body, 2.8 ms CPU and a bake each time it moves. Deferred with its design in Task 9's notes; the hold is a few lines and the bake shader already takes an arbitrary centre.
11. **R6: material id 3 is "rock face".** The detail pass no longer forces `bedrock_top` to the surface on faces over 60°; it writes `material = 3` there and leaves the strata as generated. `bedrock_top` is therefore always the stratum, and a consumer that wants "is the surface rock" reads `material` (`MaterialSet.is_rock(id)` is `id >= 2`). `materials.tres` gains a fourth row equal to rock's so every per-material array stays indexable. *Alternative:* a ninth window field of flags. Rejected: a texture, a binding and a mask bit for one bit. *Alternative:* a documented rule only. Rejected: the jump in `bedrock_top` stays and the next solver still special-cases it.
12. **R7: `Cyl.theta_of` returns strictly inside `[0, TAU)`** by mapping a result that rounds to `TAU` to `0.0`. No consumer loses its wrap: `viewer_cell` and the patch's centre cell keep `posmod` because `theta / dtheta` can round up to `n_theta` for an angle within `1e-12` of `TAU` even when it is below it; that `posmod` moves into the new `WorldParams.cell_of(theta, z)`, the one place cells are computed from angles from now on.
13. **Topsoil thin on steep slopes: `WorldParams.soil_slope_deg = 45`**, the macro slope at which soil depth reaches zero; `_strata` scales `D` by `clamp(1 − slope / tan(soil_slope_deg), 0, 1)` with the slope from central differences of the macro surface using the true cell width at the surface height. One knob, three lines, tested on the small world with the knob at 10° so it bites.
14. **Debug stamp height source:** the first stamp on an unedited cell takes its base height from the collider's baked surface (linear between mapped samples, so up to about 0.2 m off on rough rock); later stamps on the same cell read the override, which is exact. Acceptable for a debug tool; the real tools do relative ops on the GPU (decision 1's deferred design).

## Global Constraints

- Godot 4.7.2 standard build only; no GDExtension.
- Grid: 1 m cells, `Δθ = 2π / n_theta` (16384 by default), window 512 cells (project setting, 1024 the high-end option), tiles of 128, the 4 × 4 ring buffer at 512. Heights radial from the hull in metres (`R32_SFLOAT` window fields, `HEIGHT_SCALE = 1`), `h_sea = 400`, `h_max = h_sea + h_mtn()`.
- Ordering invariant `0 ≤ bedrock_top ≤ clay_bottom ≤ clay_top ≤ surface` everywhere, including after an edit.
- No per-cell GDScript loop on any per-frame path. A tool's stamp loops over its own cells (tens); a block is uploaded, saved and loaded as one `PackedByteArray`.
- Everything in the world is a child of `Station`; terrain code works in station-local `(θ, z)` only and never reads a global position for terrain purposes.
- Headless tests follow the existing pattern (`extends SceneTree`, `_initialize`, `check`, print `PASS`, `quit`) and run via `godot/tests/run.sh`; they cannot create a `RenderingDevice`. GPU work is verified by short windowed drivers that save screenshots or print numbers; windowed runs open a window on the user's screen, so they stay short and quit themselves.
- Budgets (slice 1 spec section 12, still binding): detail under 2 ms per tile, bake under 1 ms GPU, frame under 6 ms GPU mean, frame hitch under 4 ms. New: edit apply under 0.1 ms per tile. Task 9 says how each is measured: GPU times come from `capture_timestamp` pairs under `--rendering-driver vulkan` (MoltenVK); Metal returns zeros, so a Metal run checks errors and CPU times only.
- Commit after each task with the message given.

## Review Focus

1. An edit disc straddling the θ = 0 seam or a tile boundary: its cells fall in two or four tiles, every block is written and applied, and cells past a station end are dropped, not clamped onto the last row twice. Pinned by `test_edit_layer.gd` in Task 5.
2. A corrupt or truncated `.edits` file (wrong header, short body): the tile loads as unedited with one `push_warning`, and the next edit overwrites the file. Pinned by `test_edit_layer.gd` in Task 5.
3. Edit values outside the world (a surface above `h_max` or below 0, a material above 3): clamped on write, so the apply pass never stores a height the tile shader's AABB does not cover. Pinned by `test_edit_layer.gd` in Task 5.
4. A registered body that was freed, or one something else already disabled (the fly camera's hold on the player): the first is dropped silently, the second is never released by Terrain. Pinned by `test_hold_rule.gd` in Task 4.
5. An edit that lands while an edit rebake is already in flight: the patch stays dirty and a second bake follows the first, so the last edit is never lost. Pinned by the `edit_bake_due` checks added to `test_hold_rule.gd` in Task 8.

## File structure

- `godot/terrain/edit_layer.gd` (new): blocks, mask bits, `write`, disc cells, disk via `WorldIO`.
- `godot/terrain/shaders/edit_apply.glsl` (new): the apply pass.
- `godot/terrain/shaders/collider_map.glsl` (new) and `collider_bake.glsl` (rewritten): the two-pass bake.
- `godot/terrain/debug_edit.gd` (new): the `[` `]` stamp.
- `godot/terrain/hold_check.gd` + `hold_check.tscn` (new): the R5 windowed driver.
- Modified: `cyl.gd`, `world_params.gd`, `world_io.gd`, `macro_generator.gd`, `material_set.gd`, `materials.tres`, `shaders/detail.glsl`, `shaders/tile.gdshader`, `debug_window_dump.gd`, `debug_window.gd`, `terrain_window.gd`, `terrain.gd`, `collider_patch.gd`, `far_terrain.gd`, `emitter.gd`, `main.tscn`, `smoke_run.gd`, `timing_overlay.gd`, `docs/terrain-research.md`.
- Tests: `test_cylinder_math.gd`, `test_macro_maps.gd`, `test_macro_generator.gd` (modified); `test_material_set.gd`, `test_hold_rule.gd`, `test_edit_layer.gd` (new).

---

### Task 1: `Cyl.theta_of` strictly inside `[0, TAU)` and `WorldParams.cell_of` (R7)

**Files:**
- Modify: `godot/terrain/cyl.gd:12-14`, `godot/terrain/world_params.gd` (add `cell_of`), `godot/terrain/terrain.gd:297-301` (`viewer_cell`), `godot/terrain/collider_patch.gd:100-101` (`rebuild`'s centre cell)
- Test: `godot/tests/test_cylinder_math.gd`, `godot/tests/test_macro_maps.gd`

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `Cyl.theta_of(p: Vector3) -> float`: as today, but a result that rounds to `TAU` becomes `0.0`; the doc comment says "strictly inside [0, TAU)".
  - `WorldParams.cell_of(theta: float, z: float) -> Vector2i`: the 1 m world cell, `Vector2i(posmod(floori(theta / dtheta()), n_theta()), clampi(floori(z + length / 2.0), 0, n_z() - 1))`. Every later task that needs a cell from an angle calls this.

- [ ] **Step 1: Write the failing tests**

Append to `test_cylinder_math.gd` before `if failed:`:

```gdscript
	# R7: strictly inside [0, TAU). -1e-20 rad rounds to TAU under fposmod; it must come back as 0.
	check(Cyl.theta_of(Vector3(-1e-20, -1, 0)) == 0.0, "angle that rounds to TAU is 0: %.17f" % Cyl.theta_of(Vector3(-1e-20, -1, 0)))
	check(Cyl.theta_of(Vector3(0, -1, 0)) == 0.0, "theta 0")
	var just_under := Cyl.theta_of(Vector3(-1e-6, -1, 0))
	check(just_under < TAU and just_under > TAU - 1e-5, "just under TAU stays just under: %.9f" % just_under)
	var axis := Cyl.theta_of(Vector3(0, 0, 5))
	check(axis >= 0.0 and axis < TAU, "on the axis (atan2 of signed zeros) still lands in range: %f" % axis)
```

Append to `test_macro_maps.gd` before `if failed:` (the default `p` there is the test-sized world; use a fresh default one):

```gdscript
	var d := WorldParams.new()
	check(d.cell_of(0.0, -d.length / 2.0) == Vector2i(0, 0), "first cell")
	check(d.cell_of(TAU - 1e-12, 0.0).x == d.n_theta() - 1, "just under TAU is the last column")
	check(d.cell_of(TAU, 0.0).x == 0, "TAU wraps to column 0")
	check(d.cell_of(-d.dtheta(), 0.0).x == d.n_theta() - 1, "negative angle wraps")
	check(d.cell_of(0.0, d.length).y == d.n_z() - 1 and d.cell_of(0.0, -d.length).y == 0, "z clamps to the station")
	check(d.cell_of(1.5 * d.dtheta(), 0.0) == Vector2i(1, d.n_z() / 2), "cell 1 at the middle row")
```

- [ ] **Step 2: Run them to verify they fail**

Run: `cd godot && godot --headless --path . --fixed-fps 60 --quit-after 7200 -s res://tests/test_cylinder_math.gd; godot --headless --path . --fixed-fps 60 --quit-after 7200 -s res://tests/test_macro_maps.gd`
Expected: the first fails on "angle that rounds to TAU is 0"; the second fails to parse (`cell_of` not found).

- [ ] **Step 3: Implement**

`cyl.gd`: `var t := fposmod(atan2(p.x, -p.y), TAU); return 0.0 if t >= TAU else t`. `world_params.gd`: `cell_of` as in Interfaces. `terrain.gd` `viewer_cell`: `return params.cell_of(Cyl.theta_of(p), p.z)` (drop its posmod comment; the posmod now lives in `cell_of`). `collider_patch.gd` `rebuild`: `var cell := p.cell_of(center_theta, center_z)`.

- [ ] **Step 4: Run the suite**

Run: `cd godot && sh tests/run.sh`
Expected: every test prints `PASS`.

- [ ] **Step 5: Commit**

```bash
git add godot/terrain/cyl.gd godot/terrain/world_params.gd godot/terrain/terrain.gd godot/terrain/collider_patch.gd godot/tests/test_cylinder_math.gd godot/tests/test_macro_maps.gd
git commit -m "Terrain: theta_of strictly inside [0, TAU), WorldParams.cell_of holds the wrap"
```

---

### Task 2: Topsoil thin on steep slopes (macro half)

**Files:**
- Modify: `godot/terrain/world_params.gd` (add `soil_slope_deg`), `godot/terrain/macro_generator.gd:475-535` (`_strata`)
- Test: `godot/tests/test_macro_generator.gd`

**Interfaces:**
- Consumes: `MacroMaps`, `WorldParams`.
- Produces: `@export var soil_slope_deg: float = 45` in `WorldParams` ("macro slope at which soil depth reaches zero; depth scales by 1 − tan(slope) / tan(soil_slope_deg)"). In `_strata`, before the island taper, `d *= clampf(1.0 - slope / tan(deg_to_rad(p.soil_slope_deg)), 0.0, 1.0)` where `slope = sqrt(gx² + gz²)`, `gx = (s[x+1] − s[x−1]) / (2 · (p.radius − s) · p.dtheta() · 32)` with `x ± 1` wrapped, `gz = (s[y+1] − s[y−1]) / (2 · p.macro_cell)` with `y ± 1` clamped. Cliff cells keep `d = 0`.

- [ ] **Step 1: Write the failing test**

Append to `test_macro_generator.gd` before `if failed:`:

```gdscript
	# Topsoil thins with slope: with the knob at 10 degrees the mountains' 8 m per cell bites. On every
	# non-cliff land cell, depth = min(s, lerp(d_min, d_max, noise) * f), f = clamp(1 - slope / tan 10, 0, 1).
	var thin := small_params(7); thin.soil_slope_deg = 10.0
	var mt := MacroGenerator.new().generate(thin)
	var tan_soil := tan(deg_to_rad(10.0))
	var keys := ["flat", "flat", "hill", "mountain", "hill"]
	var zeroed := 0; var checked := 0
	for y in range(1, h - 1): for x in w:
		var rg: int = mt.region.get_pixel(x, y).r8
		if rg == 0 or rg == 4 or mt.cliff.get_pixel(x, y).r8 != 0: continue
		var s := mt.surface.get_pixel(x, y).r
		var gx := (mt.surface.get_pixel((x + 1) % w, y).r - mt.surface.get_pixel(posmod(x - 1, w), y).r) / (2.0 * (thin.radius - s) * thin.dtheta() * 32.0)
		var gz := (mt.surface.get_pixel(x, y + 1).r - mt.surface.get_pixel(x, y - 1).r) / (2.0 * thin.macro_cell)
		var f := clampf(1.0 - sqrt(gx * gx + gz * gz) / tan_soil, 0.0, 1.0)
		var depth := s - mt.bedrock_top.get_pixel(x, y).r
		check(depth <= thin.bedrock_depth[keys[rg]][1] * f + 1e-3, "depth over the scaled max at %d %d: %f" % [x, y, depth])
		check(depth >= minf(s, thin.bedrock_depth[keys[rg]][0] * f) - 1e-3, "depth under the scaled min at %d %d: %f" % [x, y, depth])
		checked += 1
		if f == 0.0: zeroed += 1
	check(checked > 100 and zeroed > 0, "slope rule exercised: %d cells, %d at zero depth" % [checked, zeroed])
	check(mt.surface.get_data() == m.surface.get_data(), "the knob changes strata only")
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd godot && godot --headless --path . --fixed-fps 60 --quit-after 7200 -s res://tests/test_macro_generator.gd`
Expected: parse error, `soil_slope_deg` not found on `WorldParams`.

- [ ] **Step 3: Implement the knob and the three lines in `_strata`**

Compute the slope from the `surface` array already in `_strata` (indices wrap in `x`, clamp in `y`); apply the factor to `d` before the island taper and only where `cliff[i]` is 0. Keep the island taper and the clay lens code as they are.

- [ ] **Step 4: Run the suite**

Run: `cd godot && sh tests/run.sh`
Expected: all `PASS`, including the unchanged determinism and ordering checks (the default knob at 45° leaves the small world's existing checks as they were).

- [ ] **Step 5: Commit**

```bash
git add godot/terrain/world_params.gd godot/terrain/macro_generator.gd godot/tests/test_macro_generator.gd
git commit -m "Terrain: topsoil thins with macro slope, soil_slope_deg knob"
```

---

### Task 3: Rock face is material 3, `bedrock_top` is always the stratum (R6)

**Files:**
- Modify: `godot/terrain/material_set.gd`, `godot/terrain/materials.tres`, `godot/terrain/shaders/detail.glsl:320-332`, `godot/terrain/shaders/tile.gdshader:8-9,49`, `godot/terrain/debug_window_dump.gd:12,56`
- Test: `godot/tests/test_material_set.gd` (new)

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `MaterialSet`: `const DIRT := 0`, `const CLAY := 1`, `const ROCK := 2`, `const ROCK_FACE := 3` with the doc comment "the surface is rock because its face is steeper than 60°; the strata below are as generated"; `static func is_rock(id: int) -> bool` (`id >= ROCK`); every exported array gains a fourth entry equal to rock's, `names[3] = "rock face"`, `color[3] = color[2]`. `materials.tres` updated to match.
  - `detail.glsl`: `float bt = clamp(b + nb, 0.0, h);` (no `face ?`), and `float material = face ? 3.0 : (bt >= h - 0.01 ? 2.0 : (ctt >= h - 0.01 ? 1.0 : 0.0));`. The comment above it states the rule: material 3 marks a face; `bedrock_top` is never raised by slope.
  - `tile.gdshader`: `uniform vec4 material_color[4]`, `clamp(..., 0, 3)`.
  - `debug_window_dump.gd`: four colours (the fourth equal to rock's) and the count line gains `rock face %d`.

- [ ] **Step 1: Write the failing test**

`godot/tests/test_material_set.gd`:

```gdscript
extends SceneTree

var failed := false

func check(ok: bool, msg: String) -> void:
	if not ok:
		push_error(msg)
		failed = true

func _initialize() -> void:
	var m: MaterialSet = load("res://terrain/materials.tres")
	check(MaterialSet.ROCK_FACE == 3 and MaterialSet.ROCK == 2, "ids")
	check(m.names.size() == 4 and m.names[3] == "rock face", "names %s" % [m.names])
	for prop in ["color", "porosity", "wetting_distance", "swell_factor", "repose_dry", "repose_damp", "repose_saturated",
			"roof_span_dry", "roof_span_saturated", "stable_slope_dry", "stable_slope_saturated", "compression_index"]:
		var a = m.get(prop)
		check(a.size() == 4, "%s has 4 rows" % prop)
		check(a[3] == a[2], "%s: rock face equals rock" % prop)
	check(MaterialSet.is_rock(2) and MaterialSet.is_rock(3) and not MaterialSet.is_rock(1) and not MaterialSet.is_rock(0), "is_rock")
	if failed: quit(1)
	else: print("PASS"); quit(0)
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd godot && godot --headless --path . --fixed-fps 60 --quit-after 7200 -s res://tests/test_material_set.gd`
Expected: parse error, `ROCK_FACE` not found.

- [ ] **Step 3: Implement the resource, the shader rule and the two consumers**

Edit `materials.tres` by hand (it is a text resource); keep rock's values in row 3. In `detail.glsl` change only the two lines named above and their comment.

- [ ] **Step 4: Run the suite, then the windowed dump**

Run: `cd godot && sh tests/run.sh`
Expected: all `PASS`.

Windowed: `cd godot && godot --path . res://terrain/debug_window.tscn -- --spawn --auto`
Expected: the count line prints a non-zero `rock face` count (the spawn site is within 100 m of a river and the window holds cliff bands), `user://debug/window_material.png` shows the faces in rock's colour, no errors. Then `godot --path .`: cliffs look as before (no colour change), no errors.

- [ ] **Step 5: Commit**

```bash
git add godot/terrain/material_set.gd godot/terrain/materials.tres godot/terrain/shaders/detail.glsl godot/terrain/shaders/tile.gdshader godot/terrain/debug_window_dump.gd godot/tests/test_material_set.gd
git commit -m "Terrain: steep faces are material 3 (rock face); bedrock_top is always the stratum"
```

---

### Task 4: Hold rule test, registered bodies, the 10 s render-loop check (R5, boxes while flying)

**Files:**
- Modify: `godot/terrain/terrain.gd:16-17,44-48,187-206` (hold rule), `godot/emitter.gd` (register boxes), `godot/main.tscn` (Emitter's `terrain` path)
- Create: `godot/terrain/hold_check.gd`, `godot/terrain/hold_check.tscn`
- Test: `godot/tests/test_hold_rule.gd` (new)

**Interfaces:**
- Consumes: `ColliderPatch.covers(viewer_local: Vector3) -> bool`, `ColliderPatch.set_frame(theta, z, R)`, `Terrain.teleport(theta, z)`, `Terrain.body_held(held: bool)`, `Terrain.collider_live`.
- Produces:
  - `Terrain.register_body(body: Node3D) -> void`: adds a body to the hold rule (idempotent). `Terrain.bodies() -> Array[Node3D]`: the registered bodies still alive (freed ones are pruned by `is_instance_valid`); `_process` iterates it.
  - `Terrain._hold(body: Node3D, hold: bool) -> void`: the rule from today's `_hold_body` for any body, with `_held: Dictionary` (body → true) replacing the bool: no change when already in that state, never takes a body something else disabled, never releases one it did not hold. `_hold_body(hold)` becomes `_hold(_body, hold)` plus the `body_held` signal on a change; `_process` adds `for b in bodies(): if b != _body: _hold(b, not patch.covers(station.to_local(b.global_position)))`.
  - `Emitter`: `@export var terrain: Terrain`; `spawn()` calls `terrain.register_body(box)` when `terrain` is set. `main.tscn`'s Emitter gets `terrain = NodePath("../Terrain")`.
  - `Terrain.ground_body() -> Node3D` (returns `_body`; Task 7's stamp uses it).

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
	# covers() is the whole decision: Chebyshev 124 m in the patch plane, nothing before a frame exists.
	var patch := ColliderPatch.new()
	check(not patch.covers(Vector3(3200, 0, 300)), "no frame covers nothing")
	patch.set_frame(0.5 * PI, 300.0, 3200.0)
	check(patch.covers(patch.transform * Vector3(123, 50, -123)) and not patch.covers(patch.transform * Vector3(125, 0, 0)), "covers")
	# Terrain outside the tree: _ready never runs, so the rule is driven directly on stub bodies.
	var t := Terrain.new()
	var player := Node3D.new()
	var box := RigidBody3D.new()
	var other := Node3D.new()
	t._body = player
	t.register_body(box)
	t.register_body(box)
	t.register_body(other)
	check(t.bodies().size() == 2, "registered once each: %d" % t.bodies().size())
	var holds: Array[bool] = []
	t.body_held.connect(func(h: bool) -> void: holds.append(h))
	t._hold_body(true)
	t._hold_body(true)
	check(player.process_mode == Node.PROCESS_MODE_DISABLED and holds == [true], "ground body held, signalled once: %s" % [holds])
	t._hold_body(false)
	check(player.process_mode == Node.PROCESS_MODE_INHERIT and holds == [true, false], "released")
	# Disabled by something else (the fly camera): Terrain neither takes it nor releases it (Review Focus 4).
	player.process_mode = Node.PROCESS_MODE_DISABLED
	t._hold_body(true)
	t._hold_body(false)
	check(player.process_mode == Node.PROCESS_MODE_DISABLED and holds.size() == 2, "foreign hold kept")
	player.process_mode = Node.PROCESS_MODE_INHERIT
	# Registered bodies follow the same rule without the signal.
	t._hold(box, true)
	check(box.process_mode == Node.PROCESS_MODE_DISABLED and holds.size() == 2, "box held silently")
	t._hold(box, false)
	check(box.process_mode == Node.PROCESS_MODE_INHERIT, "box released")
	# A freed body drops out (Review Focus 4).
	other.free()
	check(t.bodies().size() == 1 and t.bodies()[0] == box, "freed body pruned")
	for n in [t, player, box, patch]: n.free()
	if failed: quit(1)
	else: print("PASS"); quit(0)
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd godot && godot --headless --path . --fixed-fps 60 --quit-after 7200 -s res://tests/test_hold_rule.gd`
Expected: parse error, `register_body` not found.

- [ ] **Step 3: Implement the rule, the emitter hook and the windowed driver**

`terrain.gd`: as in Interfaces; `_held` is a Dictionary; `bodies()` prunes in place. `emitter.gd` and `main.tscn`: as in Interfaces.

`godot/terrain/hold_check.gd` (`extends Node`, modelled on `smoke_run.gd`: instantiate `main.tscn`, find `Station`, `Terrain`, `Player`, `Emitter`; feed keys through `Input.parse_input_event`), on `hold_check.tscn`. After `collider_live`:
1. Wait 1 s of frames. `emitter.count = 1; emitter.spawn()`; wait 2 s (the box lands 10 m below its spawn and rests); record `box_at = box.position`.
2. `p = station.to_local(player.global_position)`; `terrain.teleport(Cyl.theta_of(p) + 100.0 / (R - Cyl.height_of(p, R)), p.z)` (100 m spinward: still covered, so the body is stood at once); wait 1 s (the 64 m rule rebakes around the player; the box, 100 m back, stays covered).
3. `RenderingServer.render_loop_enabled = false`. Hold `KEY_W` for 10 s of frame time (the player faces spinward; the patch edge is 24 m ahead). Every frame record the player's clearance over the macro surface (as `smoke_run._clearance`) and whether `body_held(true)` has fired.
4. Release `KEY_W`; `RenderingServer.render_loop_enabled = true`; wait 3 s.
5. Print one line per check and `PASS` or `FAIL`, then `quit(0)` or `quit(1)`:
   - held fired within the 10 s, and the player's `process_mode` was `DISABLED` at the end of them;
   - the player's clearance never went below −1 m (it did not fall) and the hold happened within 2 m of the patch edge (`patch.covers` false at the hold frame, true the frame before);
   - after step 4 the player is `INHERIT`, clearance in [−1, 5] m (released and stood on the new patch), and `body_held(false)` fired;
   - the box, now about 224 m from the new patch centre, is `DISABLED` and `box.position.distance_to(box_at) < 0.05` (held, not fallen).

- [ ] **Step 4: Run the suite, then the driver**

Run: `cd godot && sh tests/run.sh`
Expected: all `PASS`, `test_emitter.gd` unchanged (its emitter has no `terrain`).

Windowed: `cd godot && godot --path . res://terrain/hold_check.tscn`
Expected: a frozen window for 10 s, then the four lines and `PASS`, exit code 0, no errors. Then `godot --path .`: spawn a few boxes, press F, fly 300 m away, fly back: the boxes are where they were, not on the hull.

- [ ] **Step 5: Commit**

```bash
git add godot/terrain/terrain.gd godot/emitter.gd godot/main.tscn godot/terrain/hold_check.gd godot/terrain/hold_check.tscn godot/tests/test_hold_rule.gd
git commit -m "Terrain: hold rule test and 10 s render-loop check; registered bodies are held off-patch"
```

---

### Task 5: Edit layer: override blocks, writes, discs, world files (R1, CPU half)

**Files:**
- Create: `godot/terrain/edit_layer.gd`
- Modify: `godot/terrain/world_io.gd`
- Test: `godot/tests/test_edit_layer.gd` (new)

**Interfaces:**
- Consumes: `TerrainWindow.FIELDS`, `TerrainWindow.TILE`, `WorldParams.h_sea`, `h_mtn()`, `n_theta()`, `n_z()`.
- Produces `class_name EditLayer extends RefCounted`:
  - `const STRIDE := 32`, `const CELLS := TerrainWindow.TILE * TerrainWindow.TILE`, `const BLOCK_SIZE := CELLS * STRIDE` (524288). Cell layout at byte offset `o`: `o + 0` u32 mask; `o + 4, 8, 12, 16, 20` f32 `surface`, `bedrock_top`, `clay_bottom`, `clay_top`, `water_surface`; `o + 24, 25, 26` u8 `material`, `compaction`, `saturation`; `o + 27..31` zero. The comment on `STRIDE` names the 16-byte layout (heights as `u16` 1/32 m pairs) as the shrink if memory at 1024 ever matters.
  - `static func bit(field: String) -> int` = `1 << TerrainWindow.FIELDS.find(field)`.
  - `static func offset_of(cell: Vector2i) -> int` = `((cell.y % TILE) * TILE + cell.x % TILE) * STRIDE`; `static func tile_of(cell: Vector2i) -> Vector2i` = `cell / TILE` (integer division; `cell.x` is already in `[0, n_theta)`).
  - `func setup(p: WorldParams, world_name: String) -> void`.
  - `func block(tile: Vector2i) -> PackedByteArray`: the tile's block, loaded from disk on first use and cached; an empty array when the tile has none. `func has_block(tile) -> bool`.
  - `func write(cells: Array[Vector2i], field: String, values: PackedFloat32Array) -> Array[Vector2i]`: for each cell sets the field's bit and value in its tile's block (allocating a zeroed block when needed), marks the tile dirty, returns the touched tiles without duplicates. Heights are clamped to `[0, h_sea + h_mtn()]`, `material` to `[0, 3]`, `compaction` and `saturation` to `[0, 255]`, u8 fields rounded.
  - `func cell_value(cell: Vector2i, field: String) -> Variant`: the override as a float, or `null` when the cell has no override of that field.
  - `func release(tile: Vector2i) -> void`: saves the block if dirty, drops it from memory. `func flush() -> Error`: saves every dirty block, clears dirty flags, returns the first error.
  - `static func disc_cells(center: Vector2i, radius: float, n_theta: int, n_z: int) -> Array[Vector2i]`: every cell whose centre offset `(dx, dy)` satisfies `dx² + dy² ≤ radius²`, `x` wrapped to `[0, n_theta)`, cells with `y` outside `[0, n_z)` dropped.
- Produces in `WorldIO`: `const EDITS_MAGIC := 0x45544741`, `const EDITS_VERSION := 1`; `static func tile_edits_path(name: String, tile: Vector2i) -> String` (`user://worlds/<name>/tiles/<ti>_<tj>.edits`); `static func save_tile_edits(name: String, tile: Vector2i, block: PackedByteArray) -> Error` (`make_dir_recursive_absolute` on the tiles dir, `FileAccess.open_compressed(path, WRITE, COMPRESSION_ZSTD)`, four `store_32` (magic, version, stride, cell count) then `store_buffer`); `static func load_tile_edits(name: String, tile: Vector2i) -> PackedByteArray` (empty when the file is missing; empty with one `push_warning` naming the path when the header or the body length is wrong).

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
	var e := EditLayer.new()
	e.setup(p, "test_edits")
	check(EditLayer.STRIDE == 32 and EditLayer.BLOCK_SIZE == 128 * 128 * 32, "block size")
	check(EditLayer.bit("surface") == 1 and EditLayer.bit("material") == 32 and EditLayer.bit("saturation") == 128, "bits")
	check(EditLayer.offset_of(Vector2i(129, 130)) == (2 * 128 + 1) * 32 and EditLayer.tile_of(Vector2i(129, 130)) == Vector2i(1, 1), "addressing")
	check(e.block(Vector2i(1, 1)).is_empty() and not e.has_block(Vector2i(1, 1)) and e.cell_value(Vector2i(129, 130), "surface") == null, "nothing yet")
	# One cell: its bit and value land in the block, which now exists.
	var touched := e.write([Vector2i(129, 130)], "surface", PackedFloat32Array([450.5]))
	check(touched == [Vector2i(1, 1)], "touched %s" % [touched])
	var b := e.block(Vector2i(1, 1))
	var o := EditLayer.offset_of(Vector2i(129, 130))
	check(b.size() == EditLayer.BLOCK_SIZE and b.decode_u32(o) == 1 and b.decode_float(o + 4) == 450.5, "cell bytes")
	check(e.cell_value(Vector2i(129, 130), "surface") == 450.5 and e.cell_value(Vector2i(129, 130), "bedrock_top") == null, "cell_value")
	e.write([Vector2i(129, 130)], "material", PackedFloat32Array([2.0]))
	check(b.decode_u32(o) == 33 and b.decode_u8(o + 24) == 2, "second field adds its bit, u8 in its byte")
	# Clamps (Review Focus 3).
	e.write([Vector2i(129, 131), Vector2i(129, 132)], "surface", PackedFloat32Array([1e9, -5.0]))
	e.write([Vector2i(129, 133)], "material", PackedFloat32Array([9.0]))
	check(absf(e.cell_value(Vector2i(129, 131), "surface") - (p.h_sea + p.h_mtn())) < 1e-3, "surface capped at h_max")
	check(e.cell_value(Vector2i(129, 132), "surface") == 0.0 and e.cell_value(Vector2i(129, 133), "material") == 3.0, "floor and material cap")
	# A disc across the seam and a tile boundary touches four tiles (Review Focus 1).
	var disc := EditLayer.disc_cells(Vector2i(0, 128), 2.0, p.n_theta(), p.n_z())
	check(disc.size() == 13, "radius 2 disc has 13 cells: %d" % disc.size())
	check(disc.has(Vector2i(16382, 128)) and disc.has(Vector2i(16383, 127)) and disc.has(Vector2i(1, 129)) and disc.has(Vector2i(0, 126)), "wraps in theta")
	var v := PackedFloat32Array(); v.resize(disc.size()); v.fill(500.0)
	var tiles := e.write(disc, "surface", v)
	tiles.sort()
	check(tiles == [Vector2i(0, 0), Vector2i(0, 1), Vector2i(127, 0), Vector2i(127, 1)], "four tiles: %s" % [tiles])
	var end := EditLayer.disc_cells(Vector2i(5, p.n_z() - 1), 2.0, p.n_theta(), p.n_z())
	check(end.size() == 9, "cells past the station end are dropped: %d" % end.size())
	for c in end: check(c.y < p.n_z() and c.y >= p.n_z() - 3, "end row %s" % c)
	# Disk: flush, reload in a fresh layer, release and reload again.
	check(e.flush() == OK and FileAccess.file_exists(WorldIO.tile_edits_path("test_edits", Vector2i(1, 1))), "flushed")
	var e2 := EditLayer.new()
	e2.setup(p, "test_edits")
	check(e2.block(Vector2i(1, 1)) == b and e2.cell_value(Vector2i(129, 130), "surface") == 450.5, "round trip")
	e2.release(Vector2i(1, 1))
	check(e2.block(Vector2i(1, 1)) == b, "reloaded after release")
	check(e2.block(Vector2i(2, 2)).is_empty(), "a tile with no file stays empty")
	# Corrupt files are ignored with a warning (Review Focus 2).
	var path := WorldIO.tile_edits_path("test_edits", Vector2i(3, 3))
	var f := FileAccess.open_compressed(path, FileAccess.WRITE, FileAccess.COMPRESSION_ZSTD)
	for word in [WorldIO.EDITS_MAGIC, WorldIO.EDITS_VERSION, 32, 16384]: f.store_32(word)
	f.store_buffer(PackedByteArray([1, 2, 3]))
	f.close()
	check(WorldIO.load_tile_edits("test_edits", Vector2i(3, 3)).is_empty(), "truncated file ignored")
	f = FileAccess.open_compressed(path, FileAccess.WRITE, FileAccess.COMPRESSION_ZSTD)
	for word in [0xdeadbeef, 1, 32, 16384]: f.store_32(word)
	f.store_buffer(b)
	f.close()
	check(WorldIO.load_tile_edits("test_edits", Vector2i(3, 3)).is_empty(), "wrong magic ignored")
	# Clean up the test world.
	var dir := ProjectSettings.globalize_path("user://worlds/test_edits/tiles")
	for fn in DirAccess.get_files_at(dir): DirAccess.remove_absolute(dir.path_join(fn))
	DirAccess.remove_absolute(dir)
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://worlds/test_edits"))
	if failed: quit(1)
	else: print("PASS"); quit(0)
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd godot && godot --headless --path . --fixed-fps 60 --quit-after 7200 -s res://tests/test_edit_layer.gd`
Expected: parse error, `EditLayer` not found.

- [ ] **Step 3: Implement `EditLayer` and the two `WorldIO` functions**

`write` loops over its cells (a tool's stamp, tens of cells) with `encode_u32`, `encode_float`, `encode_u8`; nothing else in the class loops over cells. `block` allocates with `resize(BLOCK_SIZE)` then `fill(0)`. The corrupt-file warning is a `push_warning` (run.sh treats warnings as noise).

- [ ] **Step 4: Run the suite**

Run: `cd godot && sh tests/run.sh`
Expected: all `PASS`; one `WARNING` line from the corrupt-file checks is fine.

- [ ] **Step 5: Commit**

```bash
git add godot/terrain/edit_layer.gd godot/terrain/world_io.gd godot/tests/test_edit_layer.gd
git commit -m "Terrain: edit layer of absolute per-cell override blocks, saved per tile"
```

---

### Task 6: The apply pass: edits reach the window in the detail pass's compute list (R1, GPU half)

**Files:**
- Create: `godot/terrain/shaders/edit_apply.glsl`
- Modify: `godot/terrain/terrain_window.gd` (edits, per-slot buffers, `_dispatch`, `apply_edits`, `is_resident`), `godot/terrain/terrain.gd:57-77` (`_ready` attaches the layer; `_exit_tree` flushes), `godot/terrain/far_terrain.gd:1-6` (R4 comment), `godot/terrain/debug_window.gd` (`--edits`, `--stamp`, the away-and-back `--auto`), `godot/terrain/timing_overlay.gd:12` (an `edit` pass)
- Test: none headless (RD work); the windowed dump below.

**Interfaces:**
- Consumes: `EditLayer.block / has_block / release / write / disc_cells / BLOCK_SIZE`, `WorldParams.cell_of`, `h_mtn()`.
- Produces:
  - `TerrainWindow.edits: EditLayer` (null means no edits: the far window). `func is_resident(tile: Vector2i) -> bool`. `func apply_edits(tile: Vector2i) -> void`: when `edits` is set, the tile is resident and has a block, queues on the render thread a `buffer_update` of the whole block into the slot's storage buffer and one compute list with a single `edit_apply.glsl` dispatch of `16 × 16` groups, bracketed by `capture_timestamp("edit_begin")` and `"edit_end"`; otherwise nothing.
  - `move_to`: for each slot whose resident changes, `edits.release(previous)` (when `edits` is set and a previous tile existed), and the entering tile's block (if any) goes with the dirty list to `_dispatch(tiles, blocks: Dictionary)`. `_dispatch`: all `buffer_update`s first (`buffer_update` is refused inside a compute list), then one list: the detail dispatches, `compute_list_add_barrier`, then one apply dispatch per tile with a block. The `detail_begin/end` pair stays around the whole list (an apply is a few hundredths of a millisecond; the live path measures it alone).
  - Storage buffers: `_edit_buffers: Dictionary` slot → RID (`storage_buffer_create(EditLayer.BLOCK_SIZE)`), `_edit_sets` slot → RID (set 0 of the apply shader), both created on first use for that slot and freed with the window; `_edit_window_set: RID` (set 1: the eight window images, created in `_setup_rd` for every window); `_edit_shader` and `_edit_pipeline` compiled in `_upload_macro` next to detail's and shared with the far window like them.
  - `edit_apply.glsl`: `local_size 8 × 8`; set 0 binding 0 `std430 readonly buffer { uint data[]; }`, eight `uint`s per cell in the Task 5 layout; set 1 bindings 0–7 the window images (`r32f` × 5, `r8` × 3, read-write); push constants `ivec2 origin; float h_max; float pad` (16 bytes). Per cell: `mask = data[c]`; return when 0; load the eight current values; replace each field whose bit is set (`uintBitsToFloat` for heights, `(data[c + 6] >> 8k) & 0xff` for the u8 fields); then `s = clamp(s, 0, h_max)`, `bt = clamp(bt, 0, s)`, `cb = clamp(cb, bt, s)`, `ct = clamp(ct, cb, s)`; `material` is derived as `detail.glsl` does (2 if `bt >= s − 0.01`, 1 if `ct >= s − 0.01`, else 0) unless bit 32 is set; store all eight.
  - `Terrain._ready`: after `window.setup`, `window.edits = EditLayer.new(); window.edits.setup(params, world_name)` (before `_move_window`). `Terrain._exit_tree`: `window.edits.flush()`.
  - `far_terrain.gd` doc comment gains: "Level 1 regenerates from the macro maps and shows no edits: beyond 256 m a hand edit is a dot. If earthworks ever pass 8 m, the dig slice downsamples the edit layer into it."
  - `timing_overlay.gd`: `_gpu` gains `"edit"`.
  - `debug_window.gd`: `--edits` attaches `EditLayer` with world name `debug_edits` (its files go to `user://worlds/debug_edits/tiles/`, separate from the default world's); `--stamp` (with `--edits`) writes a disc of radius 6 cells at `1500.0` m on `surface` (under `h_max`, above any peak near the spawn) around the window's centre cell before `move_to`; `--auto` with `--edits` dumps at frame 5, moves the window 4 tiles spinward at 10 (every tile leaves; dirty blocks are written), back at 15, dumps again at 20 and quits at 25.

- [ ] **Step 1: Write the shader and the window changes**

Follow decision 3 and the Interfaces block. Uniform sets for set 1 of the apply shader are created once per window from the same image RIDs as detail's set 1.

- [ ] **Step 2: Run the headless suite**

Run: `cd godot && sh tests/run.sh`
Expected: all `PASS` (nothing GPU-side runs headless; this catches parse errors in the window and Terrain).

- [ ] **Step 3: Windowed check: an edit is drawn, survives eviction and a restart, and the far window ignores it**

Run: `cd godot && godot --path . res://terrain/debug_window.tscn -- --spawn --edits --stamp --auto`
Expected: two `window surface min .. max` lines, both with `max` ≥ 1499.9 (the first after the detail list applied the block, the second after every tile left and came back from disk); `user://debug/window_surface.png` shows a white disc at the centre; no errors.

Run: `cd godot && godot --path . res://terrain/debug_window.tscn -- --spawn --edits --auto`
Expected: a fresh process, nothing stamped: both lines still show `max` ≥ 1499.9 (loaded from `user://worlds/debug_edits/tiles/`).

Run: `cd godot && godot --path . res://terrain/debug_window.tscn -- --spawn --auto`
Expected: no edit layer: `max` under 1499 (the spawn is a flat cell near a river; no peak that high is within 256 m of it). Delete `user://worlds/debug_edits/` afterwards.

Run: `cd godot && godot --path .`
Expected: the game runs as before, no errors; the overlay shows `edit n/a` (no live edit yet).

- [ ] **Step 4: Commit**

```bash
git add godot/terrain/shaders/edit_apply.glsl godot/terrain/terrain_window.gd godot/terrain/terrain.gd godot/terrain/far_terrain.gd godot/terrain/debug_window.gd godot/terrain/timing_overlay.gd
git commit -m "Terrain: edit blocks applied after the detail pass in its compute list; live apply path"
```

---

### Task 7: Collider bake in two passes, dirty flag and rebake throttle (R3, occupancy)

**Files:**
- Create: `godot/terrain/shaders/collider_map.glsl`
- Modify: `godot/terrain/shaders/collider_bake.glsl` (rewritten as the resample pass), `godot/terrain/collider_patch.gd`, `godot/terrain/smoke_run.gd` (a `bakecheck` phase)
- Test: `godot/tests/test_hold_rule.gd` (throttle checks appended)

**Interfaces:**
- Consumes: `Cyl.bake_row` (the CPU reference, unchanged), `TerrainWindow.is_resident`, `texture_rid("surface")`, `macro_rid/macro_sampler`.
- Produces:
  - `collider_map.glsl` (pass A): `local_size 8 × 8`; set 0: binding 0 `w_surface` (`r32f` readonly), 1 `m_surface` sampler, 2 `o_mapped` (`rg32f` writeonly, `(2 · half_n + 1) × 257`); push constants exactly today's `Params` block. Invocation `(k, j)` with `k < 2 · half_n + 1`, `j < 257`: `h = surface(center.x + k − half_n, center.y + j − 128)` (today's `surface()` with its window-or-macro rule), `φ = (k − half_n) · dtheta`, stores `(x, y) = ((R − h) sin φ, h + 2 (R − h) sin²(φ / 2))`.
  - `collider_bake.glsl` (pass B): `local_size 8 × 8` over `257 × 257`; set 0: binding 0 `mapped` (`rg32f` readonly), 1 `o_patch` (`r32f` writeonly); push constants `int n; int pad0; int pad1; int pad2` (16 bytes; `n = 2 · half_n + 1`); `const int SCAN = 16`. Column `(i, j)`, `x = i − 128`: binary search row `j` of `mapped` for the last `k` with `mapped[k].x ≤ x` treating the row as monotone; then over segments `(a, a + 1)` for `a` in `[k − SCAN, k + SCAN]` clipped to `[0, n − 2]`, where `min(x_a, x_{a+1}) ≤ x ≤ max(...)`, take the highest `y` (a vertical segment contributes `max(y_a, y_{a+1})`, as `Cyl.bake_row`); if no segment covers `x`, `y = x < mapped[0].x ? mapped[0].y : mapped[n − 1].y`. The shader comment states the bound: a fold-back at arc angle `φ ≤ half_n · dtheta` shifts `x` by at most `H sin φ`, under 16 samples for faces up to 200 m at the patch edge, so `SCAN = 16` reaches every segment covering `x`; a taller face at the very edge loses only its overhang envelope, never its surface.
  - `collider_patch.gd`: `_half_n` computed once in `_setup_rd` (today's expression, which depends on the world only), `_mapped: RID` (`R32G32_SFLOAT`, `STORAGE`), two shaders, two pipelines, two uniform sets; `_bake` records one list: map dispatch of `(ceil(n / 8), 33, 1)` groups, `compute_list_add_barrier`, bake dispatch of `(33, 33, 1)`, with `bake_begin` / `bake_end` around the list; readback unchanged.
  - Edit support: `const EDIT_REBAKE_INTERVAL := 0.1` (s); `func mark_dirty() -> void`; `func edit_bake_due(now_s: float) -> bool` = `_dirty and not _pending and now_s − _last_bake_s >= EDIT_REBAKE_INTERVAL`; `rebuild` clears `_dirty` and sets `_last_bake_s = Time.get_ticks_msec() / 1000.0` when it starts a bake; `var last_assign_ms: float`, the wall time of the `map_data` assignment in `_landed` (`Time.get_ticks_usec()` around it), for Task 9.
  - `smoke_run.gd`: a `bakecheck` phase right after `hold`: reads the window's `surface` texture once (`texture_get_data`, synchronous, debug only), takes `patch.center`, `_shape.map_data` (through a new `ColliderPatch.map_data() -> PackedFloat32Array`) and `_half_n` (through `half_n()`), and for rows `j` in `[0, 128, 256]` builds `h[k]` for `k` in `[−half_n, half_n]` from the window texel when `window.is_resident(window.tile_of_cell(i, j_cell))` and from `maps.sample(maps.surface, θ, z, params)` at the cell centre otherwise, runs `Cyl.bake_row(h, params.dtheta(), params.radius, 1.0, 257)` and records the largest `|reference − map_data[j · 257 + i]|`. The summary prints `bake check: max diff %.4f m over rows 0, 128, 256` and the run exits 1 if it is over 0.01.

- [ ] **Step 1: Write the failing throttle test**

Append to `test_hold_rule.gd` before the `free` loop (reuse its `patch`):

```gdscript
	# Edit rebake throttle (Review Focus 5): dirty and idle is due; in flight is not; dirty survives a
	# bake that is already running, so a second one follows; the interval is 0.1 s.
	check(not patch.edit_bake_due(100.0), "clean patch not due")
	patch.mark_dirty()
	check(patch.edit_bake_due(100.0), "dirty idle patch due")
	patch._pending = true
	check(not patch.edit_bake_due(100.0), "not due while a bake is in flight")
	patch._pending = false
	patch._last_bake_s = 100.0
	check(not patch.edit_bake_due(100.05) and patch.edit_bake_due(100.1), "0.1 s between edit rebakes")
	check(ColliderPatch.EDIT_REBAKE_INTERVAL == 0.1, "interval")
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd godot && godot --headless --path . --fixed-fps 60 --quit-after 7200 -s res://tests/test_hold_rule.gd`
Expected: parse error, `edit_bake_due` not found.

- [ ] **Step 3: Implement the two shaders, the patch changes and the bakecheck phase**

Port today's `surface()` into `collider_map.glsl` unchanged. Pass B's search and scan are the one body the Interfaces block spells out; keep `NONE = -1e30` as the "uncovered" marker.

- [ ] **Step 4: Run the suite, then the short smoke run on both drivers**

Run: `cd godot && sh tests/run.sh`
Expected: all `PASS`.

Windowed: `cd godot && godot --path . --rendering-driver vulkan res://terrain/smoke.tscn -- --legs=5`
Expected: `bake check: max diff` under 0.01 m; `bake:` max under 0.2 ms (budget 1 ms; the follow-ups predicted under 0.1); no `FELL THROUGH`; 0 error lines. Then the same without `--rendering-driver vulkan` (Metal): `bake check` passes, GPU times `n/a`, 0 error lines.

- [ ] **Step 5: Commit**

```bash
git add godot/terrain/shaders/collider_map.glsl godot/terrain/shaders/collider_bake.glsl godot/terrain/collider_patch.gd godot/terrain/smoke_run.gd godot/tests/test_hold_rule.gd
git commit -m "Terrain: collider bake as map and resample passes; dirty flag and edit rebake throttle"
```

---

### Task 8: `Terrain.write_cells`, the debug stamp, the collider follows edits

**Files:**
- Create: `godot/terrain/debug_edit.gd`
- Modify: `godot/terrain/terrain.gd` (`write_cells`, `cell_height`, the edit rebake in `_process`), `godot/main.tscn` (a `DebugEdit` node)
- Test: `godot/tests/test_edit_layer.gd` (stamp values appended)

**Interfaces:**
- Consumes: `EditLayer.write / cell_value / disc_cells`, `TerrainWindow.apply_edits`, `ColliderPatch.covers / surface_point / mark_dirty / edit_bake_due / rebuild / center`, `Terrain.ground_body()`, `WorldParams.cell_of`, `Cyl.theta_of / height_of / position`.
- Produces:
  - `Terrain.write_cells(cells: Array[Vector2i], field: String, values: PackedFloat32Array) -> void`: `window.edits.write`, then `window.apply_edits(t)` for each touched tile, then `patch.mark_dirty()` if the hull point of any cell (`Cyl.position((c.x + 0.5) · dtheta, −length / 2 + c.y + 0.5, 0, R)`) is covered by the patch. Doc comment: "Absolute overrides of `field` at world cells: drawn next frame, stood on within a few frames, saved with the world. The tool API; the tools themselves are the dig slice's."
  - `Terrain.cell_height(cell: Vector2i) -> float`: the `surface` override when the cell has one; else, when the patch covers the cell's hull point, `Cyl.height_of(patch.surface_point(hull_point, 0.0), R)`; else `height_at(θ, z)` from the macro maps.
  - `Terrain._process`: after the existing rebuild check, `if patch.edit_bake_due(Time.get_ticks_msec() / 1000.0): patch.rebuild(window, patch.center.x, patch.center.y)` (same centre: `covers` is unchanged while it is in flight, decision 7).
  - `class_name DebugEdit extends Node` with `@export var terrain: Terrain`, `const RADIUS := 3.0`, `const STEP := 1.0`, `const AHEAD := 4.0`; `_unhandled_key_input`: `KEY_BRACKETLEFT` → `stamp(-STEP)`, `KEY_BRACKETRIGHT` → `stamp(STEP)` (pressed, not echo); `func stamp(delta: float) -> void`: the centre is `terrain.params.cell_of(Cyl.theta_of(p), p.z)` with `p = station.to_local(body.global_position − body.global_basis.z · AHEAD)` and `body = terrain.ground_body()`; `cells = EditLayer.disc_cells(centre, RADIUS, n_theta, n_z)`; `values = stamp_values(cells, terrain.cell_height, delta)`; `terrain.write_cells(cells, "surface", values)`. `static func stamp_values(cells: Array[Vector2i], height_of: Callable, delta: float) -> PackedFloat32Array` (each `height_of.call(cell) + delta`). Doc comment: "Debug only: lowers or raises a disc ahead of the ground body to exercise the edit pipeline. The real tools are the dig slice's."
  - `main.tscn`: `[node name="DebugEdit" type="Node" parent="."]` with `script` `debug_edit.gd` and `terrain = NodePath("../Station/Terrain")`, next to `ClickTeleport`.

- [ ] **Step 1: Write the failing test**

Append to `test_edit_layer.gd` before the clean-up:

```gdscript
	# The debug stamp is relative to whatever height its callable reports, cell by cell.
	var sv := DebugEdit.stamp_values([Vector2i(1, 2), Vector2i(3, 4)], func(c: Vector2i) -> float: return 10.0 * c.x, -1.0)
	check(sv == PackedFloat32Array([9.0, 29.0]), "stamp values %s" % [sv])
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd godot && godot --headless --path . --fixed-fps 60 --quit-after 7200 -s res://tests/test_edit_layer.gd`
Expected: parse error, `DebugEdit` not found.

- [ ] **Step 3: Implement the API, the stamp and the scene node**

As in Interfaces. `write_cells` loops over its cells for the `covers` test (tens of cells, once per edit).

- [ ] **Step 4: Run the suite, then the windowed loop**

Run: `cd godot && sh tests/run.sh`
Expected: all `PASS`.

Windowed: `cd godot && godot --path . --rendering-driver vulkan`
Expected, in order: stand at the spawn site, press `[` five times: a pit about 6 m wide and 5 m deep appears 4 m ahead within a frame; walk into it: the player drops to its floor (the collider followed within a few frames; the overlay shows `edit` under 0.1 ms and `bake` under 1 ms); press `]` five times from inside: the floor rises back and the player ends on it; walk 600 m spinward and back (the pit's tile leaves the window once the viewer is three tiles away, and returns): the pit is still there, drawn and walkable; quit and run again: still there. On a slope the first `[` is within about 0.2 m of 1 m deep (decision 14). No errors. Delete the pit with `]` or remove `user://worlds/default/tiles/*.edits` to restore the world.

- [ ] **Step 5: Commit**

```bash
git add godot/terrain/debug_edit.gd godot/terrain/terrain.gd godot/main.tscn godot/tests/test_edit_layer.gd
git commit -m "Terrain: write_cells edit API, debug stamp on [ and ], collider rebakes after edits"
```

---

### Task 9: Measurement, budgets and notes for the next slice

**Files:**
- Modify: `godot/terrain/smoke_run.gd` (an `edit` phase and its summary lines), `docs/terrain-research.md` (measurements under 6.8)
- Create: `docs/superpowers/plans/2026-10-27-terrain-edits-followups.md`

**Interfaces:**
- Consumes: `DebugEdit` (keys through `Input.parse_input_event`), `ColliderPatch.live`, `last_assign_ms`, the `edit` and `bake` timestamp pairs via `timing_overlay.timed`.
- Produces: `smoke_run.gd` phase `edit` between `axial` and `flight`: standing still, 25 presses of `[` then 25 of `]` at 0.1 s intervals (net zero change), collecting the `edit` list times, the `bake` times in the phase, `last_assign_ms` at every `live`, the frames between a press and the next `live` (collider lag), and the frame intervals of the phase. New summary lines: `edit apply: n, median, max ms (budget 0.1)`, `map_data assign: mean, max ms (budget 4)`, `collider lag: max N frames`, and the phase row's `(k over 16)` count.

- [ ] **Step 1: Write the phase and run the measurement**

Run: `cd godot && godot --path . --rendering-driver vulkan res://terrain/smoke.tscn -- --legs=20`
Expected (M1 Max, 1440p, 512 window), each measured as stated:

| item | budget | measured by |
|---|---|---|
| detail per tile | under 2 ms | `per tile max` from the `detail` pairs over the run's window moves |
| bake (both passes) | under 1 ms, expected under 0.2 | `bake:` max over the run (the `bake_begin/end` pair now spans map and resample) |
| edit apply | under 0.1 ms | `edit apply:` max over the 50 live applies |
| GPU frame mean | under 6 ms | `GPU mean` of all frames (`viewport_get_measured_render_time_gpu`) |
| frame hitch | under 4 ms | `map_data assign:` max; and `0 over 16` frame intervals in the `edit` phase |
| collider lag | a few frames | `collider lag:` max, expected 3 to 4 (0.1 s throttle plus `frame_queue_size`) |
| bake check | under 0.01 m | `bake check:` max diff |
| errors | none | 0 lines starting with `ERROR` |

Then `godot --path . res://terrain/smoke.tscn -- --legs=20` on Metal: GPU `n/a`, the CPU lines and `bake check` as above, 0 errors. If a budget is missed, record the number; do not tune in this task.

- [ ] **Step 2: Run the whole headless suite one last time**

Run: `cd godot && sh tests/run.sh`
Expected: all `PASS`.

- [ ] **Step 3: Record the measurements and the follow-ups**

`docs/terrain-research.md`, under the slice 1 table in 6.8: "Edits slice measurements, 2026-xx-xx, M1 Max": the rows above with their numbers, five lines at most, and any budget missed.

`docs/superpowers/plans/2026-10-27-terrain-edits-followups.md`, in the style of the slice 1 follow-ups, with these entries (each a paragraph, no more):
- **GPU-authoritative blocks for the real tools.** Tools upload op lists (cell, field, relative delta); one kernel applies them to the window and writes the absolute result into the slot's block; the block is read back with `buffer_get_data_async` when its tile leaves, so the CPU copy is a mirror. Needs a pool of slot buffers larger than the slot count so a leaving tile's buffer is not reused before its readback lands. `EditLayer`'s on-disk format and `edit_apply.glsl` are unchanged by it.
- **Second collider patch per rigid body.** A second `ColliderPatch` instance centred on the nearest registered body that the viewer's patch does not cover, rebuilt on the same 64 m rule, 2.8 ms CPU plus one bake per move; `Terrain.bodies()` and `_hold` already hold the list and the rule, so the change is `covers` over a list of patches. Until then uncovered bodies are held (Task 4).
- **Edit-zone heightfield.** If a continuous tool makes the 2.8 ms `map_data` assignment visible: a 33 × 33 `HeightMapShape3D` on a second body over the tool's zone, NaN in the big patch's samples under it (written by pass B from a zone rect push constant), rebuilt per edit at about 0.05 ms; the seam between the bodies is the risk to test first.
- **Far window and edits (R4).** Unchanged: regenerated from the macro maps, so edits are invisible beyond 256 m; a downsample of the edit block's `surface` into the 8 m window is the fix if earthworks pass 8 m.
- **Block layout.** 32 bytes per cell; the 16-byte layout (heights as 1/32 m `u16` pairs) halves the 1024-window worst case of 32 MB.
- Anything the measurement run showed.

- [ ] **Step 4: Commit**

```bash
git add godot/terrain/smoke_run.gd docs/terrain-research.md docs/superpowers/plans/2026-10-27-terrain-edits-followups.md
git commit -m "Terrain: smoke run edit phase, edits slice measurements and follow-ups"
```

---

## Self-review notes

- Scope coverage against the follow-ups doc: R1 (Tasks 5, 6, 8), R3 with the bake occupancy item (Task 7, measured in 9), R4 (decision 8, the comment in Task 6, the follow-ups in Task 9), R5 (Task 4), R6 (Task 3), R7 (Task 1), topsoil (Task 2), second patch per body (decision 10, Task 4's hold, Task 9's sketch). The slice's goal statement is exercised end to end by Task 8's windowed loop and measured in Task 9.
- Names used across tasks: `EditLayer.write / block / has_block / release / flush / cell_value / disc_cells / offset_of / tile_of / bit / STRIDE / BLOCK_SIZE`, `WorldIO.tile_edits_path / save_tile_edits / load_tile_edits / EDITS_MAGIC / EDITS_VERSION`, `TerrainWindow.edits / is_resident / apply_edits`, `ColliderPatch.mark_dirty / edit_bake_due / EDIT_REBAKE_INTERVAL / last_assign_ms / map_data / half_n`, `Terrain.write_cells / cell_height / register_body / bodies / ground_body / _hold / _hold_body`, `DebugEdit.stamp / stamp_values`, `MaterialSet.ROCK_FACE / is_rock`, `WorldParams.cell_of / soil_slope_deg`, `Cyl.theta_of`.
- Deviations stated: the `detail_begin/end` pair includes the apply dispatches on window moves (decision 3's same-list rule; the live path measures the apply alone). `Terrain` tests set `_body`, `_pending` and `_last_bake_s` directly because `_ready` and `rebuild` need a station or a `RenderingDevice`.
