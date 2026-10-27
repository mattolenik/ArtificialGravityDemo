# Terrain Slice 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the bare hull with generated, walkable terrain over the whole cylinder: mountains, cliffs, valleys, flatlands, rivers and lakes with islands, in dirt, clay and rock, with real collision everywhere and a fly camera, and with the data layout the later dynamic slices build on.

**Architecture:** A 32 m macro world (water-first growth on a periodic angle-by-length grid) is generated once in GDScript and stored. At runtime a GPU compute pass expands macro maps into a 512-cell window of 1 m fields around the viewer, tile by tile. Tile meshes read those fields in their vertex shader and wrap them onto the cylinder; a single heightfield collider with the curvature baked into its samples is read back asynchronously and follows the viewer; everything lives under the `Station` node, which shifts along the axis to keep the viewer near the origin.

**Tech Stack:** Godot 4.7.2 standard build, Forward+, Jolt, GDScript, GLSL compute via `RenderingDevice` on the main device, `Texture2DRD`, `HeightMapShape3D`, FastNoiseLite.

**Spec:** [docs/superpowers/specs/2026-10-24-terrain-slice-1-design.md](../specs/2026-10-24-terrain-slice-1-design.md). Background: [docs/terrain-research.md](../../terrain-research.md).

## Global Constraints

- Godot 4.7.2 only; no GDExtension in this plan (the spec's fallback triggers only if Task 4 misses its budget by more than 2×, and that becomes a separate plan).
- Grid: `Δθ = 2π / 16384`, `Δz = 1 m`, `L` from the hull mesh (32,000 m by default), heights radial from the hull, `h_sea = 400 m`, `H_mtn = H_ref · g_ref / g_sea` with `H_ref = 1000 m`, `g_ref = 9.8`, `g_hull = station.acceleration`.
- Station space: θ = 0 is local −Y, spinward is +X at the bottom (`Vector3(sin θ, −cos θ, z)`), the axis is local +Z. Matches `emitter.gd`'s `_outward()` and `test_drop_math.gd`.
- Window fields and formats: `surface`, `bedrock_top`, `clay_bottom`, `clay_top`, `water_surface` as `R16_UNORM` scaled by 2048 m (1/32 m steps); `material`, `compaction`, `saturation` as `R8_UNORM`. Ordering invariant `0 ≤ bedrock_top ≤ clay_bottom ≤ clay_top ≤ surface` everywhere.
- Macro maps: 32 m cells, `512 × (L / 32)` cells, `Image.FORMAT_RF` for heights, `FORMAT_R8` for ids, `FORMAT_RGBF` for the river texture. Macro cell = 32 × 32 fine cells.
- Window 512 cells (project setting `terrain/window_size`, 512 or 1024), tiles 128 cells, 4 × 4 tile ring buffer at 512.
- Collider patch 257 × 257 samples at 1 m, rebuilt when the viewer is more than 64 m from its centre.
- No per-cell GDScript loop on any per-frame path. Generation is not per-frame.
- Everything in the world is a child of `Station`, including the player. Terrain code uses station-local `(θ, z)` only.
- Headless tests cannot create a `RenderingDevice`; GPU work is verified by the windowed runs written into the tasks. Headless tests follow the existing pattern (`extends SceneTree`, `_initialize`, `check`, print `PASS`, `quit`) and run via `godot/tests/run.sh`.
- Commit after each task with the message given.

## Review Focus

1. The periodic seam at θ = 2π: a viewer tile whose ring-buffer row wraps from column 127 to 0 must produce continuous tiles and a continuous collider. Pinned by `test_terrain_window_math.gd` in Task 5 and by the windowed run in Task 6 (walk across θ = 0, which is directly below the axis at spawn).
2. The station ends: a viewer within 256 m of `z = ±L/2` asks for tiles outside the macro maps; macro sampling must clamp in `z` and wrap in `θ` so the detail pass never reads garbage. Pinned by `test_macro_maps.gd` (`sample` clamps) in Task 2 and the fly-camera run in Task 8.
3. A floating-origin shift while a collider readback is in flight: the patch is a child of `Station`, so the shift moves it with the terrain and the late `map_data` is still valid. Pinned by `test_floating_origin.gd` in Task 8.
4. A seed whose test-sized world yields no river reaching the sea or no valid spawn cell: the generator must still return complete maps and a spawn site (fallback: the lowest flat land cell). Pinned by `test_macro_generator.gd` in Task 4.
5. The emitter with a viewer set and the viewer off θ = 0: boxes must spawn at the viewer's angle and axial position, with spinward still correct there. Pinned by `test_emitter.gd` in Task 6.

---

### Task 1: Cylinder math and station length

**Files:**
- Create: `godot/terrain/cyl.gd`
- Modify: `godot/station.gd` (add `length`)
- Modify: `godot/tests/test_station.gd` (add a length check)
- Test: `godot/tests/test_cylinder_math.gd`

**Interfaces:**
- Consumes: `Station.radius`, the hull mesh AABB.
- Produces: `class_name Cyl` with static functions used by every later task:
  - `static func position(theta: float, z: float, h: float, R: float) -> Vector3` → `Vector3((R − h)·sin θ, −(R − h)·cos θ, z)`.
  - `static func theta_of(p: Vector3) -> float` → `atan2(p.x, −p.y)` wrapped to `[0, TAU)`.
  - `static func height_of(p: Vector3, R: float) -> float` → `R − sqrt(p.x² + p.y²)`.
  - `static func span_volume(h1: float, h2: float, R: float, dtheta: float, dz: float) -> float` → `dtheta · dz · ((R − h1)² − (R − h2)²) / 2` for `h1 ≤ h2`.
  - `static func bake_row(h: PackedFloat32Array, dtheta: float, R: float, spacing: float, n_out: int) -> PackedFloat32Array`: the CPU reference for the collider bake. Input `h[k]` is the surface height at `φ_k = (k − (h.size() − 1) / 2) · dtheta`; output `y[i]` at `x_i = (i − (n_out − 1) / 2) · spacing` where each input maps to `(x_k, y_k) = ((R − h_k)·sin φ_k, R − (R − h_k)·cos φ_k)`; `y[i]` is the linear interpolation along the polyline of mapped samples, and where consecutive `x_k` decrease (fold-back) the maximum `y` over all covering segments is taken.
  - `Station.length: float`, set in `_ready` from `mesh.get_aabb().size.y` (the mesh is built with its long axis on Y before the scene's 90° turn, like `radius` from `end.x`).

- [ ] **Step 1: Write the failing test**

`godot/tests/test_cylinder_math.gd`:

```gdscript
extends SceneTree

var failed := false

func check(ok: bool, msg: String) -> void:
	if not ok:
		push_error(msg)
		failed = true

func _initialize() -> void:
	var R := 3200.0
	# Round trip at the bottom, spinward of it, and up a mountain.
	for t in [0.0, 1.0, 4.5, TAU - 0.01]:
		for h in [0.0, 400.0, 1543.0]:
			var p := Cyl.position(t, -123.0, h, R)
			check(absf(fposmod(Cyl.theta_of(p) - t + PI, TAU) - PI) < 1e-6, "theta %f %f" % [t, h])
			check(absf(Cyl.height_of(p, R) - h) < 1e-3, "height %f %f" % [t, h])
			check(is_equal_approx(p.z, -123.0), "z")
	check(Cyl.position(0.0, 0.0, 0.0, R).is_equal_approx(Vector3(0, -R, 0)), "theta 0 is local -Y")
	check(Cyl.position(0.5 * PI, 0.0, 0.0, R).is_equal_approx(Vector3(R, 0, 0)), "spinward is +X at the bottom")
	# Span volume against a numeric integral of (R - h) over the span.
	var dtheta := TAU / 16384; var dz := 1.0
	var v := Cyl.span_volume(100.0, 350.0, R, dtheta, dz)
	var num := 0.0
	for i in 1000:
		num += (R - (100.0 + 250.0 * (i + 0.5) / 1000.0)) * dtheta * dz * 0.25
	check(absf(v - num) / num < 1e-6, "span volume %f vs %f" % [v, num])
	# Bake: a 45° slope in height, 257 samples at 1 m, must match the analytic curved surface within 1 mm.
	var n := 257; var h := PackedFloat32Array(); h.resize(n)
	for k in n: h[k] = 300.0 + (k - 128) * 1.0
	var y := Cyl.bake_row(h, 1.0 / (R - 300.0), R, 1.0, n)
	var worst := 0.0
	for i in range(8, n - 8):
		var x := (i - 128) * 1.0
		# Invert numerically: find phi with (R - h(phi)) sin phi = x, h linear in phi.
		var phi := x / (R - 300.0)
		for _it in 20:
			var hh := 300.0 + phi * (R - 300.0)
			phi -= ((R - hh) * sin(phi) - x) / ((R - hh) * cos(phi) - (R - 300.0) * sin(phi))
		var exact := R - (R - (300.0 + phi * (R - 300.0))) * cos(phi)
		worst = maxf(worst, absf(y[i] - exact))
	check(worst < 1e-3, "bake error %f m" % worst)
	# A vertical 50 m step at the row's edge folds back; the upper envelope wins and nothing is NaN.
	for k in n: h[k] = 300.0 if k < 200 else 350.0
	y = Cyl.bake_row(h, 1.0 / (R - 300.0), R, 1.0, n)
	# The face leans antispinward by H·sin φ ≈ 1.2 m here, so compare across the lean.
	check(y[201] - y[197] > 49.0, "step kept")
	for i in n: check(is_finite(y[i]), "finite %d" % i)
	# Station length comes from the mesh.
	var station: Station = load("res://station.tscn").instantiate()
	root.add_child(station)
	await process_frame
	check(absf(station.length - 32000.0) < 1.0, "length %f" % station.length)
	if failed: quit(1)
	else: print("PASS"); quit(0)
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd godot && godot --headless --path . --fixed-fps 60 --quit-after 7200 -s res://tests/test_cylinder_math.gd`
Expected: parse error, `Cyl` not found.

- [ ] **Step 3: Implement `Cyl` and `Station.length`**

`godot/terrain/cyl.gd` with the signatures above. `bake_row` is the one body the signature does not determine: map every input sample to `(x_k, y_k)`; then for each output `x_i`, scan the consecutive segments `(x_k, x_{k+1})` that contain `x_i` (either orientation), interpolate `y` on each, and keep the maximum; if no segment covers `x_i` (only possible at the row ends), clamp to the nearest mapped sample. Doing it with a single sweep over `k` while advancing `i` is fine, as is the plain double loop; this is test and reference code, not a per-frame path.

`station.gd`: add `## Hull length along the axis, in m, read from the mesh in _ready.` `var length: float` and set `length = mesh.get_aabb().size.y` next to `radius`.

Add to `test_station.gd` after the radius check: `check(absf(station.length - 32000.0) < 1.0, "length %f" % station.length)`.

- [ ] **Step 4: Run the tests**

Run: `cd godot && sh tests/run.sh`
Expected: every test prints `PASS`, including `test_cylinder_math.gd` and `test_station.gd`.

- [ ] **Step 5: Commit**

```bash
git add godot/terrain/cyl.gd godot/station.gd godot/tests/test_cylinder_math.gd godot/tests/test_station.gd
git commit -m "Terrain: cylinder math (mapping, span volume, collider bake reference) and station length"
```

---

### Task 2: World parameters, macro maps and world files

**Files:**
- Create: `godot/terrain/world_params.gd`, `godot/terrain/macro_maps.gd`, `godot/terrain/world_io.gd`
- Test: `godot/tests/test_macro_maps.gd`

**Interfaces:**
- Consumes: `Cyl`.
- Produces:
  - `class_name WorldParams extends Resource` with exports: `seed: int = 1`, `radius: float = 3200`, `length: float = 32000`, `g_hull: float = 9.8`, `h_sea: float = 400`, `h_ref: float = 1000`, `g_ref: float = 9.8`, `macro_cell: float = 32`, `sea_z: float = 0`, `sea_width: float = 3000`, `sea_edge_noise: float = 600`, `sea_depth_max: float = 400`, `island_count: int = 6`, `region_scale: float = 4000`, `river_sources_per_km2: float = 0.08`, `river_q_min: float = 2.0`, `lake_rate: float = 0.33`, `cliff_min: float = 10`, `cliff_max: float = 60`, `cliff_fraction: float = 0.15`, `bank_distance: float = 10`, `bank_slope_deg: float = 35`, `bedrock_depth: Dictionary = {"flat": [150, 300], "hill": [60, 150], "mountain": [0, 40]}`, `clay_thickness: Vector2 = Vector2(2, 10)`, `clay_fraction: float = 0.2`, `spawn_max_slope_deg: float = 5`, `spawn_river_distance: float = 100`; derived functions `n_theta() -> int` (16384 by default, computed as `roundi(TAU * (radius − h_sea) / 1.0)` rounded to the nearest power of two), `n_z() -> int` (`roundi(length / 1.0)`), `macro_w() -> int` (`n_theta() / 32`), `macro_h() -> int` (`n_z() / 32`), `g_sea() -> float`, `h_mtn() -> float`, `dtheta() -> float`.
  - `class_name MacroMaps extends Resource` with exports: `surface`, `bedrock_top`, `clay_bottom`, `clay_top`, `water_surface: Image` (FORMAT_RF, `macro_w × macro_h`); `region: Image` (FORMAT_R8; 0 sea, 1 flat, 2 hill, 3 mountain, 4 island), `cliff: Image` (FORMAT_R8, 255 in a cliff band), `flow_dir: Image` (FORMAT_R8; 0 none, 1..8 the neighbour index, used by tests), `river: Image` (FORMAT_RGBF: distance to the nearest river centreline in m, that river's width in m, its surface height in m); `rivers: Array[PackedFloat32Array]` (each flattened `[θ, z, width, Q, θ, z, width, Q, …]` from source to mouth), `lakes: Array[Dictionary]` (`{"theta", "z", "radius", "level"}`), `loops: Array[Dictionary]` (`{"intake": Vector2, "outlets": PackedVector2Array, "q": float}`), `spawn: Vector2` (θ, z); methods `sample(img: Image, theta: float, z: float, params: WorldParams) -> float` (bilinear, wraps `θ`, clamps `z`, for FORMAT_RF images) and `cell(theta, z, params) -> Vector2i`.
  - `class_name WorldIO` with `static func save(maps: MacroMaps, params: WorldParams, name: String) -> Error` writing `user://worlds/<name>/params.tres` and `maps.res`, and `static func load_world(name: String) -> Array` returning `[params, maps]` or `[]` when missing, and `static func exists(name: String) -> bool`.

- [ ] **Step 1: Write the failing test**

`godot/tests/test_macro_maps.gd`:

```gdscript
extends SceneTree

var failed := false

func check(ok: bool, msg: String) -> void:
	if not ok:
		push_error(msg)
		failed = true

func _initialize() -> void:
	var p := WorldParams.new()
	check(p.n_theta() == 16384, "n_theta %d" % p.n_theta())
	check(p.n_z() == 32000, "n_z %d" % p.n_z())
	check(p.macro_w() == 512 and p.macro_h() == 1000, "macro size %d %d" % [p.macro_w(), p.macro_h()])
	check(absf(p.g_sea() - 9.8 * 2800.0 / 3200.0) < 1e-6, "g_sea")
	check(absf(p.h_mtn() - 1000.0 * 9.8 / p.g_sea()) < 1e-6, "h_mtn")
	# A test-sized world: 64 cells around, 128 along.
	p.radius = 64 * 32 / TAU + 40.0; p.h_sea = 40.0; p.length = 128 * 32
	check(p.n_theta() == 2048 and p.macro_w() == 64 and p.macro_h() == 128, "small world %d %d" % [p.macro_w(), p.macro_h()])
	var m := MacroMaps.new()
	m.surface = Image.create(64, 128, false, Image.FORMAT_RF)
	for x in 64: for y in 128: m.surface.set_pixel(x, y, Color(float(x), 0, 0))
	# Bilinear with cell centres at (i + 0.5) cells, wrapping in theta, clamping in z.
	var mc := p.dtheta() * 32  # one macro cell in radians
	check(absf(m.sample(m.surface, 0.5 * mc, 0.0, p) - 0.0) < 1e-4, "cell 0 centre")
	check(absf(m.sample(m.surface, TAU, 0.0, p) - 31.5) < 1e-3, "theta = TAU is the midpoint of cells 63 and 0: %f" % m.sample(m.surface, TAU, 0.0, p))
	check(absf(m.sample(m.surface, 0.0, 0.0, p) - 31.5) < 1e-3, "theta = 0 is the same midpoint")
	check(absf(m.sample(m.surface, 10.5 * mc, 1e9, p) - 10.0) < 1e-4, "z clamps high")
	check(absf(m.sample(m.surface, 10.5 * mc, -1e9, p) - 10.0) < 1e-4, "z clamps low")
	check(m.cell(TAU + 0.5 * p.dtheta() * 32, -p.length / 2, p) == Vector2i(0, 0), "cell wraps and starts at -L/2")
	# Save and load round trip.
	m.spawn = Vector2(1.5, -200)
	m.rivers = [PackedFloat32Array([0.1, 10, 5, 3, 0.2, 20, 6, 4])]
	check(WorldIO.save(m, p, "test_world") == OK, "save")
	check(WorldIO.exists("test_world"), "exists")
	var loaded: Array = WorldIO.load_world("test_world")
	check(loaded.size() == 2 and loaded[0] is WorldParams and loaded[1] is MacroMaps, "load types")
	check(loaded[1].spawn == m.spawn and loaded[1].rivers[0][3] == 3.0, "load content")
	check(absf(loaded[1].surface.get_pixel(5, 7).r - 5.0) < 1e-6, "image survived")
	check(loaded[0].h_sea == 40.0, "params survived")
	if failed: quit(1)
	else: print("PASS"); quit(0)
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd godot && godot --headless --path . --fixed-fps 60 --quit-after 7200 -s res://tests/test_macro_maps.gd`
Expected: `WorldParams` not found.

- [ ] **Step 3: Implement the three classes**

`n_theta()` rounds `TAU · (radius − h_sea) / 1.0` to the nearest power of two so tiles divide it; `n_z()` is `roundi(length)` rounded down to a multiple of 128. `sample` converts `(θ, z)` to continuous macro coordinates (`θ / dtheta / 32 − 0.5`, `(z + length / 2) / macro_cell − 0.5`), wraps the x index modulo `macro_w()`, clamps y to `[0, macro_h() − 1]`, and interpolates `get_pixel(..).r`. `WorldIO` uses `DirAccess.make_dir_recursive_absolute`, `ResourceSaver.save` and `ResourceLoader.load` with `CACHE_MODE_IGNORE`.

- [ ] **Step 4: Run the tests**

Run: `cd godot && sh tests/run.sh`
Expected: all `PASS`.

- [ ] **Step 5: Commit**

```bash
git add godot/terrain/world_params.gd godot/terrain/macro_maps.gd godot/terrain/world_io.gd godot/tests/test_macro_maps.gd
git commit -m "Terrain: world parameters, macro map resource with wrapped sampling, world files"
```

---

### Task 3: Macro generator, water first

**Files:**
- Create: `godot/terrain/macro_generator.gd`
- Test: `godot/tests/test_macro_generator.gd` (first half)

**Interfaces:**
- Consumes: `WorldParams`, `MacroMaps`, `Cyl`.
- Produces: `class_name MacroGenerator extends RefCounted` with `func generate(params: WorldParams, progress: Callable = Callable()) -> MacroMaps` and the stage methods below, each taking and filling the same `MacroMaps` so tests can inspect intermediate images. `progress` receives `(stage_name: String, fraction: float)`. All randomness through one `RandomNumberGenerator` seeded from `params.seed`, and `FastNoiseLite` instances seeded from it.
  - `_seas(m, p, rng)`: fills `region` with 0 (sea) in a band `|z − sea_z| < sea_width / 2 + noise(θ)·sea_edge_noise`, places `island_count` islands as region 4 blobs inside the band, and writes the sea floor into `surface` as `h_sea − min(sea_depth_max, k · distance_to_shore)` with `k` such that the band centre reaches the hull; `water_surface = h_sea` over sea cells, 0 elsewhere.
  - `_regions(m, p, rng)`: for land cells, region 1, 2 or 3 from low-frequency noise and Voronoi cells, biased mountain near `|z| > 0.3 · length` and flat near the sea.
  - `_drainage(m, p, rng)`: multi-source random-order fringe expansion from every shoreline land cell over land, writing `flow_dir` (each land cell points to an already-processed neighbour). Periodic in θ.
  - `_rivers(m, p, rng)`: sources by density weighted by region (mountain 4×, hill 2×, flat 1×), each traced along `flow_dir` to the sea; `Q` accumulates per cell (1 unit per source); reaches with `Q < river_q_min` dropped; width `w = 4·sqrt(Q)` m, depth `w / 8`; stores `rivers` as polylines from source to mouth.
  - `_lakes(m, p, rng)`: on a fraction `lake_rate` of rivers, one lake at a random cell of that river with radius `20·sqrt(Q)` m; `lakes` filled; the lake's level set in `_profiles`.
  - `_profiles(m, p, rng)`: walks each river upstream from its mouth, raising `water_surface` by `slope(Q)·cell` per cell with `slope(Q) = 0.004 / sqrt(Q)`; a lake flattens the profile to the height reached at its downstream edge and sets `lakes[i].level`; `river` image written by multi-source BFS over the macro grid from river cells carrying distance (m), width and surface height.

Stage order in `generate`: seas, regions, drainage, rivers, lakes, profiles, then the Task 4 stages.

- [ ] **Step 1: Write the failing test (first half)**

`godot/tests/test_macro_generator.gd`:

```gdscript
extends SceneTree

var failed := false

func check(ok: bool, msg: String) -> void:
	if not ok:
		push_error(msg)
		failed = true

func small_params(seed: int) -> WorldParams:
	var p := WorldParams.new()
	p.seed = seed
	p.radius = 64 * 32 / TAU + 40.0; p.h_sea = 40.0; p.length = 128 * 32
	p.h_ref = 100.0; p.sea_width = 800.0; p.sea_edge_noise = 100.0; p.sea_depth_max = 40.0
	p.island_count = 1; p.region_scale = 600.0; p.river_sources_per_km2 = 4.0; p.river_q_min = 1.0
	p.cliff_min = 40.0; p.cliff_fraction = 0.3
	return p

func _initialize() -> void:
	var p := small_params(7)
	var g := MacroGenerator.new()
	var m := g.generate(p)
	var w := p.macro_w(); var h := p.macro_h()
	check(m.surface.get_width() == w and m.surface.get_height() == h, "size")
	# Seas: a band around z = 0, water at sea level there, sea floor below it.
	var sea_cells := 0
	for y in h: for x in w:
		if m.region.get_pixel(x, y).r8 == 0:
			sea_cells += 1
			check(absf(m.water_surface.get_pixel(x, y).r - 40.0) < 1e-3, "sea level at %d %d" % [x, y])
			check(m.surface.get_pixel(x, y).r < 40.0, "sea floor below sea level")
	check(sea_cells > w * h / 10 and sea_cells < w * h / 2, "sea band size %d" % sea_cells)
	# Drainage: every land cell has a flow direction toward a processed neighbour, except the shoreline seeds.
	var no_dir := 0
	for y in h: for x in w:
		if m.region.get_pixel(x, y).r8 != 0 and m.flow_dir.get_pixel(x, y).r8 == 0: no_dir += 1
	check(no_dir < w * h / 20, "cells without flow dir %d" % no_dir)
	# Rivers: at least one, every one ends in the sea, Q grows downstream, polyline well formed.
	check(m.rivers.size() >= 1, "rivers %d" % m.rivers.size())
	for r in m.rivers:
		check(r.size() % 4 == 0 and r.size() >= 8, "polyline stride")
		var mouth := m.cell(r[r.size() - 4], r[r.size() - 3], p)
		check(m.region.get_pixel(mouth.x, mouth.y).r8 == 0 or m.water_surface.get_pixel(mouth.x, mouth.y).r > 0.0, "river reaches water")
		check(r[r.size() - 1] >= r[3], "Q grows downstream")
	# Profiles: river water surface is at or above sea level and non-increasing toward the mouth.
	for r in m.rivers:
		var prev := INF
		for i in range(0, r.size(), 4):
			var c := m.cell(r[i], r[i + 1], p)
			var ws := m.water_surface.get_pixel(c.x, c.y).r
			check(ws >= 40.0 - 1e-3 and ws <= prev + 1e-3, "profile monotone")
			prev = ws
	# River texture: zero distance on river cells, positive elsewhere, carries width and surface.
	var c0 := m.cell(m.rivers[0][0], m.rivers[0][1], p)
	var rv := m.river.get_pixel(c0.x, c0.y)
	check(rv.r < 1e-3 and rv.g > 0.0 and rv.b >= 40.0, "river texture on river %s" % rv)
	var far_cells := 0
	for y in h: for x in w: if m.river.get_pixel(x, y).r > 100.0: far_cells += 1
	check(far_cells > 0, "river distance field")
	# Determinism.
	var m2 := MacroGenerator.new().generate(small_params(7))
	check(m.surface.get_data() == m2.surface.get_data() and m.water_surface.get_data() == m2.water_surface.get_data(), "deterministic")
	check(MacroGenerator.new().generate(small_params(8)).surface.get_data() != m.surface.get_data(), "seed matters")
	if failed: quit(1)
	else: print("PASS"); quit(0)
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd godot && godot --headless --path . --fixed-fps 60 --quit-after 7200 -s res://tests/test_macro_generator.gd`
Expected: `MacroGenerator` not found.

- [ ] **Step 3: Implement the water-first stages**

Implement `generate` running only the six stages above for now (Task 4 appends the rest), with `surface` for land cells left at `h_sea` so the test's checks pass before growth exists. Use `PackedFloat32Array` and `PackedByteArray` working buffers and write the `Image`s at the end of each stage; `Image.set_pixel` in a 512k loop is acceptable here (generation is not a per-frame path) but prefer `Image.create_from_data` on packed arrays. The drainage fringe is a shuffled queue; the BFS for the river texture is a plain queue over the periodic grid.

- [ ] **Step 4: Run the tests**

Run: `cd godot && sh tests/run.sh`
Expected: all `PASS`. Note the wall time of `test_macro_generator.gd`; it should be well under 10 s for the small world.

- [ ] **Step 5: Commit**

```bash
git add godot/terrain/macro_generator.gd godot/tests/test_macro_generator.gd
git commit -m "Terrain: macro generator, water-first stages (seas, regions, drainage, rivers, lakes, profiles)"
```

---

### Task 4: Macro generator, growth, strata, banks, loops, spawn

**Files:**
- Modify: `godot/terrain/macro_generator.gd`
- Test: `godot/tests/test_macro_generator.gd` (second half)

**Interfaces:**
- Consumes: Task 3 stages.
- Produces, appended to `generate`:
  - `_grow(m, p, rng)`: binary-heap priority queue seeded with every water cell at its `water_surface` height; pops the lowest cell, pushes unvisited neighbours with `h' = h + s_region·b + s_river·(1 − b) + |noise|`, `b = clamp(1 − river_distance / (3·width), 0, 1)` from the river texture, `s_region` = 0.4 m/cell flat, 2.5 hill, 8 mountain, `s_river` = 0.05 m/cell, all multiplied by `max(0, 1 − (h − h_sea) / h_mtn)^0.5` so peaks approach `h_sea + h_mtn` smoothly; in cells where `cliff` is set the increment adds `rng.randf_range(cliff_min, cliff_max)` once. `cliff` is filled first from thresholded noise over hill and mountain cells so that about `cliff_fraction` of them are cliff bands. Periodic in θ. Writes `surface` for land cells.
  - `_strata(m, p, rng)`: `bedrock_top = max(0, surface − D)` with `D` drawn from `bedrock_depth[region]` plus noise, and `D = 0` where `cliff` is set; clay: where noise exceeds a threshold set by `clay_fraction`, a lens of thickness from `clay_thickness` placed at a random depth inside the dirt, clamped to the ordering invariant; where no dirt remains, `bedrock_top = surface`. Islands get `D = 0` at their cores.
  - `_banks(m, p, rng)`: for land cells within `bank_distance` of water (river texture distance or adjacency to sea or lake), limit `surface` so the slope to each water-side neighbour is at most `bank_slope_deg`; iterate until stable.
  - `_loops(m, p, rng)`: one entry per river that reaches the sea: `intake` = mouth cell `(θ, z)`, `outlets` = the source cells of that river and its tributaries, `q` = mouth `Q`.
  - `_spawn(m, p, rng)`: nearest to `θ = 0` among land cells with slope under `spawn_max_slope_deg`, `region == 1`, `surface ≥ h_sea`, within `spawn_river_distance` of a river; fallback: the lowest land cell with region 1; final fallback: any land cell.

- [ ] **Step 1: Extend the test**

Append before the `if failed:` line of `test_macro_generator.gd`:

```gdscript
	# Growth: every land cell is at or above sea level and strictly above its flow-direction parent,
	# and nothing exceeds the cap.
	var dirs := [Vector2i(0,0), Vector2i(1,0), Vector2i(1,1), Vector2i(0,1), Vector2i(-1,1), Vector2i(-1,0), Vector2i(-1,-1), Vector2i(0,-1), Vector2i(1,-1)]
	var cap := p.h_sea + p.h_mtn()
	var above_parent := 0; var land := 0
	for y in h: for x in w:
		if m.region.get_pixel(x, y).r8 == 0: continue
		land += 1
		var s := m.surface.get_pixel(x, y).r
		check(s >= 40.0 - 1e-3 and s <= cap + 1e-3, "land height %f at %d %d" % [s, x, y])
		var d: int = m.flow_dir.get_pixel(x, y).r8
		if d > 0:
			var n := Vector2i(posmod(x + dirs[d].x, w), clampi(y + dirs[d].y, 0, h - 1))
			if s > m.surface.get_pixel(n.x, n.y).r: above_parent += 1
	check(above_parent > land * 0.9, "monotone toward water %d of %d" % [above_parent, land])
	check(m.surface.get_data() != m.water_surface.get_data(), "land grew")
	# Cliff bands exist: flagged rock cells whose jump over one 32 m macro cell exceeds 45 degrees.
	# (The detail pass sharpens a flagged band into a near-vertical face at 1 m; see Task 5.)
	var cliffs := 0
	for y in range(1, h - 1): for x in w:
		if m.cliff.get_pixel(x, y).r8 == 0: continue
		check(m.bedrock_top.get_pixel(x, y).r >= m.surface.get_pixel(x, y).r - 1e-3, "cliff band exposes rock at %d %d" % [x, y])
		var s := m.surface.get_pixel(x, y).r
		for d in [Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(0, -1)]:
			var n := Vector2i(posmod(x + d.x, w), y + d.y)
			if absf(s - m.surface.get_pixel(n.x, n.y).r) / 32.0 > 1.0: cliffs += 1
	check(cliffs > 0, "no cliffs")
	# Stratigraphy ordering everywhere.
	for y in h: for x in w:
		var b := m.bedrock_top.get_pixel(x, y).r; var cb := m.clay_bottom.get_pixel(x, y).r
		var ct := m.clay_top.get_pixel(x, y).r; var s := m.surface.get_pixel(x, y).r
		check(0.0 <= b and b <= cb + 1e-4 and cb <= ct + 1e-4 and ct <= s + 1e-4, "ordering at %d %d" % [x, y])
	var with_clay := 0
	for y in h: for x in w: if m.clay_top.get_pixel(x, y).r - m.clay_bottom.get_pixel(x, y).r > 1.0: with_clay += 1
	check(with_clay > 0, "no clay lenses")
	# Bank rule: a land cell next to water rises at most 35 degrees over the 32 m to that water cell
	# (the detail pass applies the same limit within 10 m at 1 m resolution).
	for y in range(1, h - 1): for x in w:
		if m.region.get_pixel(x, y).r8 == 0: continue
		var s := m.surface.get_pixel(x, y).r
		for d in dirs.slice(1):
			var n := Vector2i(posmod(x + d.x, w), y + d.y)
			var ws := m.water_surface.get_pixel(n.x, n.y).r
			if ws > 0.0:
				check((s - ws) / 32.0 <= tan(deg_to_rad(p.bank_slope_deg)) + 1e-3, "bank slope at %d %d" % [x, y])
	# Loops and spawn.
	check(m.loops.size() >= 1 and m.loops[0].q > 0.0 and m.loops[0].outlets.size() >= 1, "loops")
	var sc := m.cell(m.spawn.x, m.spawn.y, p)
	check(m.region.get_pixel(sc.x, sc.y).r8 != 0 and m.surface.get_pixel(sc.x, sc.y).r >= 40.0, "spawn on land")
	# A seed with no rivers (Review Focus 4) still yields complete maps and a spawn site.
	var dry := small_params(11); dry.river_sources_per_km2 = 0.0
	var md := MacroGenerator.new().generate(dry)
	check(md.rivers.is_empty() and md.loops.is_empty(), "dry world")
	var dc := md.cell(md.spawn.x, md.spawn.y, dry)
	check(md.region.get_pixel(dc.x, dc.y).r8 != 0, "dry spawn on land")
	check(md.surface.get_width() == w, "dry maps complete")
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd godot && godot --headless --path . --fixed-fps 60 --quit-after 7200 -s res://tests/test_macro_generator.gd`
Expected: fails at "land grew" or "no cliffs".

- [ ] **Step 3: Implement the remaining stages**

Add the five stages and call them from `generate` after `_profiles`. The heap is a GDScript array-backed binary heap keyed on height with the cell index as payload. The growth loop visits each land cell once.

- [ ] **Step 4: Run the tests, then time the default world**

Run: `cd godot && sh tests/run.sh`
Expected: all `PASS`.

Then time a default-size generation once (not a test): `cd godot && godot --headless --path . -s res://tests/time_macro_generator.gd` where that script (create it, keep it out of the `test_` prefix) generates `WorldParams.new()` with `seed = 1`, prints the elapsed seconds per stage via the `progress` callable, and saves the result with `WorldIO.save(maps, params, "default")`.
Expected: under 120 s in total. If it is over 240 s, stop and report; the spec's GDExtension fallback is a separate plan.

- [ ] **Step 5: Commit**

```bash
git add godot/terrain/macro_generator.gd godot/tests/test_macro_generator.gd godot/tests/time_macro_generator.gd
git commit -m "Terrain: macro generator growth with cliff bands, strata, banks, loops, spawn site"
```

---

### Task 5: GPU window and the detail pass

**Files:**
- Create: `godot/terrain/terrain_window.gd`, `godot/terrain/shaders/detail.glsl`, `godot/terrain/debug_window_dump.gd`
- Test: `godot/tests/test_terrain_window_math.gd` (CPU-side addressing only)

**Interfaces:**
- Consumes: `WorldParams`, `MacroMaps`, `RenderingServer.get_rendering_device()`.
- Produces: `class_name TerrainWindow extends RefCounted`:
  - `const FIELDS := ["surface", "bedrock_top", "clay_bottom", "clay_top", "water_surface", "material", "compaction", "saturation"]`, `const TILE := 128`, `const HEIGHT_SCALE := 2048.0`.
  - `func setup(params: WorldParams, maps: MacroMaps, size: int = 512, cell: float = 1.0) -> void`: creates the window textures (`R16_UNORM` or `R8_UNORM`, usage `STORAGE | SAMPLING | CAN_COPY_FROM | CAN_COPY_TO`), uploads the macro images as RD textures (`R32_SFLOAT`, `R8_UNORM`, `R32G32B32_SFLOAT`), compiles `detail.glsl`, and builds the uniform sets once. `cell` is 1 for the main window and 8 for the far ring's window (Task 8); the detail pass receives it as a push constant and scales its noise band.
  - `func texture_rd(field: String) -> Texture2DRD`, `func texture_rid(field: String) -> RID`.
  - `var tiles_around: int` (`params.n_theta() / TILE / cell`), `var tiles_along: int`, `var slots: int` (`size / TILE`).
  - `static func wrap_tile(ti: int, tiles_around: int) -> int` (`posmod`), `func slot_of(tile: Vector2i) -> Vector2i` (`(posmod(tile.x, slots), posmod(tile.y, slots))`), `func texel_origin(tile: Vector2i) -> Vector2i` (`slot_of(tile) * TILE`), `func tile_of_cell(i: int, j: int) -> Vector2i`, `func tile_center(tile: Vector2i) -> Vector2` (θ, z of the tile centre).
  - `func move_to(center_tile: Vector2i) -> void`: computes the set of tiles the window should hold (`slots × slots` around `center_tile`, wrapped in θ, clamped in z so the window never asks for tiles beyond `[0, tiles_along)`), compares with the set it holds, and dispatches `detail.glsl` for every tile that changed slot or is new, inside one compute list with a barrier, via `RenderingServer.call_on_render_thread`. `signal tiles_generated(tiles: Array[Vector2i])`.
  - `func resident_tiles() -> Array[Vector2i]`.
- `detail.glsl` (`#[compute]`, `local_size 8×8×1`, one dispatch per tile of `16 × 16` groups): set 0 = macro samplers (five heights, region, cliff, river), set 1 = eight window images (`r16` ×5, `r8` ×3); push constants = tile index `(ti, tj)`, slot origin texels, `n_theta`, `n_z`, `dtheta`, `R`, `h_sea`, `h_mtn`, `cell`, `seed`, `bank_distance`, `bank_slope_tan`, `macro_cell`. Per cell: bilinear macro sample with wrap and clamp, except across a flagged `cliff` cell, where the interpolation toward the higher neighbour is a `smoothstep` over a 4 m band at the macro cell boundary instead of a 32 m ramp, so the band becomes a near-vertical rock face at 1 m; detail noise from a hash-based value noise in the band `cell .. 32 m` (octaves at 32, 16, 8, 4, 2, 1 m stopping at `cell`), amplitude 1.5 m on flats, 4 m on hills, 8 m on mountains, ×3 on exposed rock, ×0 within half a river width or inside lakes or sea, scaled down by `1 − min(1, bank_distance / river_distance)` near water, and ×0.1 where the macro slope exceeds `tan 50°`; river carve: within half a width the surface is `river_surface − depth · (1 − (2d/w)²)` with `depth = w / 8`, banks blended to the sampled surface between `0.5w` and `1.5w`; lakes and sea: `water_surface` from the macro map, the surface clamped at least 1 m below it; strata from the macro fields plus the same noise scaled by 0.3, clamped to the ordering invariant; `material` = 2 where `bedrock_top ≥ surface − 0.01`, 1 where `clay_top ≥ surface − 0.01`, else 0; `compaction` and `saturation` = 0. Heights written as `h / 2048`.
- `debug_window_dump.gd`: a `Node` that on key `P` copies the `surface` texture to a readback (`texture_get_data`, synchronous is fine for a debug key), converts to an `Image` (FORMAT_L8 scaled) and saves `user://debug/window_surface.png`, printing the min and max height found.

- [ ] **Step 1: Write the failing addressing test**

`godot/tests/test_terrain_window_math.gd`:

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
	# Addressing only; no RenderingDevice headless, so setup() is not called.
	w.configure(p, 512, 1.0)
	check(w.tiles_around == 128 and w.tiles_along == 250 and w.slots == 4, "tile counts %d %d %d" % [w.tiles_around, w.tiles_along, w.slots])
	check(TerrainWindow.wrap_tile(-1, 128) == 127 and TerrainWindow.wrap_tile(128, 128) == 0, "wrap")
	check(w.slot_of(Vector2i(127, 5)) == Vector2i(3, 1) and w.slot_of(Vector2i(128, 5)) == Vector2i(0, 1), "slots across the seam")
	check(w.texel_origin(Vector2i(129, 6)) == Vector2i(128, 256), "texel origin")
	check(w.tile_of_cell(16383, 31999) == Vector2i(127, 249), "last cell")
	var c := w.tile_center(Vector2i(0, 0))
	check(absf(c.x - 64 * p.dtheta()) < 1e-9 and absf(c.y - (-16000.0 + 64.0)) < 1e-6, "tile centre %s" % c)
	# The wanted set around a seam tile wraps in theta and clamps at the ends in z.
	var wanted := w.wanted_tiles(Vector2i(0, 0))
	check(wanted.size() == 16, "wanted count %d" % wanted.size())
	check(wanted.has(Vector2i(127, 0)) and wanted.has(Vector2i(126, 0)) and wanted.has(Vector2i(1, 0)), "wraps around the seam")
	for t in wanted: check(t.y >= 0, "no tile before the first row")
	wanted = w.wanted_tiles(Vector2i(10, 249))
	for t in wanted: check(t.y <= 249, "no tile after the last row")
	check(wanted.has(Vector2i(10, 246)), "window slides back at the end")
	# The far-ring window at 8 m has 16 tiles around.
	var f := TerrainWindow.new(); f.configure(p, 512, 8.0)
	check(f.tiles_around == 16 and f.tiles_along == 31, "far window %d %d" % [f.tiles_around, f.tiles_along])
	if failed: quit(1)
	else: print("PASS"); quit(0)
```

`configure(params, size, cell)` is the RD-free half of `setup`, which `setup` calls first; `wanted_tiles(center_tile) -> Array[Vector2i]` is the pure function `move_to` uses.

- [ ] **Step 2: Run it to verify it fails**

Run: `cd godot && godot --headless --path . --fixed-fps 60 --quit-after 7200 -s res://tests/test_terrain_window_math.gd`
Expected: `TerrainWindow` not found.

- [ ] **Step 3: Implement `TerrainWindow` and `detail.glsl`**

Follow the Godot compute-shader tutorial pattern: `RDShaderFile` loaded from the `.glsl`, `shader_create_from_spirv`, `compute_pipeline_create`, `RDTextureFormat` per field, `uniform_set_create` once per set, `compute_list_begin / bind / set_push_constant / dispatch / add_barrier / end`. Push constants packed with `PackedByteArray` and `encode_*`, padded to 16 bytes. Keep the GLSL noise self-contained (a hash of the integer cell plus seed; no textures for noise). `move_to` does no per-cell work on the CPU.

- [ ] **Step 4: Run the headless test, then the windowed check**

Run: `cd godot && sh tests/run.sh`
Expected: all `PASS`.

Windowed check (no scene changes yet): create `godot/terrain/debug_window.tscn` with a `Node` running a small script that loads `WorldIO.load_world("default")` (generate it with Task 4's timing script if missing), calls `TerrainWindow.setup` and `move_to(w.tile_of_cell(0, 16000))`, adds `debug_window_dump.gd`, and run `godot --path . res://terrain/debug_window.tscn`. Press `P`.
Expected: `user://debug/window_surface.png` exists, is 512 × 512, shows terrain structure (not flat, not noise), and the printed min and max heights are within `[0, h_sea + h_mtn]`. No errors in the output.

- [ ] **Step 5: Commit**

```bash
git add godot/terrain/terrain_window.gd godot/terrain/shaders/detail.glsl godot/terrain/debug_window_dump.gd godot/terrain/debug_window.tscn godot/tests/test_terrain_window_math.gd
git commit -m "Terrain: GPU window with toroidal tiles and the detail pass from macro maps"
```

---

### Task 6: Tile meshes, materials, water, the Terrain node, emitter at the viewer

**Files:**
- Create: `godot/terrain/terrain.gd`, `godot/terrain/terrain.tscn`, `godot/terrain/shaders/tile.gdshader`, `godot/terrain/shaders/water.gdshader`, `godot/terrain/materials.tres`
- Modify: `godot/main.tscn` (Player under Station; add Terrain), `godot/emitter.gd` (viewer-relative spawn), `godot/tests/test_emitter.gd`

**Interfaces:**
- Consumes: `TerrainWindow`, `Cyl`, `Station`, `WorldIO`.
- Produces: `class_name Terrain extends Node3D` with exports `station: Station`, `viewer: Node3D`, `world_name := "default"`, `window_size := 512`; `signal collider_live` (emitted by Task 7); methods `height_at(theta: float, z: float) -> float` (macro bilinear, approximate), `spawn_position() -> Vector3` (station-local from `maps.spawn`, 2 m above `height_at`), `viewer_cell() -> Vector2i`; on `_ready`: `await station.ready` if `station.radius == 0`, load or generate the world (generation shows a progress print), `WorldParams.radius/length/g_hull` taken from the station, create the window, create 16 tile `MeshInstance3D` children and 16 water children, then each `_process`: compute the viewer's tile, call `window.move_to`, re-point tiles whose slot changed (set node transform at `Cyl.position(θ_c, z_c, 0, R)` rotated so local Y is toward the axis, local X spinward, local Z axial; set shader uniforms `tile_theta`, `tile_z`, `slot_origin`).
- `tile.gdshader` (spatial): uniforms `sampler2D surface_tex, water_tex, material_tex` (the `Texture2DRD`s), `float R, tile_theta, tile_z, dtheta, dz, height_scale`, `ivec2 slot_origin`, `int window_size`; vertex: from `VERTEX.xz` in `[−64, 64]` compute `dθ = VERTEX.x · dtheta` and `dz = VERTEX.z`, texel = `slot_origin + ivec2(VERTEX.x + 64, VERTEX.z + 64)` wrapped by `window_size`, `h = texelFetch(..).r · height_scale`, `r = R − h`, `VERTEX = vec3(r·sin dθ, R − r·cos dθ, dz)`; normal from the four neighbouring texels with spacing `(R − h)·dtheta` across and `dz` along; fragment: colour by `material` (dirt `(0.45, 0.33, 0.2)`, clay `(0.6, 0.55, 0.45)`, rock `(0.5, 0.5, 0.52)`), darkened by slope, with the project's grid texture mixed in at 20 % for scale. `custom_aabb` on each tile covers `y ∈ [0, 2048]`.
- `water.gdshader`: same vertex path from `water_tex`, `ALPHA = 0.6`, blue-green tint, `discard` where `water ≤ surface`.
- `materials.tres`: a `Resource` (script `terrain/material_set.gd`) with per-material `color`, and the research table's values as placeholders for later slices.
- `emitter.gd`: new `@export var viewer: Node3D`; `_outward()` and `_local_spawn_point()` use, when `viewer` is set, the viewer's station-local position: angle `Cyl.theta_of(local)` and `z = local.z`; otherwise unchanged. `info_text` unchanged.
- `main.tscn`: `Player` becomes a child of `Station` at the same local transform; `Terrain` (instance of `terrain.tscn`) added under `Station` with `station = ".."`, `viewer = "../Player"`; the emitter gets `viewer = "../Player"`.

- [ ] **Step 1: Extend the emitter test (Review Focus 5)**

Append to `test_emitter.gd` before the trail check:

```gdscript
	# With a viewer set, boxes spawn at the viewer's angle and z, spinward still tangent there.
	station.position.x = 0
	var viewer := Node3D.new(); station.add_child(viewer)
	viewer.position = Vector3(2000, -2000, 777)  # 45 degrees spinward of the bottom
	emitter.viewer = viewer
	emitter.distance_from_axis = 100
	var sp := station.to_local(emitter.spawn_point())
	check(sp.distance_to(Vector3(100 * sin(PI / 4), -100 * cos(PI / 4), 777)) < 1e-3, "spawn at viewer angle %s" % sp)
	check(emitter.spinward().is_equal_approx(station.global_basis * Vector3(cos(PI / 4), sin(PI / 4), 0)), "spinward rotates with the viewer")
	emitter.viewer = null
	check(station.to_local(emitter.spawn_point()).is_equal_approx(Vector3(0, -100, emitter.position.z)), "no viewer restores the fixed point")
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd godot && godot --headless --path . --fixed-fps 60 --quit-after 7200 -s res://tests/test_emitter.gd`
Expected: fails, `viewer` is not a property.

- [ ] **Step 3: Implement the emitter change, the shaders, `Terrain`, and the scene edits**

Order: emitter first (run `test_emitter.gd` to green), then `materials.tres`, the two shaders, `terrain.gd` and `terrain.tscn`, then `main.tscn`. In `main.tscn` the Player's `station` path becomes `".."`. The spawn camera and lights stay under `Main`.

- [ ] **Step 4: Run the tests, then the windowed run**

Run: `cd godot && sh tests/run.sh`
Expected: all `PASS` (`test_player.gd` is unaffected by the reparent because it builds its own tree).

Windowed: `cd godot && godot --path .` (the default world generates on first run if `user://worlds/default` is missing; wait for it).
Expected: terrain visible under and around the player at its current fixed position (collision is still the hull, so the player may stand under or inside terrain; that is expected until Task 7); the 16 tiles form a continuous surface with no cracks; three material colours visible; water surfaces visible on lakes and the sea band if in view; walking spinward across θ = 0 keeps the surface continuous (Review Focus 1); pressing Spawn drops boxes beside the player. No errors in the output. Record GPU frame time from the Godot profiler.

- [ ] **Step 5: Commit**

```bash
git add godot/terrain/terrain.gd godot/terrain/terrain.tscn godot/terrain/shaders/tile.gdshader godot/terrain/shaders/water.gdshader godot/terrain/materials.tres godot/terrain/material_set.gd godot/main.tscn godot/emitter.gd godot/tests/test_emitter.gd
git commit -m "Terrain: tile and water meshes on the cylinder, Terrain node in the scene, emitter spawns at the viewer"
```

---

### Task 7: Collider patch and spawn

**Files:**
- Create: `godot/terrain/collider_patch.gd`, `godot/terrain/shaders/collider_bake.glsl`
- Modify: `godot/terrain/terrain.gd` (own the patch, hold the player, spawn), `godot/player.gd` (none expected; the hold is done from `Terrain` via `process_mode`)

**Interfaces:**
- Consumes: `TerrainWindow` textures, `MacroMaps` textures (fallback outside the window), `Cyl.bake_row` as the reference algorithm.
- Produces: `class_name ColliderPatch extends StaticBody3D` with `const SAMPLES := 257`, `var center: Vector2` (θ, z), `func rebuild(window: TerrainWindow, center_theta: float, center_z: float) -> void`, `signal live(center: Vector2)`, and a child `CollisionShape3D` with a `HeightMapShape3D` of `257 × 257` (`map_width = map_depth = 257`). The node's transform: origin at `Cyl.position(θ_c, z_c, 0, R)`, basis with Y toward the axis, X spinward, Z axial (the heightfield's local X and Z map to the patch's x and z, so `map_data[j · 257 + i]` is the sample at `x = (i − 128)`, `z = (j − 128)`).
- `collider_bake.glsl`: `local_size 64×1×1`, one invocation per output row `j` (257 rows → 5 groups); each invocation loads the 257 surface samples along θ at `z = z_c + (j − 128)`, from the window texture when inside it and from the macro `surface` sampler otherwise, maps them to `(x, y)` with the patch's `θ_c` and the station `R`, and resamples onto the uniform `x` grid with the upper-envelope rule of `Cyl.bake_row`, writing `r32f` into a 257 × 257 staging texture (`CAN_COPY_FROM`, created once). The collider is the ground, so it bakes `surface` only; water is walked through in this slice.
- `Terrain` changes: creates one `ColliderPatch` as its child; each `_process`, if the viewer is more than 64 m (in the patch's own frame) from `center`, calls `rebuild` with the viewer's `(θ, z)`; `rebuild` dispatches the bake then `texture_get_data_async(staging, 0, callback)`; the callback converts with `to_float32_array`, assigns `map_data`, sets the node transform, and emits `live`. On the first `live`, `Terrain` emits `collider_live`, moves the player to `spawn_position()` facing spinward, and sets its `process_mode` back to `PROCESS_MODE_INHERIT`; until then the player's `process_mode` is `PROCESS_MODE_DISABLED` from `Terrain._ready`. After a floating-origin shift (Task 8) nothing needs to happen: the patch is under `Station`.

- [ ] **Step 1: Write the failing test (what can be tested headless)**

Append to `test_terrain_window_math.gd` before `if failed:`:

```gdscript
	# Collider patch frame: local Y points at the axis, X is spinward, origin on the hull.
	var patch := ColliderPatch.new()
	patch.set_frame(0.5 * PI, 300.0, 3200.0)
	check(patch.position.is_equal_approx(Vector3(3200, 0, 300)), "patch origin %s" % patch.position)
	check(patch.basis.y.is_equal_approx(Vector3(-1, 0, 0)), "patch up toward the axis %s" % patch.basis.y)
	check(patch.basis.x.is_equal_approx(Vector3(0, 1, 0)), "patch x spinward %s" % patch.basis.x)
	check(patch.basis.z.is_equal_approx(Vector3(0, 0, 1)), "patch z axial")
	var shape: HeightMapShape3D = patch.get_node("CollisionShape3D").shape
	check(shape.map_width == 257 and shape.map_depth == 257, "patch samples")
	check(patch.needs_rebuild(Vector3(3200, 0, 300) + patch.basis.x * 65.0), "rebuild beyond 64 m")
	check(not patch.needs_rebuild(Vector3(3200, 0, 300) + patch.basis.x * 63.0), "no rebuild within 64 m")
```

`set_frame(theta, z, R)` sets the transform and `center`; `needs_rebuild(viewer_local: Vector3) -> bool` is the pure distance test in the patch's XZ plane.

- [ ] **Step 2: Run it to verify it fails**

Run: `cd godot && godot --headless --path . --fixed-fps 60 --quit-after 7200 -s res://tests/test_terrain_window_math.gd`
Expected: `ColliderPatch` not found.

- [ ] **Step 3: Implement the patch, the bake shader and the Terrain changes**

Port `Cyl.bake_row` to GLSL faithfully (same fold-back rule). Use `RenderingDevice.texture_get_data_async`; the callback runs on the render thread under the default thread model, which is the main thread, so it may touch the scene directly. Keep `map_data` assignment as one `PackedFloat32Array` assignment.

- [ ] **Step 4: Run the tests, then the windowed run**

Run: `cd godot && sh tests/run.sh`
Expected: all `PASS`.

Windowed: `cd godot && godot --path .`
Expected: the player appears at the spawn site standing on the ground after a short hold; walking in every direction stays on the surface; at the foot of a cliff the player is blocked and does not pass through; Spawn drops boxes that land on terrain and rest; running 200 m in one direction triggers a rebuild with no visible fall-through; walking into a lake walks on the lake bed under the water surface. Compare the visible ground against the collider by dropping a box on a slope: it must rest on the drawn surface, not above or below it by more than a few centimetres (away from cliffs). No errors.

- [ ] **Step 5: Commit**

```bash
git add godot/terrain/collider_patch.gd godot/terrain/shaders/collider_bake.glsl godot/terrain/terrain.gd godot/tests/test_terrain_window_math.gd
git commit -m "Terrain: curvature-baked heightfield collider patch with async readback, spawn on the ground"
```

---

### Task 8: Floating origin, far terrain, fly camera, timings

**Files:**
- Create: `godot/terrain/far_terrain.gd`, `godot/terrain/shaders/far.gdshader`, `godot/terrain/fly_camera.gd`, `godot/terrain/timing_overlay.gd`
- Modify: `godot/terrain/terrain.gd`, `godot/terrain/terrain.tscn`, `godot/main.tscn` (fly camera node)
- Test: `godot/tests/test_floating_origin.gd`

**Interfaces:**
- Consumes: `Terrain`, `TerrainWindow` (second instance at `cell = 8`), `MacroMaps` textures.
- Produces:
  - Floating origin in `Terrain`: `const ORIGIN_STEP := 1024.0`; `func origin_shift_for(viewer_global_z: float) -> float` returns `−round(viewer_global_z / ORIGIN_STEP) · ORIGIN_STEP` or 0 when `|viewer_global_z| ≤ ORIGIN_STEP`; `_process` applies it to `station.position.z += shift`. Pure function for the test.
  - `class_name FarTerrain extends Node3D`: ring 1 is a second `TerrainWindow` at `cell = 8`, `size = 512` (4 km), drawn with `tile.gdshader` through 16 tiles of 1024 m (the shader gains a `float cell` uniform that scales the vertex grid and the texel lookup, 1 for the main tiles), with the shader uniform `inner_radius` set so fragments inside the 1 m window's extent are discarded; ring 2 is a `far.gdshader` grid of 512 × 1000 vertices over the whole macro map at 32 m, discarding inside ring 1; ring 3 is the same grid at 128 m (`macro` sampled with a 4-texel stride) with no discard, drawn beyond 10 km. All rings use `custom_aabb` of the whole cylinder and sample the macro textures through `Texture2DRD`s created by `TerrainWindow` for the macro uploads (expose `macro_texture_rd(name)`).
  - `fly_camera.gd` on a `Camera3D` under `Station`: F toggles it; while active, `Terrain.viewer` is the camera and `Player.process_mode` is `DISABLED`; WASD plus Q/E move in the camera's frame at `speed` (default 50 m/s, scroll wheel ×1.25 per notch), mouse look while captured; it starts at the player's position; F again returns the viewer to the player and re-enables it.
  - `timing_overlay.gd`: a `Label` in the panel showing the last GPU times for `detail`, `bake`, and the frame, from `capture_timestamp` pairs placed around each compute list by `TerrainWindow` and `ColliderPatch` (`get_captured_timestamp_gpu_time`), updated every 30 frames.

- [ ] **Step 1: Write the failing test**

`godot/tests/test_floating_origin.gd`:

```gdscript
extends SceneTree

var failed := false

func check(ok: bool, msg: String) -> void:
	if not ok:
		push_error(msg)
		failed = true

func _initialize() -> void:
	check(Terrain.origin_shift_for(0.0) == 0.0, "no shift at origin")
	check(Terrain.origin_shift_for(1000.0) == 0.0, "no shift under a step")
	check(Terrain.origin_shift_for(2500.0) == -2048.0, "shift down")
	check(Terrain.origin_shift_for(-1600.0) == 2048.0, "shift up")
	# Shifting the station keeps every child's station-local position and moves global positions together.
	var station: Station = load("res://station.tscn").instantiate()
	root.add_child(station)
	await process_frame
	var viewer := Node3D.new(); station.add_child(viewer); viewer.position = Vector3(0, -3195, 2500)
	var patch := Node3D.new(); station.add_child(patch); patch.position = Vector3(0, -3200, 2400)
	station.position.z += Terrain.origin_shift_for(viewer.global_position.z)
	check(absf(viewer.global_position.z - 452.0) < 1e-3, "viewer near the origin %f" % viewer.global_position.z)
	check(viewer.position.z == 2500.0 and patch.position.z == 2400.0, "local positions unchanged")
	check(absf(patch.global_position.z - viewer.global_position.z + 100.0) < 1e-3, "patch moved with the viewer")
	if failed: quit(1)
	else: print("PASS"); quit(0)
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd godot && godot --headless --path . --fixed-fps 60 --quit-after 7200 -s res://tests/test_floating_origin.gd`
Expected: `origin_shift_for` not found.

- [ ] **Step 3: Implement the four pieces**

`origin_shift_for` is static. Apply the shift in `Terrain._process` before updating the window, and note that tiles, the patch and the player are all under `Station`, so nothing else moves. Far rings are created in `terrain.tscn`. The fly camera node is added to `main.tscn` under `Station` with `current = false`.

- [ ] **Step 4: Run the tests, then the windowed run**

Run: `cd godot && sh tests/run.sh`
Expected: all `PASS`.

Windowed: `cd godot && godot --path .`
Expected: from the spawn site the far side of the cylinder shows terrain, not the bare grid; mountains and the sea band are visible at distance; press F and fly 5 km along the axis at full speed: tiles stream without holes, the 8 m ring fills in behind the 1 m window without a visible gap, the origin shifts at least four times with no hitch longer than one frame visible and no change in the apparent position of anything; fly to within 200 m of a station end (Review Focus 2): no errors, the last tiles clamp; return with F: the player is where it was left and the collider is live. The timing overlay shows `detail` under 2 ms per tile and `bake` under 1 ms. No errors.

- [ ] **Step 5: Commit**

```bash
git add godot/terrain/far_terrain.gd godot/terrain/shaders/far.gdshader godot/terrain/fly_camera.gd godot/terrain/timing_overlay.gd godot/terrain/terrain.gd godot/terrain/terrain.tscn godot/main.tscn godot/tests/test_floating_origin.gd
git commit -m "Terrain: floating origin along the axis, far rings, fly camera, GPU timing overlay"
```

---

### Task 9: Smoke run, budgets and notes

**Files:**
- Create: `godot/terrain/smoke_run.gd` (autoload-free script attached to a `terrain/smoke.tscn` that drives the player and camera through the spec's section 13 route and logs frame times)
- Modify: `docs/terrain-research.md` (a short "Slice 1 measurements" note under section 6.8), `godot/tests/run.sh` (no change expected; confirm the new tests are picked up)

**Interfaces:**
- Consumes: everything above.
- Produces: `smoke.tscn` runs `main.tscn`'s content with a driver that, after `collider_live`, runs the player spinward for 60 s, axially for 60 s, toggles the fly camera and flies 5 km, then prints the 1 % worst frame time, the mean frame time, the max `detail` and `bake` GPU times, and the number of origin shifts, and quits.

- [ ] **Step 1: Write the driver and run it**

Run: `cd godot && godot --path . res://terrain/smoke.tscn`
Expected output, on the development machine at 1440p with the 512 window:

| measurement | budget |
|---|---|
| mean GPU frame time | under 6 ms |
| 1 % worst frame | under 16 ms |
| detail per tile | under 2 ms |
| bake | under 1 ms |
| errors | none |

If a budget is missed, report the numbers; do not tune in this task.

- [ ] **Step 2: Run the whole headless suite one last time**

Run: `cd godot && sh tests/run.sh`
Expected: all `PASS`.

- [ ] **Step 3: Record the measurements**

Add the measured table to `docs/terrain-research.md` under section 6.8 as "Slice 1 measurements, 2026-xx-xx, <machine>", three lines at most, and note any budget missed.

- [ ] **Step 4: Commit**

```bash
git add godot/terrain/smoke_run.gd godot/terrain/smoke.tscn docs/terrain-research.md
git commit -m "Terrain: smoke run driver and slice 1 measurements"
```

---

## Self-review notes

- Spec coverage: datum and grid (Task 1, 2), macro generation with cliffs, banks, loops and spawn (3, 4), detail pass and window (5), tiles, water, materials, scene and emitter (6), collider with baked curvature and the spawn hold (7), floating origin, far rings, fly camera, timings (8), smoke run and budgets (9). Persistence of edits is a non-goal and the `tiles/` directory is created empty by `WorldIO.save`.
- Interfaces named identically across tasks: `Cyl.position/theta_of/height_of/span_volume/bake_row`, `WorldParams` derived functions, `MacroMaps.sample/cell`, `TerrainWindow.configure/setup/move_to/wanted_tiles/slot_of/texel_origin/tile_of_cell/tile_center/texture_rd`, `ColliderPatch.set_frame/needs_rebuild/rebuild/live`, `Terrain.origin_shift_for/collider_live/spawn_position`.
- Deviations from the spec, stated: `station.gd` gains a `length` field (the spec said unchanged; one line). Macro maps use 32-bit float images because Godot has no 16-bit unorm `Image` format, so RAM is about 17 MB rather than 6; the spec's budget line is superseded by the measurement in Task 9.
