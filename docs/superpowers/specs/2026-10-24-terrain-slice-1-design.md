# Terrain, slice 1: generated ground you can walk on

Design for the first deliverable of the cylinder terrain system. It implements the storage, streaming, rendering and collision spine of architecture A from [docs/terrain-research.md](../../terrain-research.md), with every simulation pass left empty. Later slices add the dynamic cycle (dig, move, recompact), collapse, wetting, pump loops and waterfalls on top of this spine without changing its data layout.

Status: design, 2026-10-24. Decisions marked **(call)** are the author's; everything else was decided in conversation or in the research document.

## 1. Intent

The game is a walkable O'Neill cylinder. Today the player stands on a bare hull. This slice replaces the hull surface with generated terrain: mountain ranges, valleys, flatlands, rivers, lakes with islands, in three materials (dirt, clay, rock), sitting on a fixed datum, covering the whole hull, with real collision everywhere the player goes. The player spawns, walks, and looks. Nothing can be modified yet.

The reason to build exactly this first: the dynamic features all depend on the same grid, datum, tile store, GPU window, mesh path and collider path. Getting those right with static terrain is cheap to test and fixes the hardest plumbing (compute shaders feeding both the renderer and Jolt) before any solver exists.

## 2. Goals, non-goals, anti-goals

Goals:

- Procedurally generated terrain over the full hull, deterministic from a seed, with mountains, valleys, flatlands, rivers, lakes and islands.
- The datum from the research doc: sea level 400 m above the hull, mountain height set by sea-level gravity.
- Three materials in the data and visibly different on the surface.
- Walkable everywhere with the existing player, including up mountains where gravity is lower.
- A debug fly camera for inspecting the world **(call)**.
- A data layout that the later slices extend without migration: column spans on an angle-by-length grid, tiles, a GPU window of shared textures, grouped heightfield colliders.

Non-goals for this slice:

- Digging, augers, tampers, pumps, compaction, collapse, wetting, waterfalls, loose material, evaporation.
- Flowing water. Water is drawn as still surfaces at generated levels.
- Swimming or any water interaction; the player walks on the lake bed under the surface.
- Persistence of edits (there are none). The world file format must leave room for per-tile deltas.
- Vehicles, fast travel, multiplayer.

Anti-goals (would make this a failure even if it ran):

- A data layout that stores heights as the conserved quantity or ignores the cylinder's shrinking cell width, because the later mass-conservation requirement then fails silently.
- Any per-cell loop in GDScript on the hot path.
- Terrain generated or stored at the fine resolution for the whole station. The fine resolution exists only inside the window and is procedural from the macro maps.
- A collider that is not the same surface the player sees.

## 3. Constraints

- Godot 4.7.2 standard build, Forward+ renderer, Jolt physics, GDScript plus GLSL compute. No GDExtension unless the macro generator is proven too slow in GDScript (section 6).
- The station is `Station` in `godot/station.gd`: radius from the hull mesh (3200 m by default), acceleration 9.8 m/s² at the hull, spin about local +Z, `Vector3.FORWARD` is −Z, spinward is +X at the bottom of the cylinder. Terrain reads these; it never duplicates them.
- Hull length is the mesh length, about 32 km (±16 km along Z).
- Single precision. The world keeps itself within about 3.5 km of the origin by shifting along Z (section 7).
- Development machine is Apple silicon on Metal; the design must run there at 60 fps with headroom, and nothing may depend on image atomics or on region texture updates, which Godot 4.7.2 lacks.
- Tests run headless with the existing `godot/tests/run.sh`; GPU code cannot run headless, so it gets a windowed smoke run instead.

## 4. World model

### 4.1 Coordinates and datum

- A cell is addressed by `(i, j)` on an angle-by-length grid: `θ = i·Δθ`, `z = j·Δz − L/2`, with `Δθ = 2π / 8192` and `Δz = 2 m`. Around the hull there are 8192 columns; along it `L / 2 m`, about 16,000. **(call)** on 8192: it gives 2.15 m cells at sea level, 2.45 m at the hull and 1.4 m at 1 km above sea level, and it is a power of two for tiling.
- Heights are radial, measured inward from the hull. Radius of a point at height `h` is `r = R − h`.
- Datum: sea level is `h_sea = 400 m`, so `R_sea = R − 400`. Water may lie anywhere between the hull and sea level, so up to 400 m deep.
- Gravity is `g(h) = g_hull · (1 − h/R)`, from the station. Sea-level gravity is `g_sea = g_hull · R_sea / R`, 8.575 m/s² by default.
- Maximum relief above sea level: `H_mtn = H_ref · g_ref / g_sea` with `g_ref = 9.8 m/s²` and `H_ref = 1000 m` **(call)**. By default `H_mtn ≈ 1143 m`, peaks about 1543 m above the hull, where gravity is 5.1 m/s². Spinning faster lowers mountains, slower raises them.
- Cell area at height `h` is `(R − h)·Δθ·Δz`. A span's volume between heights `h1 < h2` is `Δθ·Δz·((R − h1)² − (R − h2)²)/2`. Any future movement of material uses this formula, never a height difference times a fixed area.

### 4.2 Columns and spans

Each column holds solid spans from the hull up to the surface. In this slice every column is one of three shapes: rock to the surface; rock then dirt; rock, a clay lens, dirt. The dense fields per cell, 16-bit fixed point above the hull in 1/32 m steps (range 2048 m) unless noted:

| field | meaning |
|---|---|
| `surface` | top of the solid ground |
| `bedrock_top` | top of the rock span; equals `surface` where rock is exposed |
| `clay_bottom`, `clay_top` | the clay lens; equal when absent |
| `water_surface` | water level, 0 where none |
| `material` (u8) | material at the surface: 0 dirt, 1 clay, 2 rock |
| `compaction`, `saturation` (u8) | reserved, zero in this slice |

Ordering invariant: `0 ≤ bedrock_top ≤ clay_bottom ≤ clay_top ≤ surface`. Boundaries are stored, not volumes; the volume formula converts exactly when later slices need mass. Loose spans, extra spans for tunnels and per-span saturation arrive in later slices as additional fields and a sparse span buffer; nothing in this slice may assume the three-shape limit outside the detail pass.

### 4.3 Materials

Dirt, clay and rock as in the research doc's table. In this slice only their appearance and their stratigraphy matter; strength, wetting and compaction values are carried in a single `materials.tres` resource so later slices read them from one place.

## 5. Scale and tiling

| level | cell | extent | lives |
|---|---|---|---|
| macro maps | 32 m, 512 × 1000 cells | whole station | on disk and in RAM, about 6 MB |
| window | 2 m, 512 × 512 cells (1 km square) | around the viewer | GPU textures, about 3.5 MB |
| tile | 128 × 128 cells (256 m) | unit of streaming and of the window's ring buffer | generated on the GPU when it enters the window |
| collider patch | 257 × 257 samples at 2 m (512 m) | around the viewer | one `HeightMapShape3D` |

The window size is a project setting; 1024 is the high-end option. Macro cells are exactly 16 × 16 fine cells so lookups are shifts.

## 6. Generation

Two stages. The macro stage runs once per world and is stored. The detail stage runs on the GPU whenever a tile enters the window and is never stored, because it is deterministic from the macro maps and the seed. Edited tiles, in later slices, are stored as deltas on top of the detail stage's output.

### 6.1 Macro stage (once per world)

Fischer-style water-first growth adapted to the cylinder. Periodic in `θ`. Outputs at 32 m. Steps, in order:

1. **Parameters.** Seed, `R`, `L`, `h_sea`, `H_mtn`, sea band width, region mix, river density, lake rate. All in a `WorldParams` resource saved with the world.
2. **Seas.** One ring sea around the full circumference centred on `z = 0`, mean width 3 km, shoreline noise of about ±600 m, with several rock-cored islands inside it from thresholded noise **(call)**. Sea level is the datum. Sea floor depth grows from the shore to the hull at the band's centre.
3. **Regions.** Partition land into mountain, hill and flat regions by low-frequency noise and Voronoi cells, with mountains biased toward the station ends and flats toward the sea. Each region has a growth rate.
4. **Drainage.** A spanning forest over land cells seeded from every shoreline cell, grown by random-order fringe expansion, gives every land cell a flow direction toward the sea. River sources are placed by density weighted toward mountain regions. Each source traces its flow path to the sea; discharge `Q` accumulates at confluences. Reaches below a `Q` threshold are dropped. Width and depth follow `Q`.
5. **Lakes.** On about one river in three, a lake on a river cell, radius from `Q`, boundary noised, level fixed when the river profile is set.
6. **River profiles.** Walk each river upstream from its mouth, raising the water surface at a slope that falls with `Q`. Lakes are flat at the height the river reaches them. This gives every water cell a height before any land exists.
7. **Growth.** Priority-queue growth of land height outward from all water cells: `h' = h + s_region·b + s_river·(1 − b) + |noise|`, with `b` the blend from river-bank growth to regional growth, all terms non-negative, and the rate attenuated as `h` approaches `h_sea + H_mtn` so peaks approach the cap smoothly. Rivers and lakes are therefore local minima by construction and every land cell drains to the sea.
8. **Stratigraphy.** `bedrock_top = surface − D`, with `D` by region (flats 150 to 300 m, hills 60 to 150 m, mountains 0 to 40 m, noised) so peaks and cliffs expose rock. Clay lenses from thresholded 3D noise inside the dirt, 2 to 10 m thick. Topsoil thin on steep slopes. Islands get rock cores.
9. **Banks.** Within 10 m of any water, limit the generated slope to the saturated stable slope of the bank material (35° for dirt), so later wetting cannot start a landslide the generator built in.
10. **Pump loops (data only).** For each river system, one loop record: intake cell at the mouth, an outlet cell at each source, `Q`. Unused in this slice; stored so the water slice has them.
11. **Spawn site.** A dirt cell with slope under 5°, within 100 m of a river, above sea level, nearest `θ = 0` **(call)**.

Outputs, under `user://worlds/<name>/`: the five height fields and the region map as 16-bit images at 512 × 1000; rivers as polylines with `(θ, z, width, depth, Q)` per vertex; lakes as masks with levels; loops; the spawn site; `WorldParams`. A river distance-and-profile texture (distance to the nearest centreline, that river's width and surface height) is rasterised here at macro resolution so the detail pass can carve channels without searching polylines.

Implementation: GDScript is the baseline, including a binary heap for the growth queue. Budget: under two minutes for the default world on the development machine, with a progress bar. If it misses that by more than 2×, the growth and drainage stages move to a small GDExtension; the interface (`WorldParams` in, the outputs above) does not change.

### 6.2 Detail stage (GPU, per tile, at stream-in)

One compute shader, `detail.glsl`, 8 × 8 workgroups over a tile, writes every field of 4.2 into the window textures at the tile's toroidal position. Per cell:

1. Bilinear-sample the macro fields at `(θ, z)`.
2. Add detail noise in the band between 2 m and 32 m that the macro stage cannot carry: amplitude by region and material (rock rough, dirt flats gentle), zero inside river channels and lakes, reduced within the bank distance of 4.1 step 9.
3. Carve rivers from the river texture: within half a width of a centreline the surface drops to the river's surface minus a parabolic depth profile; banks blend out over 1.5 widths; `water_surface` is the river's surface. Lakes: inside the mask the surface sits at least a minimum depth below the level; `water_surface` is the level. Sea: wherever `surface < h_sea`, `water_surface = h_sea`.
4. Stratigraphy from the macro fields plus small noise, clamped to the ordering invariant.
5. `material` from the stratigraphy at the surface.

Determinism: the same seed, macro maps and tile index give identical output on every run, so the pass is also the reference for later edit deltas.

## 7. Storage, streaming and origin

- **Window textures.** One `RenderingDevice` texture per field, created once on the main rendering device, usage storage, sampling, copy-from and copy-to. Each is wrapped in a `Texture2DRD` for materials. Addressing is toroidal: tile `(ti, tj)` occupies `(ti mod 4, tj mod 4)` of the 4 × 4 tile ring buffer at a 512 window.
- **Viewer.** The window follows the viewer, which is the player or the fly camera. When the viewer's tile changes, the entering row or column of tiles is generated by `detail.glsl` in one compute list with a barrier, and the tile mesh nodes are re-pointed. There is no CPU upload in this slice; the upload path through a staging texture and `texture_copy`, needed for edited tiles later, is reserved in the window's interface but not built.
- **Macro maps on the GPU.** The macro fields and the river texture are uploaded once as ordinary textures and sampled by `detail.glsl` and by the far-terrain shaders.
- **Floating origin.** Everything in the world is a child of the `Station` node, including the player, boxes and terrain. When the viewer's station-local `z` crosses a 1024 m boundary, the station node's `position.z` shifts by a whole 1024 m so the viewer's global `z` stays within ±1024 m. Terrain code works in station-local `(θ, z)` only and never reads a global position for terrain purposes. The shift is a single transform change on one node; Jolt sees a uniform teleport of every body, which preserves contacts.
- **World files.** `user://worlds/<name>/` holds the macro outputs of 6.1 and a `tiles/` directory that is empty in this slice and will hold per-tile deltas later.

## 8. Rendering

- **Tiles.** One shared `ArrayMesh`, a 129 × 129 vertex grid. Sixteen `MeshInstance3D` nodes, one per window tile, each with a `ShaderMaterial` whose uniforms are the tile's `θ_c`, `z_c`, its toroidal offset and the window textures. The node sits at the hull point `(θ_c, R, z_c)` with local Y toward the axis, local X spinward and local Z axial. The vertex shader reads `surface` with `texelFetch`, sets `r = R − h`, and places the vertex at `(r·sin dθ, R − r·cos dθ, dz)` in the node's frame, where `dθ` and `dz` are the vertex's offsets from the tile centre. Angles stay below 0.05 rad so float32 trigonometry is exact to well under a millimetre. Normals come from finite differences of neighbouring texels scaled by the local metric `(R − h)·Δθ` across and `Δz` along. Adjacent tiles sample the same border texels, so there are no cracks. Each tile sets `custom_aabb` to its full height range.
- **Surface look.** The fragment shader colours by `material` and slope: dirt, clay and rock each a flat colour family with slope darkening and a little noise. No textures are required in this slice; the existing grid texture may be used for scale **(call)**.
- **Water.** A second shared grid mesh per tile, drawn only where `water_surface > surface`, translucent, still, with a depth tint. Lakes read flat; rivers follow their generated profile.
- **Far terrain.** Three rings outside the window, each a displaced grid like the tiles but sampling coarser data: an 8 m ring to about 4 km generated by `detail.glsl` with its noise cut at 8 m, a 32 m ring from the macro maps to about 10 km, and a 128 m whole-station mesh from a downsampled macro map. Each ring hides its inner edge under the finer level's skirt. The hull mesh stays as the backdrop beyond the far mesh and as the physical floor under the deepest water, where terrain thickness reaches zero.
- **Sky view.** From the floor the opposite side of the cylinder is 6.4 km away and always visible; the far mesh is what the player sees there. Its resolution is chosen so a 128 m cell subtends under 1.2° at that distance.

## 9. Collision

- **One patch.** A single `StaticBody3D` with a `HeightMapShape3D` of 257 × 257 samples at 2 m spacing (scaled by `(2, 1, 2)`, which Jolt accepts) centred on the viewer. It is rebuilt when the viewer moves more than 128 m from the patch centre, so the patch always extends at least 128 m beyond the viewer in every direction. Spawned boxes land near the player and are covered by the same patch; a second patch per distant body is left to later slices.
- **Curvature is baked in.** The patch's frame is the tangent frame at its centre, with local Y toward the axis. A heightfield can represent any single-valued surface over its grid, and the curved terrain is single-valued over a 512 m patch (9° of arc), so each sample stores the height of the curved surface above the tangent plane: for sample position `(x, z)` in the patch frame, solve `φ` from `(R − h(φ))·sin φ = x` (two fixed-point iterations starting from `φ = x / R_sea` suffice), read `h` at `(θ_c + φ, z_c + z)` bilinearly, and store `y = R − (R − h)·cos φ`. The collider is then the same curved surface the tiles draw, to within linear interpolation between 2 m samples, with no flat-tile sagitta error and no per-tile bodies to produce seam contacts.
- **Baked on the GPU, read back once.** A small compute shader, `collider_bake.glsl`, produces the 257 × 257 float patch into a staging texture from the window textures (falling back to the macro maps where the patch extends outside the window). `texture_get_data_async` returns it after `frame_queue_size` frames; the callback converts the bytes with `PackedByteArray.to_float32_array` and assigns `map_data`. No per-sample GDScript loop. In this slice the terrain is static, so the latency only matters at startup and after a floating-origin shift; the player is held at the spawn point until the first patch is live.
- **Holes.** None in this slice. The NaN-hole convention is reserved for the tunnel slice.
- **Bodies never sleep.** The project's bodies apply a force every tick and never sleep; the tunnel slice depends on that for terrain changing under resting bodies, and nothing in this slice may introduce sleeping.

## 10. Player and camera

- The player spawns at the macro stage's spawn site, 2 m above the surface, facing spinward, after the first collider patch is live.
- The existing walker is unchanged. Its `up_direction` is already radial and its gravity comes from the station, so lower gravity on mountains is automatic.
- **Fly camera (call).** Toggled by F. WASD and mouse in the station frame, speed scaled by the scroll wheel, no collision. While active it is the viewer: the window, the collider patch and the far rings follow it. The player is frozen in place meanwhile.
- The existing emitter panel keeps working; boxes spawn and fall onto terrain.

## 11. Scene and code layout

New folder `godot/terrain/`:

| file | role |
|---|---|
| `terrain.gd`, `terrain.tscn` | `Terrain` node under `Station`: owns the window, tile nodes, collider patch, far rings and viewer tracking; exposes `height_at(θ, z)` and `material_at(θ, z)` for gameplay |
| `world_params.gd` | `WorldParams` resource |
| `macro_generator.gd` | the macro stage, with a progress signal |
| `world_io.gd` | reads and writes `user://worlds/<name>/` |
| `terrain_window.gd` | RD textures, `Texture2DRD` wrappers, toroidal addressing, `detail.glsl` dispatch |
| `collider_patch.gd` | `collider_bake.glsl` dispatch, async readback, `HeightMapShape3D` update |
| `far_terrain.gd` | the three rings |
| `fly_camera.gd` | debug camera |
| `materials.tres` | per-material values |
| `shaders/detail.glsl`, `shaders/collider_bake.glsl` | compute |
| `shaders/tile.gdshader`, `shaders/water.gdshader`, `shaders/far.gdshader` | rendering |

`main.tscn` gains the `Terrain` node under `Station`. `station.gd` is unchanged. A world is generated on first run if `user://worlds/default/` is missing.

## 12. Budgets

Measured on the development machine at 1440p, default world, 512 window:

| item | budget |
|---|---|
| frame time, GPU, standing still | under 6 ms including the existing scene |
| detail pass per tile | under 2 ms |
| collider bake plus readback | under 1 ms GPU, latency `frame_queue_size` frames |
| window memory | under 4 MB at 512, under 16 MB at 1024 |
| macro maps in RAM | under 8 MB |
| macro generation | under 2 minutes, with progress |
| frame hitch on a window step or origin shift | under 4 ms |

`RenderingDevice.capture_timestamp` brackets every compute dispatch from day one, and a debug overlay shows the timings.

## 13. Verification

Headless tests, run by `godot/tests/run.sh`, each a `SceneTree` script that prints `PASS`:

- `test_cylinder_math.gd`: `(θ, z, h)` to position and back; the span-volume formula against a numeric integral; the curvature-bake `φ` solve against the analytic surface for a known height function, error under 1 mm at the patch edge.
- `test_macro_generator.gd`: on a small world (64 × 128 macro cells) with a fixed seed: identical output hash on two runs; every land cell strictly higher than its flow-direction parent; every river reaches the sea; no cell above `h_sea + H_mtn`; stratigraphy ordering holds everywhere; the spawn site satisfies its rules; the bank rule holds within 10 m of water.
- The existing `test_station.gd` and `test_player.gd` still pass unchanged.

Windowed smoke run, manual but scripted: start the game, wait for the first patch, run the player spinward for 60 s and axially for 60 s, toggle the fly camera and fly 5 km, and record frame times and the timestamp overlay. Acceptance: no hole, crack or fall-through, budgets in section 12 met, no error output.

## 14. Left to the builder

- Exact noise functions, octave counts and the colour palette.
- The far-ring scheme beyond the constraints in section 8 (three levels, skirts, 128 m far cell).
- Tile node pooling and the order of compute dispatches within a frame.
- The binary heap and fringe-expansion details in the macro stage, and whether the growth runs over the full 512 × 1000 grid or over land only.
- Whether `surface` and the other heights use `R16_UNORM` with a scale or `R16_UINT`; both satisfy section 4.2.
- How the player is held until the first collider patch is live.

## 15. Calls made and open items

Calls, listed so they can be checked while reading: 8192 columns; `H_ref = 1000 m`; one ring sea at `z = 0` with islands; 512 window with a 1024 option; 257 × 257 collider patch rebuilt at 128 m; spawn nearest `θ = 0`; fly camera on F; grid texture for scale; 1024 m origin shift step; GDScript macro generator with a GDExtension fallback.

Open after this slice, not before it: the exact `H_ref` once mountains are seen; whether the 8 m far ring is worth its cost; whether boxes need their own collider patches.
