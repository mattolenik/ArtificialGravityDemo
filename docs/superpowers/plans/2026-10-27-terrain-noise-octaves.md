# Terrain Noise Octaves Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn off the detail-noise octaves that alias on the 1 m window, keep the look of flats, hills and bare rock by re-tuning the remaining amplitudes, measure the collider-to-mesh mismatch before and after, and put every noise knob in `WorldParams` so the user tunes by eye without a shader edit.

**Architecture:** `detail.glsl` keeps its octave loop and its `if (float(s) < pc.cell) break`; the per-octave weights, the per-region amplitudes and the bare-rock multiplier move from shader constants to `WorldParams` fields that `TerrainWindow._push_constants` packs (64 to 112 bytes), so a weight of 0 is how an octave is dropped and both windows (1 m and 8 m) read the same values. A short windowed driver, `noise_report.tscn`, parks the fly camera at the spawn site and at the highest bare-rock macro cell, reads the window surface and the live collider back once, prints the mismatch statistics and saves screenshots and the window dump; it takes the knobs as command-line overrides and regenerates the windows, so an A/B run is one command. The user tunes from its output and the chosen values become the defaults.

**Tech Stack:** Godot 4.7.2, GDScript, GLSL compute on the main `RenderingDevice` (push constants; a synchronous `texture_get_data` in the debug driver only), `HeightMapShape3D` under Jolt, headless `SceneTree` tests via `godot/tests/run.sh`.

**Spec:** item R2 of [docs/superpowers/plans/2026-10-27-terrain-slice-1-followups.md](2026-10-27-terrain-slice-1-followups.md); conventions from sections 6.2 (detail stage) and 9 (collision) of [docs/superpowers/specs/2026-10-24-terrain-slice-1-design.md](../specs/2026-10-24-terrain-slice-1-design.md); the slice 1 figures in section 6.8 of [docs/terrain-research.md](../../terrain-research.md).

## Decisions

Each with the alternative considered and why it lost.

1. **The floor is the 1 m window's only: the 2 m and 1 m octaves are off there; the 8 m window keeps 32, 16 and 8 m as today.** On a 1 m grid the 1 m octave hits every lattice cell at `f = 0.5` (per-cell noise, 0.38 m on bare mountain rock) and the 2 m octave is sampled at `f = 0.25` and `0.75` only, a 2-cell staircase of lattice values (0.844/0.156 blends) with twice that amplitude (0.76 m). Both are what R2 calls the rough-rock look, and by the chord-error arithmetic (the collider's 1 m chords against drawn vertices 0.77 m apart) the 2 m staircase is the larger share of the mismatch, so both go. Alternative: R2's literal `s < 2 × cell` per window. It keeps the 2 m staircase, and on the far window it drops the 8 m octave, which moves the near-only share of the peak at the 256 m seam (today 0.111: the 4, 2 and 1 m octaves over 1.96875) to 0.22 (8, 4 and 2 m), where this plan takes it to 0.067 (the 4 m octave alone): 5.3 m against 1.6 m on bare rock and changes the far level's look inside the same tuning pass. The far window is not under the collider; its own floor is a separate eye test. Implemented as zero weights (decision 2), so the shader's break stays as it is.

2. **The knobs are `WorldParams` fields that reach the shader through the existing push constants.** `detail_octaves` (six relative weights, 32 down to 1 m), `detail_region_amp` (five peaks in m: sea, flat, hill, mountain, island), `detail_rock_roughness` (bare rock's multiplier is 1 + this). `WorldParams` is where every world knob lives and reaches the shader. In 4.7.2 `ResourceSaver` omits fields equal to their defaults, so a world file carries a knob only if it was changed before the save and every other world takes the current defaults; this matters to the edit slice, which regenerates unedited cells against these values, because changing a default retunes every default-valued world. The push constant block grows from 64 to 112 bytes, under the 128 bytes Vulkan guarantees, and the far window already shares the block. Alternatives: constants in `terrain_window.gd` (not saved with the world); a uniform buffer (an RID, an `RDUniform` and a set rebuild for 13 floats); a separate floor knob in metres (redundant with a zero weight: the far window never runs an octave under its own cell, so zeroing 1 m or 2 m touches the 1 m window only and zeroing 8 m touches both alike, which is decision 1 exactly).

3. **Amplitudes are re-tuned as relative weights normalised by their sum.** The region amplitude stays the peak in metres and the weights are the spectrum's shape (the fBm convention), so one knob sets size and the others set texture. Dropping the 1 m and 2 m octaves renormalises the rest by 1.96875 / 1.875 = 1.05, the same on both windows, so the seam relation is unchanged. The grain bare rock loses is given back, where the eye wants it, by raising the 4 m weight (the finest clean octave on the 1 m window) and the rock roughness; Task 3 gives the ranges. Alternative: absolute weights (a pure deletion, but reproducing today's look needs defaults like 0.508, 0.254, ... or rescaled region amplitudes). Skipped: a rock-only grain knob for the octaves at 4 m and under; add it when the eye test says flats got rough before rock got right.

4. **The mismatch is the in-row chord error at every drawn vertex over the live 257 m patch: p99 and max of |error|.** The bake puts the collider's 1 m samples on the drawn row polyline, so the two surfaces differ only where a drawn vertex sits off the collider's chord. The driver reads the window surface and `map_data` back once (synchronous, debug only), maps each cell centre into the patch frame as the bake does and interpolates the collider there. It is the patch-wide statistic slice 1 reported (18 cm max, 8 cm p99), re-measured with one method before and after. Alternatives: dropping boxes (3 to 5 cm resolution, a few points); a compute pass for the comparison (a one-shot loop over 100 k samples in a debug driver does not need one).

5. **Fixed views: the spawn site and the highest bare-rock macro cell of the world, each from eye height (1.7 m, 10 degrees down) and from 120 m (40 degrees down), looking spinward, the light bar parked at noon over the site.** Both sites come from the world file, so any user on any world reproduces them, and the rock site is where cells are narrowest and rock is bare, where slice 1 measured. Alternative: the slice 1 reports' hand-placed fly camera (its position was not recorded). `--at=theta,z` adds a view of the user's choosing.

6. **A/B runs by command-line overrides, not file edits.** The driver's `--octaves`, `--amp` and `--rock` set the fields on the loaded `WorldParams`, regenerate both windows (`TerrainWindow.regenerate()`, three lines) and rebake the patch; the chosen values go into the `world_params.gd` defaults once, at the end. The default world's `params.tres` omits the fields, as does any file saved while they equal the defaults, so the defaults apply to every such world.

## Global Constraints

- Godot 4.7.2 only; 1 m cells; 512 window of 128-cell tiles; the 8 m far window shares `detail.glsl` and the push constant layout.
- No per-cell GDScript loop on a per-frame path. The driver's readback loops are one-shot and live in `noise_report.gd` only.
- Headless tests follow the existing pattern (`extends SceneTree`, `_initialize`, `check`, print `PASS`, `quit`) and run via `godot/tests/run.sh`; GPU work is verified by the windowed driver, which opens a window on the user's screen, so a run stays under a minute.
- Detail pass budget 2 ms per tile (0.18 to 0.23 ms in slice 1), measured with `--rendering-driver vulkan` (MoltenVK); Metal reports zero GPU timestamps.
- The 8 m far window keeps matching the 1 m window at their seam: the 32, 16 and 8 m weights reach both windows alike; the 4, 2 and 1 m weights reach the 1 m window only.
- Push constants are hand-packed std430 (`PackedByteArray.encode_*`), a multiple of 16 bytes and exactly the shader block's size.
- Commit after each task with the message given.

## Review Focus

1. The default world's `params.tres` was saved before the detail fields existed: loading it must give the script defaults, not zeros or nulls. Pinned in Task 2 (a hand-written old-style `.tres` loads with the defaults).
2. A short, empty or over-long `detail_octaves` or `detail_region_amp` list in a world file: the packing pads with zeros or truncates to the slot, and the shader divides by `max(norm, 1e-6)`, so the worst case is no noise, never NaN, an out-of-range read or a value written over the next field. Pinned in Task 2 (packing test with short and long lists).
3. The GDScript buffer and the shader's block must both be 112 bytes, or `compute_list_set_push_constant` errors on every dispatch and no tile generates. Pinned in Task 2 (size check) and by every windowed run (an `ERROR` line fails it).
4. A user who changes the 8 m weight changes both windows at once; the far level's edge 256 m out must look as it does today. Pinned by the eye check in Task 3's checklist.
5. The collider patch can reach cells outside the window's wanted set (viewer at a tile edge, station ends): the driver must skip them, not read another tile's texels. Pinned in Task 1 by the printed sample count, which must match the 256 m span at each site.

---

### Task 1: Noise report driver and the "before" measurement

**Files:**
- Create: `godot/terrain/noise_report.gd`, `godot/terrain/noise_report.tscn`
- Modify: `docs/terrain-research.md` (section 6.8, a "Noise octaves" table with the "before" row)
- Test: `godot/tests/test_noise_report.gd`

**Interfaces:**
- Consumes: `main.tscn`, instantiated as `smoke_run.gd` does; `Terrain.collider_live`, `Terrain.window`, `Terrain.far.window`, `Terrain.patch`, `Terrain.maps.spawn`, `Terrain.params`, `Terrain.height_at(theta, z)`; `ColliderPatch.live`, `needs_rebuild(viewer_local)`, `center` (theta, z), `surface_point(p, lift)`, `get_node("CollisionShape3D").shape.map_data`; `FlyCamera.toggle()`; `LightBar.theta`, `day_length`; `Cyl.position`, `Cyl.bake_row` (the test's reference); `debug_window_dump.gd` (`window`, `center`, `_dump()`); the `Panel/Box/Timing` overlay's `timed` signal; `TerrainWindow.tiles_generated`, `texture_rid`, `center_tile`, `wanted_tiles`, `tile_of_cell`, `size`.
- Produces: `class_name NoiseReport extends Node`, the script of `noise_report.tscn` (one `Node`, as `smoke.tscn`), run as `godot --path . res://terrain/noise_report.tscn -- [--label=NAME] [--at=THETA,Z]`:
  - `static func row_mismatch(h: PackedFloat32Array, dtheta: float, R: float, row: PackedFloat32Array) -> PackedFloat32Array`: `h[k]` is the drawn surface height at angle `(k - (h.size() - 1) / 2) * dtheta` from the patch centre; `row` is one collider row of 257 samples, sample `i` at `x = i - 128`. Each `h[k]` maps to `(x, y) = ((R - h) sin phi, h + 2 (R - h) sin^2(phi / 2))` as `Cyl.bake_row` and `collider_bake.glsl` do. Returns `y - row(x)` for every `k` with `|x| <= 128`, `row(x)` linear between the two samples around `x`; a NaN `h[k]` (a cell outside the window) is skipped, and so are its two neighbours, whose collider chords run to a macro sample and would report the macro-to-detail gap as chord error.
  - `static func rock_site(maps: MacroMaps, params: WorldParams) -> Vector2`: `(theta, z)` of the centre of the highest macro cell with `bedrock_top >= surface - 1` (bare rock at the macro level), or of the highest cell of all when none is bare. Read both images once with `get_data().to_float32_array()`.
  - Per site, one stdout line and the files `user://debug/noise/<label>_<site>_eye.png`, `_high.png` (viewport screenshots), `_surface.png` and `_material.png` (the P-dump, moved from `user://debug/`). `label` defaults to `run`; sites are `spawn`, `rock` and, with `--at`, `at`.

- [ ] **Step 1: Write the failing test**

`godot/tests/test_noise_report.gd`:

```gdscript
extends SceneTree

var failed := false

func check(ok: bool, msg: String) -> void:
	if not ok:
		push_error(msg)
		failed = true

func _initialize() -> void:
	var R := 3200.0
	var dtheta := TAU / 16384
	# A 45 degree slope at 1200 m (0.767 m cells): the bake lies on the drawn polyline, so a drawn vertex
	# misses the collider's chord only by the hull's curvature over one cell, under 1 mm.
	var h := PackedFloat32Array()
	h.resize(405)
	for k in 405: h[k] = 1200.0 + (k - 202) * 0.767
	var e := NoiseReport.row_mismatch(h, dtheta, R, Cyl.bake_row(h, dtheta, R, 1.0, 257))
	check(e.size() >= 300 and e.size() <= 360, "samples within 128 m: %d" % e.size())
	var worst := 0.0
	for x in e: worst = maxf(worst, absf(x))
	check(worst < 1e-3, "slope mismatch %f m" % worst)
	# Per-cell noise of +-0.2 m: the collider's 1 m chords cut the zigzag by 5 cm or more somewhere and
	# never by more than its 0.4 m peak to peak.
	for k in 405: h[k] = 1200.0 + (0.2 if k % 2 == 0 else -0.2)
	var row := Cyl.bake_row(h, dtheta, R, 1.0, 257)
	e = NoiseReport.row_mismatch(h, dtheta, R, row)
	worst = 0.0
	for x in e: worst = maxf(worst, absf(x))
	check(worst > 0.05 and worst <= 0.4, "zigzag mismatch %f m" % worst)
	# A NaN sample (a cell outside the window) and its two neighbours are skipped, not propagated.
	h[200] = NAN
	var e2 := NoiseReport.row_mismatch(h, dtheta, R, row)
	check(e2.size() == e.size() - 3, "NaN and its neighbours skipped: %d vs %d" % [e2.size(), e.size()])
	for x in e2: check(is_finite(x), "NaN leaked")
	# rock_site: the highest macro cell with bedrock within 1 m of the surface, else the highest cell.
	var p := WorldParams.new()
	p.radius = 64 * 32 / TAU + 40.0; p.h_sea = 40.0; p.length = 128 * 32
	var m := MacroMaps.new()
	m.surface = Image.create(64, 128, false, Image.FORMAT_RF)
	m.bedrock_top = Image.create(64, 128, false, Image.FORMAT_RF)
	for x in 64: for y in 128:
		m.surface.set_pixel(x, y, Color(float(x + y), 0, 0))
		m.bedrock_top.set_pixel(x, y, Color(float(x + y) - 10.0, 0, 0))
	var mc := 32 * p.dtheta()
	check(NoiseReport.rock_site(m, p).is_equal_approx(Vector2(63.5 * mc, -p.length / 2.0 + 127.5 * 32)), "no bare rock: the highest cell")
	m.bedrock_top.set_pixel(20, 30, Color(50.0, 0, 0))  # bare, surface 50
	m.bedrock_top.set_pixel(10, 15, Color(25.0, 0, 0))  # bare, lower
	check(NoiseReport.rock_site(m, p).is_equal_approx(Vector2(20.5 * mc, -p.length / 2.0 + 30.5 * 32)), "the highest bare cell")
	if failed: quit(1)
	else: print("PASS"); quit(0)
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd godot && godot --headless --path . --import >/dev/null 2>&1; godot --headless --path . --fixed-fps 60 --quit-after 7200 -s res://tests/test_noise_report.gd`
Expected: an `ERROR` line naming `NoiseReport`, no `PASS`.

- [ ] **Step 3: Write `noise_report.gd` and `noise_report.tscn`**

The scene is one `Node` with the script, as `smoke.tscn`. The driver, in order:

1. `_ready`: parse `--label=` and `--at=`; instantiate `main.tscn`; connect `Terrain.collider_live` to `_route` (one shot) and the `Timing` overlay's `timed`; swallow mouse events as `smoke_run._input` does; `add_child`. If `collider_live` has not fired after 1200 frames, `push_error` and `quit(1)`. The windows do not exist until `Terrain._ready` has run, so their signals are connected in `_route`.
2. `_route`: connect both windows' `tiles_generated` and start collecting `timed` lists from this moment, exactly as `smoke_run._route` does (`smoke_run.gd:80-82`), so lists and dispatches pair up; `FlyCamera.toggle()` (the camera is now the viewer, the player stays frozen); `Panel.visible = false`; the light bar's `day_length = 1e9`; `_visit` each site: `spawn` at `maps.spawn`, `rock` at `rock_site(maps, params)`, `at` from `--at`; print the detail timing line (`smoke_run._stat` and `_per_tile` format) and `quit()`.
3. `_visit(name: String, theta: float, z: float)`: the light bar's `theta` = the site's; the fly camera's station-space `transform` at `Cyl.position(theta, z, height_at(theta, z) + 60, R)` looking spinward (`Basis.looking_at(forward, up)` with `up = (-sin theta, cos theta, 0)`, `spinward = (cos theta, sin theta, 0)`, `forward = cos(tilt) * spinward - sin(tilt) * up`); if `patch.needs_rebuild` there, `await patch.live` (`push_error` and `quit(1)` after 600 frames), else await 3 frames; print the site line from `_mismatch()`; the P-dump (`debug_window_dump.gd` with `window = terrain.window`, `center = terrain.window.center_tile`, `_dump()` via `RenderingServer.call_on_render_thread`), then move its two files to the labelled names with `DirAccess.rename_absolute`; then for `eye` (camera 1.7 m over `patch.surface_point`, 10 degrees down) and `high` (120 m over the macro surface, 40 degrees down): place the camera, await 2 frames and `RenderingServer.frame_post_draw`, save `get_viewport().get_texture().get_image()` as PNG.
4. `_mismatch() -> Dictionary`: on the render thread, `texture_get_data(window.texture_rid("surface"), 0).to_float32_array()` (512 × 512). `c` is the patch centre's cell, `(posmod(floori(center.x / dtheta), n_theta), floori(center.y + length / 2))`; `half = ceili(asin(minf(129.0 / (R - h_sea - h_mtn), 1.0)) / dtheta)` as `ColliderPatch._bake` computes it. For each of the 257 rows `j` (cell row `c.y + j - 128`, skipped outside `[0, n_z)`), build `h` from cells `c.x + k` for `k` in `[-half, half]`, theta wrapped, texel `posmod(row, size) * size + posmod(i, size)` (the shader's slot addressing, since `size = slots * TILE`), NaN where `tile_of_cell(i, row)` is not in `wanted_tiles(center_tile)` (collect that set once); append `row_mismatch(h, dtheta, R, map_data.slice(j * 257, (j + 1) * 257))`. Return `n`, p99 and max of |e| (sorted, index `int(0.99 * n)`), the signed max (mesh above the collider) and min, and the MD5 (`HashingContext`) of the near and far windows' surface bytes.

Site line: `site rock theta 1.2345 z -12345.0: mismatch n 85000 skipped 0, |e| p99 8.1 cm max 18.3 cm, mesh above collider up to 18.3 cm below up to 9.0 cm, surface md5 near 1a2b3c4d far 5e6f7a8b` (`skipped` counts the vertices dropped as outside the window or next to one).

- [ ] **Step 4: Run the test, then the driver**

Run: `cd godot && sh tests/run.sh`
Expected: every test prints `PASS`, `test_noise_report.gd` among them.

Run: `cd godot && godot --path . res://terrain/noise_report.tscn -- --label=before`
Expected: done in under a minute; no `ERROR` line; two site lines; `n` equals 257 rows × the in-window vertices within ±128 m per row (256 m over the cell width: about 240 at the spawn's 1.07 m cells at 400 m, 333 at the rock site's 0.77 m at 1200 m), so about 61 700 and 85 600, less 3 per skipped column; `skipped` is 0 at the spawn, and a non-zero `skipped` means the patch reaches past the window there, which the line shows so it is not read as chord error; spawn p99 under 1 cm (dirt flat, 1.5 m amplitude); rock p99 and max of the order of slice 1's 8 and 18 cm (the site differs; these are the baseline for this method); eight PNGs under `user://debug/noise/` (`~/Library/Application Support/Godot/app_userdata/Artificial Gravity/debug/noise/`). Open the eye and high views: ground in frame, not sky and not the inside of a hill. Then once with `--rendering-driver vulkan` for the detail column: `per tile max` under 2 ms.

- [ ] **Step 5: Record the baseline**

In `docs/terrain-research.md`, after the slice 1 table in section 6.8, add (numbers filled in):

```markdown
**Noise octaves, 2026-10-xx, same machine, 1152×648 window.** `godot --path . res://terrain/noise_report.tscn -- --label=X`: collider mismatch = |drawn vertex − collider| along rows over the 257 m patch (`NoiseReport.row_mismatch`), p99 / max; views in `user://debug/noise/X_*.png`.

| run | octaves 32, 16, 8, 4, 2, 1 m | rock p99 / max | spawn p99 / max | detail per tile (Vulkan) |
|---|---|---|---|---|
| before | 1, .5, .25, .125, .0625, .03125 | | | |
```

- [ ] **Step 6: Commit**

```bash
git add godot/terrain/noise_report.gd godot/terrain/noise_report.gd.uid godot/terrain/noise_report.tscn godot/tests/test_noise_report.gd godot/tests/test_noise_report.gd.uid docs/terrain-research.md
git commit -m "Terrain: noise report driver: collider mismatch statistics and fixed views of the spawn and a rock site"
```

---

### Task 2: Noise knobs in WorldParams, the 2 m and 1 m octaves off, the "after" measurement

**Files:**
- Modify: `godot/terrain/world_params.gd` (three fields), `godot/terrain/shaders/detail.glsl` (`Params`, `AMP`, `detail_noise`, `region_amp`, the `exposed` line), `godot/terrain/terrain_window.gd` (`_push_constants`, `regenerate`), `godot/terrain/noise_report.gd` (override args), `docs/terrain-research.md` (three rows)
- Test: `godot/tests/test_terrain_window_math.gd` (append)

**Interfaces:**
- Consumes: Task 1's driver and table.
- Produces:
  - `WorldParams.detail_octaves: PackedFloat32Array = [1.0, 0.5, 0.25, 0.125, 0.0, 0.0]` (relative weight of the 32, 16, 8, 4, 2, 1 m octaves, normalised by their sum; 0 drops one; under 4 cells an octave is per-cell noise, so the 1 m window's 2 m and 1 m are off), `WorldParams.detail_region_amp: PackedFloat32Array = [1.5, 1.5, 4.0, 8.0, 4.0]` (peak in m by region id: sea, flat, hill, mountain, island), `WorldParams.detail_rock_roughness: float = 2.0` (bare rock's amplitude is 1 + this times its region's, fading in over the last 1 m of cover); each with a doc comment saying that.
  - `detail.glsl` `Params` after `cliff_min` (offset 56): `float rock_roughness;` (60), `float octave[6];` (64), `float region_amp[5];` (88), `float pad;` (108); 112 bytes. `detail_noise` weights octave `o` by `pc.octave[o]` and divides by `max(sum of all six pc.octave, 1e-6)` whatever the window's cell, so both windows scale alike; a zero weight may skip the octave's lattice work. `region_amp` reads `pc.region_amp[id]` (copy the five into a local array first if the compiler rejects the dynamic index). `a = region_amp(p) * (1.0 + pc.rock_roughness * exposed)`. `const float AMP[5]` goes; `if (float(s) < pc.cell) break` stays.
  - `TerrainWindow._push_constants(tile) -> PackedByteArray` packs 112 bytes: the first 60 as today, then the three fields at the offsets above, a list shorter than its slot padded with zeros, a longer one truncated to the slot (never written past it). `func regenerate() -> void`: clears residency and calls `move_to(center_tile)` so every slot regenerates with the params as they now stand (push constants are built at dispatch); does nothing before the first `move_to`.
  - `noise_report.gd` args `--octaves=w0,w1,w2,w3,w4,w5`, `--amp=a0,a1,a2,a3,a4`, `--rock=x`: when any is given, after `collider_live` and before the first site, set the fields on `terrain.params`, `regenerate()` both windows, `patch.rebuild(terrain.window, patch.center.x, patch.center.y)` and `await patch.live`. The report's first line prints the three values in use.

- [ ] **Step 1: Write the failing tests**

Append to `godot/tests/test_terrain_window_math.gd` before `if failed:`:

```gdscript
	# detail.glsl push constants: 112 bytes, the detail knobs at their std430 offsets, short lists padded.
	var q := WorldParams.new()
	q.detail_octaves = PackedFloat32Array([1.0, 0.5, 0.25, 0.125])
	q.detail_region_amp = PackedFloat32Array([1.0, 2.0, 3.0])
	q.detail_rock_roughness = 2.5
	var v := TerrainWindow.new()
	v.configure(q, 512, 1.0)
	var b := v._push_constants(Vector2i(3, 4))
	check(b.size() == 112, "push constant size %d" % b.size())
	check(b.decode_s32(0) == 3 and b.decode_s32(8) == 384 and b.decode_float(24) == 1.0 and b.decode_float(56) == q.cliff_min, "fixed fields")
	check(b.decode_float(60) == 2.5, "rock roughness at 60")
	for o in 6: check(b.decode_float(64 + 4 * o) == (q.detail_octaves[o] if o < 4 else 0.0), "octave %d" % o)
	for r in 5: check(b.decode_float(88 + 4 * r) == (float(r + 1) if r < 3 else 0.0), "region amp %d" % r)
	q.detail_octaves = PackedFloat32Array([1, 1, 1, 1, 1, 1, 9.0])
	check(v._push_constants(Vector2i(3, 4)).decode_float(88) == 1.0, "a seventh octave weight is truncated, not written over region_amp[0]")
	# A world file from before the detail fields existed loads with their defaults.
	var old := FileAccess.open("user://old_params.tres", FileAccess.WRITE)
	old.store_string('[gd_resource type="Resource" script_class="WorldParams" format=3]\n\n[ext_resource type="Script" path="res://terrain/world_params.gd" id="1"]\n\n[resource]\nscript = ExtResource("1")\nseed = 7\n')
	old.close()
	var loaded := ResourceLoader.load("user://old_params.tres", "", ResourceLoader.CACHE_MODE_IGNORE) as WorldParams
	var fresh_params := WorldParams.new()
	check(loaded != null and loaded.seed == 7 and loaded.detail_octaves == fresh_params.detail_octaves \
			and loaded.detail_region_amp == fresh_params.detail_region_amp \
			and loaded.detail_rock_roughness == fresh_params.detail_rock_roughness, "an old world file takes the defaults")
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd godot && godot --headless --path . --fixed-fps 60 --quit-after 7200 -s res://tests/test_terrain_window_math.gd`
Expected: an `ERROR` on `detail_octaves` (no such property), no `PASS`.

- [ ] **Step 3: Implement the fields, the shader, `_push_constants`, `regenerate` and the driver args**

As the Interfaces block states. Update the comments on `detail_noise` and `Params` to say the weights come from `WorldParams`.

- [ ] **Step 4: Run the headless suite**

Run: `cd godot && sh tests/run.sh`
Expected: every test `PASS`.

- [ ] **Step 5: Windowed: the refactor reproduces "before"**

Run: `cd godot && godot --path . res://terrain/noise_report.tscn -- --label=refactor --octaves=1,0.5,0.25,0.125,0.0625,0.03125`
Expected: no `ERROR`; both sites' p99 and max equal the `before` run's to the millimetre; the surface MD5s match the `before` run's (the weights are exact powers of two as constants or as push constants). If MoltenVK's fast-math contracts the sum differently the MD5s may differ while the statistics still agree to the millimetre; that is acceptable, say so in the commit message.

- [ ] **Step 6: Windowed: the two candidate floors**

Run: `-- --label=no1m --octaves=1,0.5,0.25,0.125,0.0625,0`, then `-- --label=after` (the defaults: 2 m and 1 m off).
Expected: no `ERROR`; spawn figures under 1 cm as before (its 2 m and 1 m grain was 2 to 5 cm, so they can only fall, by millimetres); at the rock site the `no1m` run lowers p99 and max by a minority and the `after` run by about half, the remainder being the 4 m and 8 m octaves' chord error (intrinsic to resampling a 0.77 m polyline at 1 m), and neither exceeds `before`; `after_rock_eye.png` shows smoother rock than `before_rock_eye.png` (the `_surface.png` dump is scaled over the whole window's height range, so sub-metre grain is under one grey level in it; the eye views are the grain check). If `no1m` moves the rock figures by less than a millimetre, the 1 m octave was not the mismatch; the decision stands on `after`.

- [ ] **Step 7: Vulkan timing**

Run: `cd godot && godot --path . --rendering-driver vulkan res://terrain/noise_report.tscn -- --label=vk`
Expected: no `ERROR`; `per tile max` under 2 ms (about 0.2 ms).

- [ ] **Step 8: Record**

Add the `refactor`, `no1m` and `after` rows to the section 6.8 table, the Vulkan per-tile figure in the `after` row.

- [ ] **Step 9: Commit**

```bash
git add godot/terrain/world_params.gd godot/terrain/shaders/detail.glsl godot/terrain/terrain_window.gd godot/terrain/noise_report.gd godot/tests/test_terrain_window_math.gd docs/terrain-research.md
git commit -m "Terrain: detail noise octaves, region amplitudes and rock roughness in WorldParams; the 2 m and 1 m octaves are off"
```

---

### Task 3: Tune by eye, fix the defaults

> Runs in the main session with the user, after Tasks 1 and 2 are merged: Steps 1 and 2 need the user to name candidates and look at the PNGs, and the task's only code change is the defaults.

**Files:**
- Modify: `godot/terrain/world_params.gd` (the chosen defaults), `docs/terrain-research.md` (the `tuned` row), `docs/superpowers/plans/2026-10-27-terrain-slice-1-followups.md` (R2 closed with the chosen values and figures)

**Interfaces:**
- Consumes: Task 2's driver args and the `after_*` views.
- Produces: the defaults the game ships with; no code.

The decision is the user's; the implementer runs the candidates the user names, lays the views side by side and records the choice. The knobs, the `after` values and the ranges worth trying:

| knob | after | try | what it does |
|---|---|---|---|
| `detail_octaves[5]` (1 m) | 0 | 0 | per-cell noise on the 1 m window; collider mismatch for nothing |
| `detail_octaves[4]` (2 m) | 0 | 0 to 0.06 | a 2-cell staircase on the 1 m window; back on only if the rock wants it and the rock max stays under `before` |
| `detail_octaves[3]` (4 m) | 0.125 | 0.1 to 0.3 | the finest clean octave; rock grain now comes from here; 0.2 is the first candidate |
| `detail_octaves[0..2]` (32, 16, 8 m) | 1, 0.5, 0.25 | hold | the hill shape, shared with the far window |
| `detail_rock_roughness` | 2 | 1.5 to 3 | bare rock at (1 + this) times its region's peak: 24 m on mountains today |
| `detail_region_amp` flat, hill, mountain, island | 1.5, 4, 8, 4 | 1 to 2.5, 3 to 6, 6 to 10, 3 to 6 | peak in m; the sea entry is unused (no noise on the sea floor) |

- [ ] **Step 1: Candidates**

For each candidate the user names, starting with `--label=c1 --octaves=1,0.5,0.25,0.2,0,0`, run the driver; when the user wants to walk it, set the candidate as the defaults in `world_params.gd` and run `godot --path .` (the game has no overrides). Expected per run: no `ERROR`; rock p99 and max at or under the `after` row's.

- [ ] **Step 2: The eye checklist**

The user looks at `<label>_spawn_eye.png` (flats: gentle, no grain), `<label>_rock_eye.png` and `_high.png` (bare rock: texture without a per-cell sparkle) against `before_*` and `after_*`, and, if any of the 32, 16 or 8 m weights changed, at the far level's edge 256 m out in the game's eye view (no lip beyond today's).

- [ ] **Step 3: Set the defaults**

Put the chosen values in `world_params.gd`; run `cd godot && sh tests/run.sh` (every `PASS`; no test pins default values) and the driver once with no overrides as `--label=tuned`; add the `tuned` row to the section 6.8 table; close R2 in the followups doc with the chosen values and the `before` and `tuned` figures.

- [ ] **Step 4: Commit**

```bash
git add godot/terrain/world_params.gd docs/terrain-research.md docs/superpowers/plans/2026-10-27-terrain-slice-1-followups.md
git commit -m "Terrain: detail noise tuned by eye (octaves 32..1 m = <values>, rock roughness <value>)"
```

---

## Self-review notes

- Spec coverage: R2's octave drop (Task 2, decision 1); measurable before and after (Task 1's driver, Task 2's refactor and candidate runs, the section 6.8 table); knobs in one place without a shader edit (Task 2, decision 2); amplitude re-tune (decision 3, Task 3's ranges); far window matching at the seam (decision 1, Global Constraints, Review Focus 4); detail budget on Vulkan (Task 2 step 7); the P-dump before and after (Task 1 step 3, the `_surface.png` files); a headless test for anything that moves to GDScript (the packing and old-file tests in Task 2; the floor itself stays in the shader as zero weights); the tuning hand-off (Task 3).
- Names used identically across tasks: `NoiseReport.row_mismatch`, `NoiseReport.rock_site`, `WorldParams.detail_octaves`, `detail_region_amp`, `detail_rock_roughness`, `TerrainWindow._push_constants`, `TerrainWindow.regenerate`, the push constant offsets 60, 64, 88, 108 and size 112, the driver args `--label`, `--at`, `--octaves`, `--amp`, `--rock`, the labels `before`, `refactor`, `no1m`, `after`, `tuned`.
- Review Focus pins: 1 and 2 in Task 2 step 1; 3 in Task 2 step 1 (size) and every windowed step; 4 in Task 3 step 2; 5 in Task 1 step 4 (the sample count).
- Proportion: code blocks are the two tests and the stdout formats; the driver and the shader change are given as signatures, offsets and the formulas the tests do not determine.
